import Foundation
import LedgerCore

enum SyncCoordinatorError: Error, Equatable {
    case alreadyRunning
    case notConnected
    case connectionChanged
    case missingBalanceDate
}

struct SimpleFINPinnedAccountsResponse: Sendable {
    var response: SimpleFINAccountsResponse
    var connectionPin: SimpleFINConnectionPin
}

/// Single-flight sync (§6.4). All network requests run here, outside any
/// database transaction; each account's response is handed to the
/// `BudgetMutationService`, whose `syncTransact` commits that account's
/// imports, staged rows, conflicts, discrepancies, pause state, and cursor in
/// ONE database transaction. A failure on one link records a redacted
/// per-link error and never aborts the other links; HTTP 401/403 pauses every
/// active link (`authRevoked`) and stops the pass (§4.5).
actor SyncCoordinator {
    private var inFlight = false
    private let urlSession: URLSession?
    private let nowEpochProvider: @Sendable () -> Int64

    init(
        urlSession: URLSession? = nil,
        nowEpochProvider: @escaping @Sendable () -> Int64 = {
            Int64(Date().timeIntervalSince1970)
        }
    ) {
        self.urlSession = urlSession
        self.nowEpochProvider = nowEpochProvider
    }

    struct SyncSummary: Sendable {
        var importedCount = 0
        var updatedInPlaceCount = 0
        var skippedPendingCount = 0
        var ignoredOutOfWindowCount = 0
        var conflictCount = 0
        var discrepancyCount = 0
        var syncedLinkCount = 0
        var skippedPausedLinkCount = 0
        var pausedLinkMessages: [String] = []
        var linkErrorMessages: [String] = []
        var providerErrors: [String] = []
    }

    func syncNow(
        service: BudgetMutationService,
        credentials: any SimpleFINCredentialStore,
        connectionPin: SimpleFINConnectionPin,
        nowEpoch: Int64
    ) async throws -> SyncSummary {
        guard !inFlight else { throw SyncCoordinatorError.alreadyRunning }
        inFlight = true
        defer { inFlight = false }

        guard let state = try await service.simpleFINState(),
              state.activeCredentialPin != nil else {
            throw SyncCoordinatorError.notConnected
        }
        guard state.matchesActiveCredential(connectionPin) else {
            throw SyncCoordinatorError.connectionChanged
        }
        let credential = try credentials.load(itemID: connectionPin.itemID)
        let client = SimpleFINClient(credential: credential, urlSession: urlSession)
        var summary = SyncSummary()
        var passRetryNotBeforeEpoch: Int64?

        if state.isSyncDeferred(at: max(nowEpoch, nowEpochProvider())) {
            summary.linkErrorMessages.append("Sync is deferred until the server-provided retry time.")
            return summary
        }

        for link in state.links {
            // A Retry-After received for one link is connection-wide. Re-read
            // the durable gate before every subsequent link so this pass never
            // expands the provider's requested backoff window. The local gate
            // is a fail-closed fallback when the durable update races another
            // writer and cannot be persisted.
            let evaluationEpoch = max(nowEpoch, nowEpochProvider())
            if (try await service.simpleFINState())?.isSyncDeferred(at: evaluationEpoch) == true
                || passRetryNotBeforeEpoch.map({ evaluationEpoch < $0 }) == true {
                summary.linkErrorMessages.append("Sync is deferred until the server-provided retry time.")
                break
            }
            // A paused link pauses sync for that account only (§4.6).
            guard link.status == .active else {
                summary.skippedPausedLinkCount += 1
                continue
            }
            // Links without a cursor were never initial-linked; skip.
            guard let cursor = link.lastSuccessfulPostedEpoch else { continue }
            let identity = link.identity
            do {
                try await validateConnection(service: service, expected: connectionPin)
                let window = try SimpleFINRequestWindow.recurring(lastSuccessfulPostedEpoch: cursor)
                // Network stays outside the write transaction (§6.4). A window
                // longer than SimpleFIN's 45-day limit is fetched in pages.
                let response = try await fetchPaged(
                    client: client,
                    service: service,
                    windows: try SimpleFINHistoryPaging.windows(
                        startEpoch: window.startEpoch,
                        endEpoch: window.endEpoch,
                        nowEpoch: max(nowEpoch, nowEpochProvider())
                    ),
                    remoteAccountID: link.remoteAccountID,
                    localAccountID: link.localAccountID,
                    nowEpoch: nowEpoch
                )

                // One atomic commit per account: the engine's imports, pause
                // decision, and cursor land together or not at all.
                let outcome = try await service.syncTransact(
                    nowEpoch: nowEpoch,
                    expectedCredentialPin: connectionPin
                ) { workspace, updated in
                    guard var storedLink = updated.link(identity: identity) else {
                        throw SyncCoordinatorError.connectionChanged
                    }
                    let outcome = try SimpleFINSyncEngine.applyAccountSync(
                        response: response,
                        link: &storedLink,
                        window: .recurring(requestStartEpoch: window.startEpoch),
                        workspace: &workspace,
                        nowEpoch: nowEpoch
                    )
                    if outcome.hasProviderErrors {
                        guard updated.recordProviderErrors(
                            outcome.providerErrors,
                            forLinkIdentity: identity
                        ) else {
                            throw SyncCoordinatorError.connectionChanged
                        }
                        return outcome
                    }
                    try updated.upsertLinkOrThrow(storedLink)
                    updated.lastSuccessfulSyncAtEpoch = nowEpoch
                    updated.clearExpiredSyncDeferral(at: nowEpoch)
                    updated.clearLastErrorAfterSuccessfulSync()
                    return outcome
                }
                summary.importedCount += outcome.importedTransactionIDs.count
                summary.updatedInPlaceCount += outcome.updatedInPlaceTransactionIDs.count
                summary.skippedPendingCount += outcome.skippedPendingCount
                summary.ignoredOutOfWindowCount += outcome.ignoredOutOfWindowCount
                summary.conflictCount += outcome.conflictIDs.count
                summary.discrepancyCount += outcome.discrepancyID == nil ? 0 : 1
                summary.providerErrors.append(contentsOf: outcome.providerErrors)
                if outcome.hasProviderErrors {
                    continue
                }
                if let pause = outcome.pause {
                    summary.pausedLinkMessages.append("A link was paused (\(pause.rawValue)).")
                } else {
                    summary.syncedLinkCount += 1
                }
            } catch {
                if error as? SyncCoordinatorError == .connectionChanged
                    || error as? SimpleFINConnectionPinError == .connectionChanged {
                    throw SyncCoordinatorError.connectionChanged
                }
                try await validateConnection(service: service, expected: connectionPin)
                if case SimpleFINHTTPError.status(let code, _) = error, code == 401 || code == 403 {
                    // §4.5: a revoked/invalid credential is connection-level;
                    // pause every active link until reconnect and stop.
                    try await pauseAllActiveLinks(
                        service: service,
                        nowEpoch: nowEpoch,
                        httpCode: code,
                        expected: connectionPin
                    )
                    throw error
                }
                if case SimpleFINHTTPError.status(_, let retryAfterSeconds) = error,
                   let retryAfterSeconds,
                   retryAfterSeconds > 0 {
                    let retryBaseEpoch = max(nowEpoch, nowEpochProvider())
                    // An oversized Retry-After must still defer (fail closed):
                    // saturate the deadline at Int64.max instead of skipping
                    // both the durable and in-memory gates on overflow.
                    let deadline = retryBaseEpoch.addingReportingOverflow(retryAfterSeconds)
                    let retryNotBeforeEpoch = deadline.overflow ? Int64.max : deadline.partialValue
                    passRetryNotBeforeEpoch = max(
                        passRetryNotBeforeEpoch ?? Int64.min,
                        retryNotBeforeEpoch
                    )
                    do {
                        try await service.updateSimpleFINState(nowEpoch: retryBaseEpoch) { stored in
                            guard var updated = stored,
                                  updated.matchesActiveCredential(connectionPin) else { return }
                            updated.deferSync(until: retryNotBeforeEpoch)
                            stored = updated
                        }
                    } catch {
                        summary.linkErrorMessages.append(
                            "The server retry delay was applied for this pass but could not be persisted; retry the sync later."
                        )
                    }
                }
                let pauseReason = Self.pauseReason(for: error)
                let message = Self.redactedLinkMessage(for: error)
                _ = try? await service.updateSimpleFINState(nowEpoch: nowEpoch) { stored in
                    guard var updated = stored,
                          updated.matchesActiveCredential(connectionPin),
                          var storedLink = updated.link(identity: identity) else { return }
                    if let pauseReason {
                        storedLink.pause(reason: pauseReason, message: message)
                    } else {
                        storedLink.recordSyncError(message)
                    }
                    try updated.upsertLinkOrThrow(storedLink)
                    stored = updated
                }
                if pauseReason != nil {
                    summary.pausedLinkMessages.append(message)
                } else {
                    summary.linkErrorMessages.append(message)
                }
            }
        }
        try await validateConnection(service: service, expected: connectionPin)
        return summary
    }

    /// §4.5/§4.6: 401/403 on `/accounts` means the credential is revoked or
    /// invalid for every link. Promotion of a new credential generation makes
    /// those links eligible for reactivation after matching discovery.
    private func pauseAllActiveLinks(
        service: BudgetMutationService,
        nowEpoch: Int64,
        httpCode: Int,
        expected: SimpleFINConnectionPin
    ) async throws {
        _ = try await service.updateSimpleFINState(nowEpoch: nowEpoch) { stored in
            guard var updated = stored,
                  updated.matchesActiveCredential(expected) else {
                throw SyncCoordinatorError.connectionChanged
            }
            // This durable gate invalidates this generation before any other
            // in-flight response can reach a workspace/cursor commit.
            updated.markCredentialAuthorizationRevoked()
            updated.recordConnectionSyncError(
                "SimpleFIN access was refused (HTTP \(httpCode)). All links are paused until reconnect."
            )
            stored = updated
        }
    }

    /// Response-level anomalies thrown while decoding a per-account fetch
    /// pause that link (§4.2: pause rather than merging/inventing identity).
    private static func pauseReason(for error: Error) -> SimpleFINLinkPauseReason? {
        switch error {
        case SimpleFINProtocolError.duplicateRemoteAccountIdentity: return .duplicateRemoteIdentity
        case SimpleFINProtocolError.missingStableRemoteIdentity: return .missingStableConnectionKey
        default: return nil
        }
    }

    /// Fixed, short strings only — never URLs, tokens, credential material, or
    /// raw provider payloads.
    private static func redactedLinkMessage(for error: Error) -> String {
        switch error {
        case SimpleFINProtocolError.duplicateRemoteAccountIdentity:
            return "Two remote accounts share one identity; the link was paused rather than merging them."
        case SimpleFINProtocolError.missingStableRemoteIdentity:
            return "The remote account has no stable identity; the link was paused."
        case let http as SimpleFINHTTPError:
            if case .status(let code, _) = http {
                return "Sync failed with HTTP \(code); it will be retried."
            }
            return "The SimpleFIN server could not be reached; sync will be retried."
        case is SimpleFINProtocolError:
            return "The SimpleFIN response failed validation; sync will be retried."
        default:
            return "Sync failed for this account; it will be retried."
        }
    }

    /// Balances-only discovery request used by the linking UI (§4.4 step 1).
    func fetchBalances(
        service: BudgetMutationService,
        credentials: any SimpleFINCredentialStore,
        nowEpoch: Int64
    ) async throws -> SimpleFINPinnedAccountsResponse {
        guard let state = try await service.simpleFINState(),
              let connectionPin = state.activeCredentialPin else {
            throw SyncCoordinatorError.notConnected
        }
        let credential = try credentials.load(itemID: connectionPin.itemID)
        let client = SimpleFINClient(credential: credential, urlSession: urlSession)
        let requestLog = try await service.beginSyncRequest(
            connectionID: "primary",
            startedAtEpoch: nowEpoch
        )
        let response: SimpleFINAccountsResponse
        do {
            response = try await client.fetchAccounts(SimpleFINRequest(balancesOnly: true))
            try await service.finishSyncRequest(
                requestLog,
                status: .succeeded,
                completedAtEpoch: nowEpoch
            )
        } catch {
            let details = Self.httpDetails(for: error)
            try? await service.finishSyncRequest(
                requestLog,
                status: .failed,
                completedAtEpoch: nowEpoch,
                httpStatus: details.code,
                retryAfterSeconds: details.retryAfterSeconds
            )
            if case SimpleFINHTTPError.status(let code, _) = error,
               code == 401 || code == 403 {
                try await pauseAllActiveLinks(
                    service: service,
                    nowEpoch: nowEpoch,
                    httpCode: code,
                    expected: connectionPin
                )
            }
            throw error
        }
        try await validateConnection(service: service, expected: connectionPin)
        return SimpleFINPinnedAccountsResponse(
            response: response,
            connectionPin: connectionPin
        )
    }

    /// History fetch for the two-request initial link sequence (§4.2/§4.4).
    func fetchHistory(
        service: BudgetMutationService,
        credentials: any SimpleFINCredentialStore,
        connectionPin: SimpleFINConnectionPin,
        remoteAccountID: String,
        startEpoch: Int64,
        balanceDateEpoch: Int64,
        nowEpoch: Int64
    ) async throws -> SimpleFINAccountsResponse {
        try await validateConnection(service: service, expected: connectionPin)
        let credential = try credentials.load(itemID: connectionPin.itemID)
        let client = SimpleFINClient(credential: credential, urlSession: urlSession)
        let window = try SimpleFINRequestWindow.initial(
            startEpoch: startEpoch,
            balanceDateEpoch: balanceDateEpoch,
            endpointEndDateIsInclusive: true
        )
        let response: SimpleFINAccountsResponse
        do {
            // Initial history spans up to 90 days; SimpleFIN rejects ranges
            // over 45 days, so the window is fetched in pages and merged.
            response = try await fetchPaged(
                client: client,
                service: service,
                windows: try SimpleFINHistoryPaging.windows(
                    startEpoch: window.startEpoch,
                    endEpoch: window.endEpoch,
                    nowEpoch: nowEpoch
                ),
                remoteAccountID: remoteAccountID,
                localAccountID: nil,
                nowEpoch: nowEpoch
            )
        } catch {
            if case SimpleFINHTTPError.status(let code, _) = error,
               code == 401 || code == 403 {
                try await pauseAllActiveLinks(
                    service: service,
                    nowEpoch: nowEpoch,
                    httpCode: code,
                    expected: connectionPin
                )
            }
            throw error
        }
        try await validateConnection(service: service, expected: connectionPin)
        return response
    }

    /// Fetches consecutive history pages for one remote account, logging each
    /// request like a single fetch, and merges them. Any failed page fails the
    /// whole fetch, so a partial history is never imported.
    private func fetchPaged(
        client: SimpleFINClient,
        service: BudgetMutationService,
        windows: [SimpleFINRequestWindow],
        remoteAccountID: String,
        localAccountID: AccountID?,
        nowEpoch: Int64
    ) async throws -> SimpleFINAccountsResponse {
        var pages: [SimpleFINAccountsResponse] = []
        for window in windows {
            let requestLog = try await service.beginSyncRequest(
                connectionID: "primary",
                accountID: localAccountID,
                requestedStartEpoch: window.startEpoch,
                requestedEndEpoch: window.endEpoch,
                startedAtEpoch: nowEpoch
            )
            do {
                pages.append(try await client.fetchAccounts(SimpleFINRequest(window: window, accountID: remoteAccountID)))
                try await service.finishSyncRequest(
                    requestLog,
                    status: .succeeded,
                    completedAtEpoch: nowEpoch
                )
            } catch {
                let details = Self.httpDetails(for: error)
                try? await service.finishSyncRequest(
                    requestLog,
                    status: .failed,
                    completedAtEpoch: nowEpoch,
                    httpStatus: details.code,
                    retryAfterSeconds: details.retryAfterSeconds
                )
                throw error
            }
        }
        return try SimpleFINHistoryPaging.merge(pages)
    }

    private static func httpDetails(for error: Error) -> (code: Int?, retryAfterSeconds: Int64?) {
        guard case SimpleFINHTTPError.status(let code, let retryAfterSeconds) = error else {
            return (nil, nil)
        }
        return (code, retryAfterSeconds)
    }

    private func validateConnection(
        service: BudgetMutationService,
        expected: SimpleFINConnectionPin
    ) async throws {
        guard let current = try await service.simpleFINState(),
              current.matchesActiveCredential(expected) else {
            throw SyncCoordinatorError.connectionChanged
        }
    }
}

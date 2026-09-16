import Foundation
import LedgerCore

/// App-side projection access: rebuilds the value-type workspace from the
/// current snapshot inside the service actor so replay work stays off the
/// main thread.
extension BudgetMutationService {
    func projectionResult(through horizon: BudgetMonth?) throws -> ProjectionResult? {
        try cachedProjectionResult(through: horizon)
    }
}

/// A remote account visible from the balances-only discovery request.
/// `providerErrors` carries the discovery response's `errors`/`errlist`
/// in LedgerCore-redacted form: a candidate built from an errored response has
/// an untrustworthy balance/balance-date and must not start a link (§4.5).
struct RemoteAccountCandidate: Identifiable, Sendable {
    var connectionKey: String
    var account: SimpleFINRemoteAccount
    var linkedLocalAccountID: AccountID?
    var providerErrors: [String] = []
    var connectionPin: SimpleFINConnectionPin

    var id: String { SimpleFINAccountLink.identity(connectionKey: connectionKey, remoteAccountID: account.id) }
}

enum LinkAttestation: Equatable {
    /// §4.4 option (b): opening = snapshot balance minus normalized history.
    case snapshotMinusHistory
    /// §4.4 option (a): user-entered opening balance at the anchor date.
    case userOpening(Milliunits)
}

extension AppModel {

    // MARK: - Claim (§4.1)

    /// Claims a Setup Token. The token is used once and discarded; the
    /// credential is stored only in the Keychain. If the returned host differs
    /// from the claim host, the credential is parked in `pendingClaim` until
    /// the user explicitly confirms it (§4.1 step 5).
    func connectSimpleFIN(setupToken: String) async {
        pendingSetupToken = nil
        pendingTrustedHost = nil
        await bootstrapIfNeeded()
        guard case .ready = phase else {
            actionError = "Create or open a budget before connecting SimpleFIN."
            return
        }
        do {
            // A Setup Token is single-use. Verify the actual production
            // Keychain boundary before claiming it so an ad-hoc local bundle
            // fails closed without burning the token on a later save error.
            try credentials.preflight()
            // Finish any durable Keychain work before consuming another
            // single-use Setup Token.
            try await credentialLifecycle.retryPendingOperations(nowEpoch: nowEpoch)
            let extraHosts = Set(simplefin?.extraTrustedHosts ?? [])
            let result = try await SimpleFINClient.claim(setupToken: setupToken, trustedHosts: extraHosts)
            let pending = PendingClaim(
                credential: result.credential,
                hostDescription: "\(result.credential.host.host):\(result.credential.host.port)",
                replacementIntent: SimpleFINCredentialReplacementIntent(
                    itemID: UUID().uuidString,
                    baseHost: result.credential.host.host,
                    basePort: result.credential.host.port
                ),
                requiresHostConfirmation: result.returnedHostDiffersFromClaimHost
            )
            if result.returnedHostDiffersFromClaimHost {
                pendingClaim = pending
                return
            }
            if await storeClaimedCredential(pending) {
                pendingClaim = nil
            } else {
                // Keep the claimed credential only in memory so a failed
                // stage/save can retry without consuming another token.
                pendingClaim = pending
            }
        } catch let error as SimpleFINProtocolError {
            if case .untrustedHost(let host) = error,
               let trustedHost = try? SimpleFINHost(host: host) {
                // The token remains in memory only until the explicit host
                // decision; it is never written to state, logs, or argv.
                pendingSetupToken = setupToken
                pendingTrustedHost = trustedHost
            }
            actionError = friendlyMessage(error)
        } catch {
            actionError = friendlyMessage(error)
        }
    }

    /// Persists a user-approved non-official host before the first claim. This
    /// creates only a disconnected, credential-free state when no connection
    /// row exists yet; the host is then available for the retry path.
    func rememberTrustedHost(_ host: SimpleFINHost) async throws {
        await bootstrapIfNeeded()
        guard case .ready = phase else {
            throw LedgerPersistenceError.workspaceNotFound
        }
        let now = nowEpoch
        _ = try await service.updateSimpleFINState(nowEpoch: now) { state in
            if var existing = state {
                existing.addTrustedHost(host)
                state = existing
            } else {
                var created = SimpleFINConnectionState(
                    status: .disconnected,
                    keychainItemID: nil,
                    baseHost: host.host,
                    basePort: host.port,
                    credentialGeneration: 0,
                    createdAtEpoch: now
                )
                created.addTrustedHost(host)
                state = created
            }
        }
        await refresh()
    }

    func trustPendingSetupHostAndRetry(setupToken token: String, host: SimpleFINHost) async {
        do {
            try await rememberTrustedHost(host)
            pendingSetupToken = nil
            pendingTrustedHost = nil
            actionError = nil
            await connectSimpleFIN(setupToken: token)
        } catch {
            actionError = friendlyMessage(error)
        }
    }

    func rejectPendingSetupHost() {
        pendingSetupToken = nil
        pendingTrustedHost = nil
    }

    func confirmPendingClaim(_ pending: PendingClaim) async {
        var confirmed = pending
        confirmed.requiresHostConfirmation = false
        pendingClaim = confirmed
        if await storeClaimedCredential(confirmed) {
            pendingClaim = nil
        }
    }

    func rejectPendingClaim() {
        guard pendingClaim?.requiresHostConfirmation == true else { return }
        pendingClaim = nil
    }

    func retryPendingClaimStorage() async {
        guard let pending = pendingClaim, !pending.requiresHostConfirmation else { return }
        if await storeClaimedCredential(pending) {
            pendingClaim = nil
        }
    }

    private func storeClaimedCredential(_ pending: PendingClaim) async -> Bool {
        do {
            try await credentialLifecycle.replaceCredential(
                pending.credential,
                intent: pending.replacementIntent,
                nowEpoch: nowEpoch
            )
            await refresh()
            infoMessage = simplefin?.hasLinksAwaitingReconnectValidation == true
                ? "SimpleFIN connected and the Setup Token was discarded. Fetch remote accounts to validate and reactivate matching links."
                : "SimpleFIN connected. The Setup Token was discarded."
            return true
        } catch {
            actionError = friendlyMessage(error)
            await refresh()
            return false
        }
    }

    /// Disconnect (§4.6): deletes the Keychain item, marks the connection
    /// disconnected, and preserves links/cursors/import identity as tombstones.
    func disconnectSimpleFIN() async {
        do {
            try await credentialLifecycle.disconnect(nowEpoch: nowEpoch)
            await refresh()
            pendingClaim = nil
            infoMessage = "Disconnected. Local data, links, and cursors were preserved."
        } catch {
            actionError = friendlyMessage(error)
            await refresh()
        }
    }

    // MARK: - Discovery and initial link (§4.4)

    func fetchRemoteAccounts() async -> [RemoteAccountCandidate]? {
        do {
            let fetched = try await syncCoordinator.fetchBalances(
                service: service,
                credentials: credentials,
                nowEpoch: nowEpoch
            )
            let discovered = try fetched.response.accounts.map { account in
                let key = try account.remoteConnectionKey()
                let identity = SimpleFINAccountLink.identity(connectionKey: key, remoteAccountID: account.id)
                return (account: account, connectionKey: key, identity: identity)
            }

            var links = simplefin?.linksByIdentity ?? [:]
            if fetched.response.errors.isEmpty {
                let remoteIdentities = Set(discovered.map { $0.identity })
                let updatedState = try await service.updateSimpleFINState(nowEpoch: nowEpoch) { stored in
                    guard var updated = stored,
                          updated.matchesActiveCredential(fetched.connectionPin) else {
                        throw SyncCoordinatorError.connectionChanged
                    }
                    updated.reactivateLinksAfterIdentityMatch(remoteIdentities)
                    stored = updated
                }
                links = updatedState?.linksByIdentity ?? [:]
                await refresh()
            }

            return discovered.map { discoveredAccount in
                return RemoteAccountCandidate(
                    connectionKey: discoveredAccount.connectionKey,
                    account: discoveredAccount.account,
                    linkedLocalAccountID: links[discoveredAccount.identity]?.localAccountID,
                    providerErrors: fetched.response.errors,
                    connectionPin: fetched.connectionPin
                )
            }
        } catch {
            actionError = friendlyMessage(error)
            await refresh()
            return nil
        }
    }

    /// Performs the full §4.4 initial link for a **new** local account:
    /// balances-only snapshot `B`/`T` (already fetched), anchor
    /// `S = max(T - 90d, start of first month)`, history for `(S, T]`, opening
    /// from the chosen attestation branch, then one atomic import commit and
    /// the cursor set to `T`. Both branches mark `history_incomplete = true`.
    func linkRemoteAccount(
        candidate: RemoteAccountCandidate,
        localName: String,
        type: AccountType,
        onBudget: Bool,
        sign: SimpleFINSignNormalization,
        attestation: LinkAttestation
    ) async -> Bool {
        guard let snapshot else { return false }
        do {
            let now = nowEpoch
            // §4.2 core policy gate: type and requested normalization are
            // already known, so reject before the history request or any
            // mutation. The core APIs and mutation service repeat this check
            // so a direct caller cannot bypass it.
            try SimpleFINSynchronizer.validateSignNormalization(
                accountType: type,
                signNormalization: sign
            )
            // §4.5: a candidate built from an errored discovery response has
            // an untrustworthy B/T — reject before spending the history fetch.
            guard candidate.providerErrors.isEmpty else {
                throw SimpleFINProtocolError.providerReportedErrors(candidate.providerErrors)
            }
            guard let balanceDate = candidate.account.balanceDateEpoch else {
                throw SyncCoordinatorError.missingBalanceDate
            }
            let calendar = try BudgetCalendar(timeZoneIdentifier: snapshot.budget.timeZoneIdentifier)
            let ninetyDays: Int64 = 90 * 86_400
            let requestedStart = try subChecked(balanceDate, ninetyDays)
            let firstMonthStart = try calendar.monthStartEpoch(of: snapshot.budget.firstMonth)
            let anchor = max(requestedStart, firstMonthStart)

            // Network first (outside any database transaction).
            let historyResponse = try await syncCoordinator.fetchHistory(
                service: service,
                credentials: credentials,
                connectionPin: candidate.connectionPin,
                remoteAccountID: candidate.account.id,
                startEpoch: anchor,
                balanceDateEpoch: balanceDate,
                nowEpoch: now
            )
            // Every condition that could otherwise surface mid-commit —
            // provider errors, a missing account block, invalid posted rows,
            // a malformed balance — rejects HERE, before any account exists
            // or a cursor can advance. The original response is preserved
            // untouched for the import below.
            let remoteBlock = try SimpleFINSynchronizer.validateInitialLinkResponse(
                response: historyResponse,
                connectionKey: candidate.connectionKey,
                remoteAccountID: candidate.account.id,
                accountType: type,
                signNormalization: sign,
                calendar: calendar,
                nowEpoch: now
            )

            let openingMilliunits: Milliunits
            switch attestation {
            case .snapshotMinusHistory:
                let calculation = try SimpleFINSynchronizer.initialLinkCalculation(
                    snapshotBalanceDecimalString: candidate.account.balance,
                    history: remoteBlock.transactions,
                    accountType: type,
                    signNormalization: sign,
                    startEpoch: anchor,
                    balanceDateEpoch: balanceDate
                )
                openingMilliunits = try MoneyParser.milliunits(fromDecimalString: calculation.openingBalanceDecimalString)
            case .userOpening(let value):
                openingMilliunits = value
            }

            guard let openingDate = calendar.budgetDate(fromEpoch: anchor) else {
                throw BudgetCalendarError.unrepresentableDate
            }
            let remoteCurrency = candidate.account.currency
            let link = SimpleFINAccountLink(
                connectionKey: candidate.connectionKey,
                remoteAccountID: candidate.account.id,
                localAccountID: nil, // bound inside the commit, or left nil for the §4.4 step 6 pause
                signNormalization: sign
            )

            // §4.4 step 6: a positive computed card opening cannot be
            // normalized into v1 — no legal account can exist, so the pause
            // persists as an account-less link with no cursor and no ledger
            // mutation. Re-linking after the provider state resolves binds an
            // account via the identity upsert. The gate mirrors addAccount's
            // eligibility so the two can never disagree.
            if SimpleFINSynchronizer.positiveCardOpeningRequiresAccountlessPause(
                accountType: type,
                onBudget: onBudget,
                accountCurrency: remoteCurrency,
                budgetCurrency: snapshot.budget.currency,
                openingMilliunits: openingMilliunits
            ) {
                _ = try await service.updateSimpleFINState(nowEpoch: now) { stored in
                    guard var updated = stored,
                          updated.matchesActiveCredential(candidate.connectionPin) else {
                        throw SyncCoordinatorError.connectionChanged
                    }
                    var pausedLink = link
                    pausedLink.pause(
                        reason: .positiveCardSnapshot,
                        message: "The computed card opening is positive after normalization; the link is paused with no local account."
                    )
                    try updated.upsertLinkOrThrow(pausedLink)
                    stored = updated
                }
                await refresh()
                infoMessage = "The link was paused: the computed card opening is positive, which v1 cannot represent. No local account was created; relink once the provider state is resolved."
                return true
            }

            // §2.1: a positive normalized card snapshot with a legal (non-
            // positive) opening still imports the exact (S,T] history and
            // commits cursor T (§4.4 step 7); the bound link pauses so the
            // card stays visible and unsynced until resolved.
            let parsedSnapshot = try MoneyParser.milliunits(fromDecimalString: candidate.account.balance)
            let normalizedSnapshot = parsedSnapshot.multipliedReportingOverflow(by: Int64(sign.rawValue))
            guard !normalizedSnapshot.overflow else { throw SimpleFINProtocolError.arithmeticOverflow }
            let cardSnapshotIsPositive = type == .creditCard && onBudget && normalizedSnapshot.partialValue > 0

            // One atomic commit (§4.4 steps 5–7): account + opening + exact
            // (S,T]-filtered history + import records + link with cursor T.
            // The engine receives the ORIGINAL provider response; validation
            // above guarantees it is error-free and well-formed.
            let commitResult: (accountID: AccountID, pause: SimpleFINLinkPauseReason?) = try await service.syncTransact(
                nowEpoch: now,
                expectedCredentialPin: candidate.connectionPin
            ) { workspace, updated in
                let accountID = try workspace.addAccount(
                    name: localName,
                    type: type,
                    onBudget: onBudget,
                    currency: remoteCurrency,
                    openingBalance: openingMilliunits,
                    openingDate: openingDate,
                    nowEpoch: now
                )
                try workspace.markAccountHistoryIncomplete(accountID)
                var boundLink = link
                boundLink.localAccountID = accountID
                let outcome = try SimpleFINSyncEngine.applyAccountSync(
                    response: historyResponse,
                    link: &boundLink,
                    window: .initialLinkWithSnapshot(
                        startEpoch: anchor,
                        balanceDateEpoch: balanceDate,
                        snapshotBalanceMilliunits: normalizedSnapshot.partialValue
                    ),
                    workspace: &workspace,
                    nowEpoch: now
                )
                // A snapshot discrepancy is an intentional §4.4 outcome: the
                // account, imports, cursor, discrepancy, and paused link must
                // commit together. Other in-commit pauses still indicate a
                // validation gap and roll back the whole initial link.
                guard outcome.pause == nil || outcome.pause == .snapshotDiscrepancy else {
                    throw SimpleFINProtocolError.invalidResponse("initial-link import paused unexpectedly")
                }
                if cardSnapshotIsPositive && outcome.pause == nil {
                    boundLink.pause(
                        reason: .positiveCardSnapshot,
                        message: "The provider reports a positive balance after normalization; sync for this card is paused."
                    )
                }
                try updated.upsertLinkOrThrow(boundLink)
                return (accountID, outcome.pause)
            }
            _ = commitResult.accountID
            await refresh()
            infoMessage = commitResult.pause == .snapshotDiscrepancy
                ? "Linked, but paused: a snapshot discrepancy was recorded for review."
                : cardSnapshotIsPositive
                ? "Linked, but the card link is paused: the provider reports a positive balance."
                : "Linked. Opening balance was derived once; the register now matches the snapshot without double-counting."
            return true
        } catch {
            actionError = friendlyMessage(error)
            await refresh()
            return false
        }
    }

    // MARK: - Sync (§4.3)

    func syncNow() async {
        guard !syncing else { return }
        guard let connectionPin = simplefin?.activeCredentialPin else {
            actionError = friendlyMessage(SyncCoordinatorError.notConnected)
            return
        }
        syncing = true
        defer { syncing = false }
        do {
            let summary = try await syncCoordinator.syncNow(
                service: service,
                credentials: credentials,
                connectionPin: connectionPin,
                nowEpoch: nowEpoch
            )
            await refresh()
            var parts = ["Imported \(summary.importedCount) transaction(s) across \(summary.syncedLinkCount) account(s)."]
            if summary.updatedInPlaceCount > 0 {
                parts.append("\(summary.updatedInPlaceCount) row(s) updated from remote corrections.")
            }
            if summary.conflictCount > 0 {
                parts.append("\(summary.conflictCount) sync conflict(s) need review.")
            }
            if summary.discrepancyCount > 0 {
                parts.append("A balance discrepancy was recorded for review.")
            }
            if summary.skippedPendingCount > 0 {
                parts.append("\(summary.skippedPendingCount) pending row(s) ignored by design.")
            }
            if summary.skippedPausedLinkCount > 0 {
                parts.append("\(summary.skippedPausedLinkCount) paused link(s) skipped.")
            }
            parts.append(contentsOf: summary.pausedLinkMessages)
            parts.append(contentsOf: summary.linkErrorMessages)
            if !summary.providerErrors.isEmpty {
                parts.append(
                    "Provider messages: \(SimpleFINDiagnosticRedactor.summary(summary.providerErrors))"
                )
            }
            lastSyncSummary = SimpleFINDiagnosticRedactor.statusSummary(parts)
        } catch {
            let currentState = try? await service.simpleFINState()
            let connectionStillMatches = currentState?.matchesActiveCredential(connectionPin) == true
            let isConnectionChange = error as? SyncCoordinatorError == .connectionChanged
            let isAuthorizationFailure: Bool
            if case SimpleFINHTTPError.status(let code, _) = error {
                isAuthorizationFailure = code == 401 || code == 403
            } else {
                isAuthorizationFailure = false
            }
            let message = isAuthorizationFailure
                ? friendlyMessage(error)
                : (connectionStillMatches && !isConnectionChange
                    ? friendlyMessage(error)
                    : friendlyMessage(SyncCoordinatorError.connectionChanged))
            lastSyncSummary = nil
            actionError = message
            if connectionStillMatches && !isConnectionChange {
                let now = nowEpoch
                _ = try? await service.updateSimpleFINState(nowEpoch: now) { stored in
                    guard var updated = stored,
                          updated.matchesActiveCredential(connectionPin) else { return }
                    updated.recordConnectionSyncError(message)
                    stored = updated
                }
            }
            await refresh()
        }
    }

    /// §4.3/§6.4: automatic all-account refresh at most once per 24 hours,
    /// measured from both the last successful refresh and the last request
    /// start. The request timestamp matters when a prior attempt failed or
    /// the app was suspended before its completion was persisted. Manual
    /// “Sync Now” is not throttled locally (server 429/Retry-After still wins).
    func autoSyncIfDue() async {
        guard let state = simplefin,
              state.activeCredentialPin != nil else { return }
        let day: Int64 = 24 * 3_600
        let now = nowEpoch
        if let last = state.lastSuccessfulSyncAtEpoch,
           now >= last,
           now - last < day {
            return
        }
        let latestRequestStart: Int64?
        do {
            latestRequestStart = try await service.latestSyncRequestStartedAtEpoch()
        } catch {
            // A failed history read must not turn an activation notification
            // into an unbounded network retry loop.
            return
        }
        if let latestRequestStart,
           now >= latestRequestStart,
           now - latestRequestStart < day {
            return
        }
        await syncNow()
    }

    // MARK: - Link pause state (§2.1)

    /// Explicit reactivation of a hard-paused link. The informational
    /// `closedMonthImportPending` badge clears on its own once no unresolved
    /// closed-month imports remain; every other reason requires this.
    func resumeLink(identity: String) async {
        do {
            let updated = try await service.updateSimpleFINState(nowEpoch: nowEpoch) { stored in
                guard var updated = stored,
                      updated.activeCredentialPin != nil,
                      updated.canManuallyResumeLink(identity: identity),
                      var link = updated.link(identity: identity) else { return }
                link.resume()
                try updated.upsertLinkOrThrow(link)
                stored = updated
            }
            await refresh()
            guard updated?.link(identity: identity)?.status == .active else {
                actionError = "This link remains paused. Resolve its outstanding review item before resuming it."
                return
            }
            infoMessage = "Link resumed. The next sync will pick it up from its cursor."
        } catch {
            actionError = friendlyMessage(error)
        }
    }

    // MARK: - Review queue actions

    /// Resolves one persisted snapshot discrepancy using the exact observed
    /// facts currently shown in the review queue. The core rechecks the
    /// optimistic version and performs the adjustment/pause update atomically.
    func resolveSnapshotDiscrepancy(
        _ discrepancy: SnapshotDiscrepancyRow,
        choice: SnapshotDiscrepancyResolutionChoice
    ) async {
        guard let snapshot else {
            actionError = "The budget is no longer available."
            return
        }
        let command = SnapshotDiscrepancyResolutionCommand(
            budgetID: snapshot.budget.id,
            discrepancyID: discrepancy.id,
            expectedVersion: SnapshotDiscrepancyVersion(discrepancy: discrepancy),
            choice: choice
        )
        do {
            let result = try await service.resolveSnapshotDiscrepancy(command, nowEpoch: nowEpoch)
            await refresh()
            infoMessage = switch result.reason {
            case .adjustment:
                "The balance discrepancy was resolved with an audited adjustment."
            case .manualAttestation:
                "The discrepancy was acknowledged without an accounting adjustment; the attestation is recorded."
            case .accountClosedOffBudget:
                "The account-close workflow is not available from this local review surface."
            }
        } catch {
            actionError = friendlyMessage(error)
            await refresh()
        }
    }

    /// Resolves one persisted sync conflict with a fixed user choice. The
    /// current budget revision is included so stale review cards cannot apply
    /// a decision to a changed workspace.
    func resolveSyncConflict(
        _ conflict: SyncConflictRow,
        choice: SyncConflictResolutionChoice,
        expectedTransactionFingerprint: String? = nil
    ) async {
        guard let snapshot else {
            actionError = "The budget is no longer available."
            return
        }
        let command = SyncConflictResolutionCommand(
            budgetID: snapshot.budget.id,
            conflictID: conflict.id,
            expectedBudgetRevision: snapshot.budget.revision,
            expectedTransactionFingerprint: expectedTransactionFingerprint,
            choice: choice
        )
        do {
            let result = try await service.resolveSyncConflict(command, nowEpoch: nowEpoch)
            await refresh()
            infoMessage = "Sync conflict resolved (\(result.action.rawValue))."
        } catch {
            actionError = friendlyMessage(error)
            await refresh()
        }
    }

    /// Open review-queue counts surfaced in the main window and Settings.
    var openSyncConflictCount: Int {
        snapshot?.syncConflicts.filter { $0.status == .open }.count ?? 0
    }

    var openSnapshotDiscrepancyCount: Int {
        snapshot?.snapshotDiscrepancies.filter { $0.status == .open }.count ?? 0
    }

    var openScheduleReviewCount: Int {
        snapshot?.scheduleReviews.filter { $0.status == .open }.count ?? 0
    }

    var openReviewCount: Int {
        openSyncConflictCount + openSnapshotDiscrepancyCount + openScheduleReviewCount
    }

    /// Expected occurrences whose match window has fully passed (D5.5).
    var overdueScheduleCount: Int {
        guard let snapshot, !snapshot.schedules.isEmpty,
              let workspace = try? BudgetWorkspace(snapshot: snapshot),
              let calendar = try? BudgetCalendar(timeZoneIdentifier: snapshot.budget.timeZoneIdentifier),
              let today = calendar.budgetDate(fromEpoch: nowEpoch) else { return 0 }
        return workspace.expectedOccurrences(in: RecurrenceEngine.adding(days: -400, to: today)...today, asOf: today).filter(\.isOverdue).count
    }
}

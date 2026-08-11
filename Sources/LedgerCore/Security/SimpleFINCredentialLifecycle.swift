import Foundation

/// Fixed lifecycle failures. Cases never carry an underlying error, item
/// identifier, host, or credential-bearing value into diagnostics.
public enum SimpleFINCredentialLifecycleError: Error, Equatable, Sendable {
    case operationAlreadyInProgress
    case pendingOperationConflict
    case credentialDeletionFailed
    case credentialRecoveryFailed

    public static let deletionFailureDiagnostic =
        "SimpleFIN credential cleanup could not be completed. Retry the connection action."
}

/// Narrow persistence seam used by the credential lifecycle. Production
/// delegates to `BudgetMutationService`, preserving it as the sole database
/// writer; tests inject a deterministic faulting actor.
public protocol SimpleFINConnectionStateStore: Sendable {
    func loadConnectionState() async throws -> SimpleFINConnectionState?

    @discardableResult
    func updateConnectionState(
        nowEpoch: Int64,
        _ body: @escaping @Sendable (inout SimpleFINConnectionState?) throws -> Void
    ) async throws -> SimpleFINConnectionState?
}

public struct BudgetMutationSimpleFINConnectionStateStore: SimpleFINConnectionStateStore {
    private let service: BudgetMutationService

    public init(service: BudgetMutationService) {
        self.service = service
    }

    public func loadConnectionState() async throws -> SimpleFINConnectionState? {
        try await service.simpleFINState()
    }

    @discardableResult
    public func updateConnectionState(
        nowEpoch: Int64,
        _ body: @escaping @Sendable (inout SimpleFINConnectionState?) throws -> Void
    ) async throws -> SimpleFINConnectionState? {
        try await service.updateSimpleFINState(nowEpoch: nowEpoch, body)
    }
}

/// Coordinates the cross-store credential saga. SQLite cannot share one
/// transaction with Keychain Services, so each external side effect is
/// bracketed by durable, non-secret intent that makes every partial state
/// idempotently retryable after an error or process restart.
public actor SimpleFINCredentialLifecycle {
    private let credentials: any SimpleFINCredentialStore
    private let states: any SimpleFINConnectionStateStore
    private var operationInProgress = false

    public init(
        credentials: any SimpleFINCredentialStore,
        states: any SimpleFINConnectionStateStore
    ) {
        self.credentials = credentials
        self.states = states
    }

    /// Saves and promotes a claimed credential. The caller supplies a stable
    /// replacement intent so an in-memory claimed credential can retry the
    /// exact same staged operation without incrementing generation twice.
    public func replaceCredential(
        _ credential: SimpleFINCredential,
        intent: SimpleFINCredentialReplacementIntent,
        nowEpoch: Int64
    ) async throws {
        try beginOperation()
        defer { operationInProgress = false }
        try await replaceCredentialImpl(credential, intent: intent, nowEpoch: nowEpoch)
    }

    /// Deletes every reachable item before clearing the primary SQLite
    /// reference. A failed deletion keeps the reference and disconnect gate
    /// intact for a later idempotent retry.
    public func disconnect(nowEpoch: Int64) async throws {
        try beginOperation()
        defer { operationInProgress = false }

        let current = try await states.loadConnectionState()
        guard current != nil else { return }
        if current?.status == .disconnected,
           current?.keychainItemID == nil,
           current?.pendingCredentialReplacement == nil,
           current?.keychainItemIDsPendingDeletion.isEmpty == true,
           current?.credentialDisconnectPending == false,
           current?.links.allSatisfy({ $0.status == .paused }) == true {
            return
        }

        _ = try await states.updateConnectionState(nowEpoch: nowEpoch) { state in
            guard var updated = state else { return }
            updated.credentialDisconnectPending = true
            state = updated
        }
        try await finishDisconnectImpl(nowEpoch: nowEpoch)
    }

    /// Completes durable work left by a prior failure or process exit. It is
    /// safe to call at launch/activation and before a new claim.
    public func retryPendingOperations(nowEpoch: Int64) async throws {
        try beginOperation()
        defer { operationInProgress = false }
        try await retryPendingOperationsImpl(nowEpoch: nowEpoch)
    }

    private func beginOperation() throws {
        guard !operationInProgress else {
            throw SimpleFINCredentialLifecycleError.operationAlreadyInProgress
        }
        operationInProgress = true
    }

    private func replaceCredentialImpl(
        _ credential: SimpleFINCredential,
        intent: SimpleFINCredentialReplacementIntent,
        nowEpoch: Int64
    ) async throws {
        if try await states.loadConnectionState()?.credentialDisconnectPending == true {
            try await finishDisconnectImpl(nowEpoch: nowEpoch)
        }
        try await normalizeCompletedDisconnectLinksImpl(nowEpoch: nowEpoch)

        if let pending = try await states.loadConnectionState()?.pendingCredentialReplacement,
           pending != intent {
            try await recoverReplacementImpl(pending, nowEpoch: nowEpoch)
        }
        try await deleteSupersededItemsImpl(nowEpoch: nowEpoch)

        if let current = try await states.loadConnectionState(),
           current.keychainItemID == intent.itemID,
           current.pendingCredentialReplacement == nil {
            return
        }

        _ = try await states.updateConnectionState(nowEpoch: nowEpoch) { state in
            if var existing = state {
                if let pending = existing.pendingCredentialReplacement, pending != intent {
                    throw SimpleFINCredentialLifecycleError.pendingOperationConflict
                }
                existing.pendingCredentialReplacement = intent
                state = existing
            } else {
                state = SimpleFINConnectionState(
                    status: .disconnected,
                    keychainItemID: nil,
                    baseHost: intent.baseHost,
                    basePort: intent.basePort,
                    credentialGeneration: 0,
                    createdAtEpoch: nowEpoch,
                    pendingCredentialReplacement: intent
                )
            }
        }

        // The new item identifier is durable before this save begins. If the
        // following database promotion fails, recovery can still find it.
        try credentials.save(credential, itemID: intent.itemID)
        try await promoteReplacementImpl(intent, nowEpoch: nowEpoch)
        try await deleteSupersededItemsImpl(nowEpoch: nowEpoch)
    }

    private func retryPendingOperationsImpl(nowEpoch: Int64) async throws {
        if try await states.loadConnectionState()?.credentialDisconnectPending == true {
            try await finishDisconnectImpl(nowEpoch: nowEpoch)
        }
        if let pending = try await states.loadConnectionState()?.pendingCredentialReplacement {
            try await recoverReplacementImpl(pending, nowEpoch: nowEpoch)
        }
        try await deleteSupersededItemsImpl(nowEpoch: nowEpoch)
        try await normalizeCompletedDisconnectLinksImpl(nowEpoch: nowEpoch)
    }

    private func recoverReplacementImpl(
        _ intent: SimpleFINCredentialReplacementIntent,
        nowEpoch: Int64
    ) async throws {
        do {
            _ = try credentials.load(itemID: intent.itemID)
        } catch SimpleFINKeychainError.itemNotFound {
            _ = try await states.updateConnectionState(nowEpoch: nowEpoch) { state in
                guard var updated = state,
                      updated.pendingCredentialReplacement == intent else { return }
                updated.pendingCredentialReplacement = nil
                state = updated
            }
            return
        } catch {
            throw SimpleFINCredentialLifecycleError.credentialRecoveryFailed
        }
        try await promoteReplacementImpl(intent, nowEpoch: nowEpoch)
    }

    private func promoteReplacementImpl(
        _ intent: SimpleFINCredentialReplacementIntent,
        nowEpoch: Int64
    ) async throws {
        _ = try await states.updateConnectionState(nowEpoch: nowEpoch) { state in
            guard var updated = state else {
                throw SimpleFINCredentialLifecycleError.pendingOperationConflict
            }
            if updated.keychainItemID == intent.itemID,
               updated.pendingCredentialReplacement == nil {
                state = updated
                return
            }
            guard updated.pendingCredentialReplacement == intent,
                  !updated.credentialDisconnectPending else {
                throw SimpleFINCredentialLifecycleError.pendingOperationConflict
            }

            let supersededItemID = updated.keychainItemID
            if updated.status == .disconnected {
                // Backward-compatible safety for a pre-M5.7 tombstone that
                // still contains active links: preserve reconnect provenance
                // before the new generation becomes active.
                updated.pauseAllLinksForFullDisconnect()
            }
            updated.keychainItemID = intent.itemID
            updated.pendingCredentialReplacement = nil
            if let supersededItemID,
               supersededItemID != intent.itemID,
               !updated.keychainItemIDsPendingDeletion.contains(supersededItemID) {
                updated.keychainItemIDsPendingDeletion.append(supersededItemID)
            }
            updated.status = .active
            updated.baseHost = intent.baseHost
            updated.basePort = intent.basePort
            updated.credentialGeneration += 1
            updated.credentialAuthorizationRevoked = false
            updated.clearCredentialLifecycleError()
            updated.authRevokedLinkIdentitiesAwaitingReconnect = updated.links
                .filter { $0.status == .paused && $0.pauseReason == .authRevoked }
                .map(\.identity)
                .sorted()
            state = updated
        }
    }

    private func deleteSupersededItemsImpl(nowEpoch: Int64) async throws {
        while let itemID = try await states.loadConnectionState()?.keychainItemIDsPendingDeletion.first {
            do {
                try credentials.delete(itemID: itemID)
            } catch {
                await recordDeletionFailure(nowEpoch: nowEpoch)
                throw SimpleFINCredentialLifecycleError.credentialDeletionFailed
            }
            _ = try await states.updateConnectionState(nowEpoch: nowEpoch) { state in
                guard var updated = state else { return }
                updated.keychainItemIDsPendingDeletion.removeAll { $0 == itemID }
                if updated.lastErrorRedacted == SimpleFINCredentialLifecycleError.deletionFailureDiagnostic {
                    updated.clearCredentialLifecycleError()
                }
                state = updated
            }
        }
    }

    private func finishDisconnectImpl(nowEpoch: Int64) async throws {
        if let intent = try await states.loadConnectionState()?.pendingCredentialReplacement {
            try await deleteForDisconnect(itemID: intent.itemID, nowEpoch: nowEpoch)
            _ = try await states.updateConnectionState(nowEpoch: nowEpoch) { state in
                guard var updated = state,
                      updated.pendingCredentialReplacement == intent else { return }
                updated.pendingCredentialReplacement = nil
                state = updated
            }
        }

        try await deleteSupersededItemsImpl(nowEpoch: nowEpoch)

        if let primaryItemID = try await states.loadConnectionState()?.keychainItemID {
            try await deleteForDisconnect(itemID: primaryItemID, nowEpoch: nowEpoch)
            // Clearing the primary reference and finalizing disconnected
            // happen only after its deletion returned success/not-found.
            _ = try await states.updateConnectionState(nowEpoch: nowEpoch) { state in
                guard var updated = state,
                      updated.keychainItemID == primaryItemID else {
                    throw SimpleFINCredentialLifecycleError.pendingOperationConflict
                }
                updated.keychainItemID = nil
                updated.status = .disconnected
                updated.credentialDisconnectPending = false
                updated.clearCredentialLifecycleError()
                updated.pauseAllLinksForFullDisconnect()
                state = updated
            }
        } else {
            _ = try await states.updateConnectionState(nowEpoch: nowEpoch) { state in
                guard var updated = state else { return }
                updated.status = .disconnected
                updated.credentialDisconnectPending = false
                updated.clearCredentialLifecycleError()
                updated.pauseAllLinksForFullDisconnect()
                state = updated
            }
        }
    }

    /// M5.6 could persist a completed disconnected tombstone while leaving
    /// formerly active links active. Activation recovery upgrades that exact
    /// shape without touching links that were already hard-paused.
    private func normalizeCompletedDisconnectLinksImpl(nowEpoch: Int64) async throws {
        guard let current = try await states.loadConnectionState(),
              current.status == .disconnected,
              current.keychainItemID == nil,
              !current.credentialDisconnectPending,
              current.links.contains(where: { $0.status == .active }) else { return }

        _ = try await states.updateConnectionState(nowEpoch: nowEpoch) { state in
            guard var updated = state,
                  updated.status == .disconnected,
                  updated.keychainItemID == nil,
                  !updated.credentialDisconnectPending else { return }
            updated.pauseAllLinksForFullDisconnect()
            state = updated
        }
    }

    private func deleteForDisconnect(itemID: String, nowEpoch: Int64) async throws {
        do {
            try credentials.delete(itemID: itemID)
        } catch {
            await recordDeletionFailure(nowEpoch: nowEpoch)
            throw SimpleFINCredentialLifecycleError.credentialDeletionFailed
        }
    }

    private func recordDeletionFailure(nowEpoch: Int64) async {
        do {
            _ = try await states.updateConnectionState(nowEpoch: nowEpoch) { state in
                guard var updated = state else { return }
                updated.recordCredentialLifecycleError(
                    SimpleFINCredentialLifecycleError.deletionFailureDiagnostic
                )
                state = updated
            }
        } catch {
            // The deletion error is still surfaced to the caller, and every
            // item identifier remains in its prior durable retry field.
        }
    }
}

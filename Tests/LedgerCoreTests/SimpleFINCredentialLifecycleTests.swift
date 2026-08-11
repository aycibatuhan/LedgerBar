import Foundation
import Testing
@testable import LedgerCore

private enum SyntheticCredentialStoreFailure: Error {
    case save
    case delete
}

private enum SyntheticStateStoreFailure: Error {
    case update
}

private final class FaultingCredentialStore: SimpleFINCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: SimpleFINCredential]
    private var saveFailureCount = 0
    private var failingDeletionIDs: Set<String> = []
    private var savedIDs: [String] = []
    private var deletedIDs: [String] = []

    init(values: [String: SimpleFINCredential] = [:]) {
        self.values = values
    }

    func failNextSave() {
        lock.lock(); defer { lock.unlock() }
        saveFailureCount += 1
    }

    func failDeletion(of itemID: String) {
        lock.lock(); defer { lock.unlock() }
        failingDeletionIDs.insert(itemID)
    }

    func allowDeletion(of itemID: String) {
        lock.lock(); defer { lock.unlock() }
        failingDeletionIDs.remove(itemID)
    }

    func save(_ credential: SimpleFINCredential, itemID: String) throws {
        lock.lock(); defer { lock.unlock() }
        savedIDs.append(itemID)
        if saveFailureCount > 0 {
            saveFailureCount -= 1
            throw SyntheticCredentialStoreFailure.save
        }
        values[itemID] = credential
    }

    func load(itemID: String) throws -> SimpleFINCredential {
        lock.lock(); defer { lock.unlock() }
        guard let value = values[itemID] else { throw SimpleFINKeychainError.itemNotFound }
        return value
    }

    func delete(itemID: String) throws {
        lock.lock(); defer { lock.unlock() }
        deletedIDs.append(itemID)
        if failingDeletionIDs.contains(itemID) {
            throw SyntheticCredentialStoreFailure.delete
        }
        values.removeValue(forKey: itemID)
    }

    func contains(_ itemID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return values[itemID] != nil
    }

    func saveCalls() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return savedIDs
    }

    func deleteCalls() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return deletedIDs
    }
}

private actor FaultingConnectionStateStore: SimpleFINConnectionStateStore {
    private var state: SimpleFINConnectionState?
    private var updateAttempt = 0
    private var failingUpdateAttempts: Set<Int>

    init(state: SimpleFINConnectionState?, failingUpdateAttempts: Set<Int> = []) {
        self.state = state
        self.failingUpdateAttempts = failingUpdateAttempts
    }

    func loadConnectionState() async throws -> SimpleFINConnectionState? {
        state
    }

    func updateConnectionState(
        nowEpoch: Int64,
        _ body: @escaping @Sendable (inout SimpleFINConnectionState?) throws -> Void
    ) async throws -> SimpleFINConnectionState? {
        _ = nowEpoch
        updateAttempt += 1
        if failingUpdateAttempts.remove(updateAttempt) != nil {
            throw SyntheticStateStoreFailure.update
        }
        var candidate = state
        try body(&candidate)
        state = candidate
        return state
    }

    func snapshot() -> SimpleFINConnectionState? { state }
}

@Suite("SimpleFIN credential lifecycle")
struct SimpleFINCredentialLifecycleTests {
    private let oldItemID = "old-item"
    private let newItemID = "new-item"

    private func credential() throws -> SimpleFINCredential {
        let host = try SimpleFINHost(host: SimpleFINURLValidator.officialBridgeHost)
        return try SimpleFINCredential(
            host: host,
            opaquePercentEncodedPathPrefix: "/synthetic",
            existingQueryItems: [],
            existingPercentEncodedQuery: nil,
            username: String(repeating: "u", count: 4),
            password: String(repeating: "p", count: 8),
            approvedHost: host
        )
    }

    private func activeState(itemID: String) -> SimpleFINConnectionState {
        SimpleFINConnectionState(
            status: .active,
            keychainItemID: itemID,
            baseHost: SimpleFINURLValidator.officialBridgeHost,
            basePort: 443,
            credentialGeneration: 1,
            createdAtEpoch: testEpoch
        )
    }

    @Test("explicit trusted hosts are idempotent and omit the official host")
    func explicitTrustedHostState() throws {
        let betaHost = try SimpleFINHost(host: "  beta-bridge.simplefin.org  ")
        var state = activeState(itemID: oldItemID)

        state.addTrustedHost(betaHost)
        state.addTrustedHost(betaHost)
        state.addTrustedHost(try SimpleFINHost(host: SimpleFINURLValidator.officialBridgeHost))

        #expect(state.extraTrustedHosts == [betaHost])

        let roundTripped = try JSONDecoder().decode(
            SimpleFINConnectionState.self,
            from: JSONEncoder().encode(state)
        )
        #expect(roundTripped.extraTrustedHosts == [betaHost])
    }

    private func replacementIntent() -> SimpleFINCredentialReplacementIntent {
        SimpleFINCredentialReplacementIntent(
            itemID: newItemID,
            baseHost: SimpleFINURLValidator.officialBridgeHost,
            basePort: 443
        )
    }

    private func temporaryDatabaseURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledgerbar-credential-lifecycle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("LedgerBar.sqlite")
    }

    private func makePersistentService(at url: URL) async throws -> BudgetMutationService {
        let store = try LedgerWorkspaceStore(databaseURL: url)
        let service = BudgetMutationService(store: store)
        _ = try await service.createBudget(
            name: "Synthetic",
            currency: "USD",
            timeZoneIdentifier: "UTC",
            firstMonth: month("2025-01"),
            currentMonth: month("2025-01"),
            nowEpoch: testEpoch
        )
        return service
    }

    @Test("save failure retains the old primary and a retryable replacement intent")
    func saveFailure() async throws {
        let synthetic = try credential()
        let credentials = FaultingCredentialStore(values: [oldItemID: synthetic])
        credentials.failNextSave()
        let states = FaultingConnectionStateStore(state: activeState(itemID: oldItemID))
        let lifecycle = SimpleFINCredentialLifecycle(credentials: credentials, states: states)

        await #expect(throws: SyntheticCredentialStoreFailure.self) {
            try await lifecycle.replaceCredential(
                synthetic,
                intent: replacementIntent(),
                nowEpoch: testEpoch + 1
            )
        }

        let state = try #require(await states.snapshot())
        #expect(state.keychainItemID == oldItemID)
        #expect(state.pendingCredentialReplacement == replacementIntent())
        #expect(state.credentialGeneration == 1)
        #expect(credentials.contains(oldItemID))
        #expect(!credentials.contains(newItemID))
        #expect(credentials.deleteCalls().isEmpty)
    }

    @Test("database promotion failure keeps both identifiers and retry finishes replacement")
    func databasePromotionFailureThenRetry() async throws {
        let synthetic = try credential()
        let credentials = FaultingCredentialStore(values: [oldItemID: synthetic])
        let states = FaultingConnectionStateStore(
            state: activeState(itemID: oldItemID),
            failingUpdateAttempts: [2]
        )
        let lifecycle = SimpleFINCredentialLifecycle(credentials: credentials, states: states)

        await #expect(throws: SyntheticStateStoreFailure.self) {
            try await lifecycle.replaceCredential(
                synthetic,
                intent: replacementIntent(),
                nowEpoch: testEpoch + 1
            )
        }
        var state = try #require(await states.snapshot())
        #expect(state.keychainItemID == oldItemID)
        #expect(state.pendingCredentialReplacement == replacementIntent())
        #expect(credentials.contains(oldItemID))
        #expect(credentials.contains(newItemID))

        // A new coordinator simulates process restart: the credential value
        // is recovered from the durably referenced Keychain item.
        let recoveredLifecycle = SimpleFINCredentialLifecycle(credentials: credentials, states: states)
        try await recoveredLifecycle.retryPendingOperations(nowEpoch: testEpoch + 2)
        state = try #require(await states.snapshot())
        #expect(state.keychainItemID == newItemID)
        #expect(state.pendingCredentialReplacement == nil)
        #expect(state.keychainItemIDsPendingDeletion.isEmpty)
        #expect(state.credentialGeneration == 2)
        #expect(!credentials.contains(oldItemID))
        #expect(credentials.contains(newItemID))
        #expect(credentials.saveCalls() == [newItemID])
    }

    @Test("superseded deletion failure is fixed, redacted, and retryable")
    func supersededDeletionFailure() async throws {
        let synthetic = try credential()
        let credentials = FaultingCredentialStore(values: [oldItemID: synthetic])
        credentials.failDeletion(of: oldItemID)
        let states = FaultingConnectionStateStore(state: activeState(itemID: oldItemID))
        let lifecycle = SimpleFINCredentialLifecycle(credentials: credentials, states: states)

        await #expect(throws: SimpleFINCredentialLifecycleError.credentialDeletionFailed) {
            try await lifecycle.replaceCredential(
                synthetic,
                intent: replacementIntent(),
                nowEpoch: testEpoch + 1
            )
        }
        var state = try #require(await states.snapshot())
        #expect(state.keychainItemID == newItemID)
        #expect(state.keychainItemIDsPendingDeletion == [oldItemID])
        #expect(state.lastErrorRedacted == SimpleFINCredentialLifecycleError.deletionFailureDiagnostic)
        #expect(!SimpleFINCredentialLifecycleError.deletionFailureDiagnostic.contains(oldItemID))

        credentials.allowDeletion(of: oldItemID)
        let recoveredLifecycle = SimpleFINCredentialLifecycle(credentials: credentials, states: states)
        try await recoveredLifecycle.retryPendingOperations(nowEpoch: testEpoch + 2)
        state = try #require(await states.snapshot())
        #expect(state.keychainItemIDsPendingDeletion.isEmpty)
        #expect(state.lastErrorRedacted == nil)
        #expect(!credentials.contains(oldItemID))
    }

    @Test("replacement preserves links and defers authorization resume until identity match")
    func replacementPreservesLinkState() async throws {
        let synthetic = try credential()
        let credentials = FaultingCredentialStore(values: [oldItemID: synthetic])
        let retainedAccountID = AccountID()
        var authorizationLink = SimpleFINAccountLink(
            connectionKey: "synthetic-connection-a",
            remoteAccountID: "synthetic-account-a",
            localAccountID: retainedAccountID,
            lastSuccessfulPostedEpoch: testEpoch,
            status: .paused,
            pauseReason: .authRevoked,
            lastErrorRedacted: "Synthetic authorization failure."
        )
        let protocolLink = SimpleFINAccountLink(
            connectionKey: "synthetic-connection-b",
            remoteAccountID: "synthetic-account-b",
            localAccountID: AccountID(),
            lastSuccessfulPostedEpoch: testEpoch - 1,
            status: .paused,
            pauseReason: .protocolError,
            lastErrorRedacted: "Synthetic protocol failure."
        )
        var initial = activeState(itemID: oldItemID)
        initial.links = [authorizationLink, protocolLink]
        let states = FaultingConnectionStateStore(state: initial)
        let lifecycle = SimpleFINCredentialLifecycle(credentials: credentials, states: states)

        try await lifecycle.replaceCredential(
            synthetic,
            intent: replacementIntent(),
            nowEpoch: testEpoch + 1
        )

        var state = try #require(await states.snapshot())
        authorizationLink = try #require(state.link(identity: authorizationLink.identity))
        #expect(authorizationLink.status == .paused)
        #expect(authorizationLink.pauseReason == .authRevoked)
        #expect(authorizationLink.localAccountID == retainedAccountID)
        #expect(authorizationLink.lastSuccessfulPostedEpoch == testEpoch)
        let retainedProtocolLink = try #require(state.link(identity: protocolLink.identity))
        #expect(retainedProtocolLink == protocolLink)
        #expect(state.authRevokedLinkIdentitiesAwaitingReconnect == [authorizationLink.identity])

        state.reactivateLinksAfterIdentityMatch([authorizationLink.identity, protocolLink.identity])
        authorizationLink = try #require(state.link(identity: authorizationLink.identity))
        #expect(authorizationLink.status == .active)
        #expect(authorizationLink.pauseReason == nil)
        #expect(state.link(identity: protocolLink.identity) == protocolLink)
    }

    @Test("reconnect reuses tombstones and reactivates only matching eligible links")
    func reconnectIdentityMatchingMatrix() async throws {
        let synthetic = try credential()
        let credentials = FaultingCredentialStore()
        let matchedAccountID = AccountID()
        let matched = SimpleFINAccountLink(
            connectionKey: "synthetic-connection-a",
            remoteAccountID: "synthetic-account-a",
            localAccountID: matchedAccountID,
            lastSuccessfulPostedEpoch: testEpoch,
            status: .paused
        )
        let unmatched = SimpleFINAccountLink(
            connectionKey: "synthetic-connection-b",
            remoteAccountID: "synthetic-account-b",
            localAccountID: AccountID(),
            lastSuccessfulPostedEpoch: testEpoch - 1,
            status: .paused
        )
        let informational = SimpleFINAccountLink(
            connectionKey: "synthetic-connection-c",
            remoteAccountID: "synthetic-account-c",
            localAccountID: AccountID(),
            lastSuccessfulPostedEpoch: testEpoch - 2,
            status: .paused,
            pauseReason: .closedMonthImportPending,
            lastErrorRedacted: "Synthetic closed-month notice."
        )
        let authorization = SimpleFINAccountLink(
            connectionKey: "synthetic-connection-d",
            remoteAccountID: "synthetic-account-d",
            localAccountID: AccountID(),
            lastSuccessfulPostedEpoch: testEpoch - 3,
            status: .paused,
            pauseReason: .authRevoked,
            lastErrorRedacted: "Synthetic authorization failure."
        )
        let protocolPause = SimpleFINAccountLink(
            connectionKey: "synthetic-connection-e",
            remoteAccountID: "synthetic-account-e",
            localAccountID: AccountID(),
            lastSuccessfulPostedEpoch: testEpoch - 4,
            status: .paused,
            pauseReason: .protocolError,
            lastErrorRedacted: "Synthetic protocol failure."
        )
        let positiveCardPause = SimpleFINAccountLink(
            connectionKey: "synthetic-connection-f",
            remoteAccountID: "synthetic-account-f",
            localAccountID: nil,
            status: .paused,
            pauseReason: .positiveCardSnapshot,
            lastErrorRedacted: "Synthetic positive-card pause."
        )
        let links = [matched, unmatched, informational, authorization, protocolPause, positiveCardPause]
        var disconnected = SimpleFINConnectionState(
            status: .disconnected,
            keychainItemID: nil,
            baseHost: SimpleFINURLValidator.officialBridgeHost,
            basePort: 443,
            credentialGeneration: 1,
            createdAtEpoch: testEpoch,
            links: links,
            credentialAuthorizationRevoked: true,
            disconnectPausedLinkIdentities: [matched.identity, unmatched.identity, informational.identity]
        )

        // A matching response in the revoked generation cannot clear auth.
        disconnected.reactivateLinksAfterIdentityMatch([authorization.identity])
        #expect(disconnected.link(identity: authorization.identity) == authorization)

        let states = FaultingConnectionStateStore(state: disconnected)
        let lifecycle = SimpleFINCredentialLifecycle(credentials: credentials, states: states)
        try await lifecycle.replaceCredential(
            synthetic,
            intent: replacementIntent(),
            nowEpoch: testEpoch + 1
        )

        var state = try #require(await states.snapshot())
        #expect(state.status == .active)
        #expect(state.credentialGeneration == 2)
        #expect(!state.credentialAuthorizationRevoked)
        #expect(state.activeCredentialPin != nil)
        #expect(state.createdAtEpoch == testEpoch)
        #expect(state.links == links)
        #expect(state.authRevokedLinkIdentitiesAwaitingReconnect == [authorization.identity])

        var revokedAgainInSameGeneration = state
        revokedAgainInSameGeneration.markCredentialAuthorizationRevoked()
        #expect(revokedAgainInSameGeneration.credentialAuthorizationRevoked)
        #expect(revokedAgainInSameGeneration.authRevokedLinkIdentitiesAwaitingReconnect.isEmpty)
        revokedAgainInSameGeneration.reactivateLinksAfterIdentityMatch([authorization.identity])
        #expect(revokedAgainInSameGeneration.link(identity: authorization.identity) == authorization)

        let matchingIdentities: Set<String> = [
            matched.identity,
            informational.identity,
            authorization.identity,
            protocolPause.identity,
            positiveCardPause.identity
        ]
        _ = try await states.updateConnectionState(nowEpoch: testEpoch + 2) { stored in
            guard var updated = stored else { return }
            updated.reactivateLinksAfterIdentityMatch(matchingIdentities)
            stored = updated
        }

        state = try #require(await states.snapshot())
        let reactivatedMatched = try #require(state.link(identity: matched.identity))
        #expect(reactivatedMatched.status == .active)
        #expect(reactivatedMatched.localAccountID == matchedAccountID)
        #expect(reactivatedMatched.lastSuccessfulPostedEpoch == testEpoch)
        #expect(state.link(identity: unmatched.identity) == unmatched)
        #expect(state.disconnectPausedLinkIdentities == [unmatched.identity])
        let reactivatedInformational = try #require(state.link(identity: informational.identity))
        #expect(reactivatedInformational.status == .active)
        #expect(reactivatedInformational.pauseReason == .closedMonthImportPending)
        #expect(reactivatedInformational.lastErrorRedacted == informational.lastErrorRedacted)
        #expect(state.link(identity: authorization.identity)?.status == .active)
        #expect(state.link(identity: authorization.identity)?.pauseReason == nil)
        #expect(state.link(identity: protocolPause.identity) == protocolPause)
        #expect(state.link(identity: positiveCardPause.identity) == positiveCardPause)
        #expect(state.authRevokedLinkIdentitiesAwaitingReconnect.isEmpty)

        try await lifecycle.retryPendingOperations(nowEpoch: testEpoch + 3)
        state = try #require(await states.snapshot())
        #expect(state.credentialGeneration == 2)
        #expect(state.links.count == links.count)
        #expect(credentials.saveCalls() == [newItemID])

        // A second disconnect before the unmatched identity returns must
        // retain that prior marker while unioning links reactivated above.
        try await lifecycle.disconnect(nowEpoch: testEpoch + 4)
        state = try #require(await states.snapshot())
        #expect(state.status == .disconnected)
        #expect(Set(state.disconnectPausedLinkIdentities) == Set([
            matched.identity,
            unmatched.identity,
            informational.identity,
            authorization.identity
        ]))
        #expect(state.link(identity: protocolPause.identity) == protocolPause)
        #expect(state.link(identity: positiveCardPause.identity) == positiveCardPause)
    }

    @Test("disconnect clears the primary reference only after deletion")
    func disconnectSuccess() async throws {
        let synthetic = try credential()
        let credentials = FaultingCredentialStore(values: [oldItemID: synthetic])
        let retainedLink = SimpleFINAccountLink(
            connectionKey: "synthetic-connection",
            remoteAccountID: "synthetic-account",
            localAccountID: AccountID(),
            lastSuccessfulPostedEpoch: testEpoch
        )
        var initial = activeState(itemID: oldItemID)
        initial.links = [retainedLink]
        let states = FaultingConnectionStateStore(state: initial)
        let lifecycle = SimpleFINCredentialLifecycle(credentials: credentials, states: states)

        try await lifecycle.disconnect(nowEpoch: testEpoch + 1)

        let state = try #require(await states.snapshot())
        #expect(state.status == .disconnected)
        #expect(state.keychainItemID == nil)
        #expect(!state.credentialDisconnectPending)
        let disconnectedLink = try #require(state.link(identity: retainedLink.identity))
        #expect(disconnectedLink.status == .paused)
        #expect(disconnectedLink.pauseReason == retainedLink.pauseReason)
        #expect(disconnectedLink.localAccountID == retainedLink.localAccountID)
        #expect(disconnectedLink.lastSuccessfulPostedEpoch == retainedLink.lastSuccessfulPostedEpoch)
        #expect(state.links.allSatisfy { $0.status == .paused })
        #expect(state.disconnectPausedLinkIdentities == [retainedLink.identity])
        #expect(!credentials.contains(oldItemID))
        #expect(credentials.deleteCalls() == [oldItemID])
    }

    @Test("full disconnect preserves the complete workspace and durable link tombstone")
    func fullDisconnectPreservesPersistentWorkspace() async throws {
        let databaseURL = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
        let service = try await makePersistentService(at: databaseURL)
        let seeded = try await service.transact(nowEpoch: testEpoch + 1) { workspace in
            let accountID = try workspace.addAccount(
                name: "Synthetic Tracking",
                type: .other,
                onBudget: false,
                currency: "USD",
                openingBalance: usd(0),
                openingDate: date("2025-01-02"),
                nowEpoch: testEpoch
            )
            let transactionID = try workspace.importPostedTransaction(
                accountID: accountID,
                connectionKey: "synthetic-connection",
                remoteAccountID: "synthetic-account",
                remoteTransactionID: "synthetic-transaction",
                postedEpoch: testEpoch + 3 * 86_400,
                payeeName: "Synthetic Payee",
                amountMilliunits: usd(-12),
                nowEpoch: testEpoch + 1
            )
            return (accountID, transactionID)
        }
        let link = SimpleFINAccountLink(
            connectionKey: "synthetic-connection",
            remoteAccountID: "synthetic-account",
            localAccountID: seeded.0,
            lastSuccessfulPostedEpoch: testEpoch + 3 * 86_400
        )
        _ = try await service.updateSimpleFINState(nowEpoch: testEpoch + 2) { state in
            var connected = activeState(itemID: oldItemID)
            connected.links = [link]
            state = connected
        }
        let before = try #require(await service.currentSnapshot())
        #expect(before.transactions.contains { $0.id == seeded.1 })
        #expect(before.simpleFINImports.contains { $0.transactionID == seeded.1 })

        let synthetic = try credential()
        let credentials = FaultingCredentialStore(values: [oldItemID: synthetic])
        let lifecycle = SimpleFINCredentialLifecycle(
            credentials: credentials,
            states: BudgetMutationSimpleFINConnectionStateStore(service: service)
        )
        try await lifecycle.disconnect(nowEpoch: testEpoch + 3)

        let after = try #require(await service.currentSnapshot())
        #expect(after == before)
        let disconnected = try #require(try await service.simpleFINState())
        #expect(disconnected.status == .disconnected)
        #expect(disconnected.keychainItemID == nil)
        let tombstone = try #require(disconnected.link(identity: link.identity))
        #expect(tombstone.status == .paused)
        #expect(tombstone.localAccountID == link.localAccountID)
        #expect(tombstone.lastSuccessfulPostedEpoch == link.lastSuccessfulPostedEpoch)
        #expect(disconnected.disconnectPausedLinkIdentities == [link.identity])
        #expect(throws: SimpleFINKeychainError.itemNotFound) {
            _ = try credentials.load(itemID: oldItemID)
        }

        let coldStore = try LedgerWorkspaceStore(databaseURL: databaseURL)
        let coldWorkspace = try coldStore.loadFirstWorkspace().snapshot()
        #expect(coldWorkspace == before)
        let coldState = try coldStore.loadSimpleFINState(budgetID: before.budget.id)
        #expect(coldState == disconnected)
    }

    @Test("old-generation and authorization-rejected responses cannot commit")
    func oldGenerationResponseCannotCommit() async throws {
        let databaseURL = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
        let service = try await makePersistentService(at: databaseURL)
        let accountID = try await service.transact(nowEpoch: testEpoch + 1) { workspace in
            try workspace.addAccount(
                name: "Synthetic Tracking",
                type: .other,
                onBudget: false,
                currency: "USD",
                openingBalance: usd(0),
                openingDate: date("2025-01-02"),
                nowEpoch: testEpoch
            )
        }
        let link = SimpleFINAccountLink(
            connectionKey: "synthetic-connection",
            remoteAccountID: "synthetic-account",
            localAccountID: accountID,
            lastSuccessfulPostedEpoch: testEpoch
        )
        let oldPin = SimpleFINConnectionPin(itemID: oldItemID, credentialGeneration: 1)
        _ = try await service.updateSimpleFINState(nowEpoch: testEpoch + 2) { state in
            var connected = activeState(itemID: oldItemID)
            connected.links = [link]
            state = connected
        }

        let synthetic = try credential()
        let credentials = FaultingCredentialStore(values: [oldItemID: synthetic])
        let lifecycle = SimpleFINCredentialLifecycle(
            credentials: credentials,
            states: BudgetMutationSimpleFINConnectionStateStore(service: service)
        )
        try await lifecycle.disconnect(nowEpoch: testEpoch + 3)
        try await lifecycle.replaceCredential(
            synthetic,
            intent: replacementIntent(),
            nowEpoch: testEpoch + 4
        )
        let workspaceBeforeResponse = try #require(await service.currentSnapshot())
        let stateBeforeResponse = try #require(try await service.simpleFINState())
        #expect(stateBeforeResponse.credentialGeneration == 2)
        #expect(!stateBeforeResponse.matchesActiveCredential(oldPin))

        await #expect(throws: SimpleFINConnectionPinError.connectionChanged) {
            _ = try await service.syncTransact(
                nowEpoch: testEpoch + 5,
                expectedCredentialPin: oldPin
            ) { workspace, state in
                _ = try workspace.importPostedTransaction(
                    accountID: accountID,
                    connectionKey: link.connectionKey,
                    remoteAccountID: link.remoteAccountID,
                    remoteTransactionID: "stale-transaction",
                    postedEpoch: testEpoch + 4 * 86_400,
                    payeeName: "Synthetic Stale Payee",
                    amountMilliunits: usd(-5),
                    nowEpoch: testEpoch + 5
                )
                guard var staleLink = state.link(identity: link.identity) else {
                    throw SimpleFINConnectionPinError.connectionChanged
                }
                staleLink.lastSuccessfulPostedEpoch = testEpoch + 4 * 86_400
                state.upsertLink(staleLink)
            }
        }

        #expect(await service.currentSnapshot() == workspaceBeforeResponse)
        #expect(try await service.simpleFINState() == stateBeforeResponse)

        // A 401/403 from the newly promoted generation must also reject every
        // other response that captured its pin before authorization failed.
        let rejectedPin = try #require(stateBeforeResponse.activeCredentialPin)
        _ = try await service.updateSimpleFINState(nowEpoch: testEpoch + 6) { stored in
            guard var updated = stored,
                  updated.matchesActiveCredential(rejectedPin) else {
                throw SimpleFINConnectionPinError.connectionChanged
            }
            updated.markCredentialAuthorizationRevoked()
            stored = updated
        }
        let authorizationRejectedState = try #require(try await service.simpleFINState())
        #expect(authorizationRejectedState.credentialAuthorizationRevoked)
        #expect(authorizationRejectedState.activeCredentialPin == nil)
        #expect(authorizationRejectedState.link(identity: link.identity)?.status == .paused)
        #expect(authorizationRejectedState.disconnectPausedLinkIdentities == [link.identity])

        await #expect(throws: SimpleFINConnectionPinError.connectionChanged) {
            _ = try await service.syncTransact(
                nowEpoch: testEpoch + 7,
                expectedCredentialPin: rejectedPin
            ) { workspace, state in
                _ = try workspace.importPostedTransaction(
                    accountID: accountID,
                    connectionKey: link.connectionKey,
                    remoteAccountID: link.remoteAccountID,
                    remoteTransactionID: "authorization-stale-transaction",
                    postedEpoch: testEpoch + 5 * 86_400,
                    payeeName: "Synthetic Rejected Payee",
                    amountMilliunits: usd(-7),
                    nowEpoch: testEpoch + 7
                )
                guard var staleLink = state.link(identity: link.identity) else {
                    throw SimpleFINConnectionPinError.connectionChanged
                }
                staleLink.lastSuccessfulPostedEpoch = testEpoch + 5 * 86_400
                state.upsertLink(staleLink)
            }
        }
        await #expect(throws: SimpleFINConnectionPinError.connectionChanged) {
            _ = try await service.updateSimpleFINState(nowEpoch: testEpoch + 8) { stored in
                guard var updated = stored,
                      updated.matchesActiveCredential(rejectedPin) else {
                    throw SimpleFINConnectionPinError.connectionChanged
                }
                updated.reactivateLinksAfterIdentityMatch([link.identity])
                stored = updated
            }
        }

        #expect(await service.currentSnapshot() == workspaceBeforeResponse)
        #expect(try await service.simpleFINState() == authorizationRejectedState)
        let coldStore = try LedgerWorkspaceStore(databaseURL: databaseURL)
        #expect(try coldStore.loadFirstWorkspace().snapshot() == workspaceBeforeResponse)
        #expect(
            try coldStore.loadSimpleFINState(budgetID: workspaceBeforeResponse.budget.id)
                == authorizationRejectedState
        )
    }

    @Test("disconnect deletes replacement and superseded items before the primary")
    func disconnectDeletesEveryReachableItem() async throws {
        let synthetic = try credential()
        let supersededItemID = "superseded-item"
        let credentials = FaultingCredentialStore(values: [
            oldItemID: synthetic,
            newItemID: synthetic,
            supersededItemID: synthetic
        ])
        var initial = activeState(itemID: oldItemID)
        initial.pendingCredentialReplacement = replacementIntent()
        initial.keychainItemIDsPendingDeletion = [supersededItemID]
        let states = FaultingConnectionStateStore(state: initial)
        let lifecycle = SimpleFINCredentialLifecycle(credentials: credentials, states: states)

        try await lifecycle.disconnect(nowEpoch: testEpoch + 1)

        let state = try #require(await states.snapshot())
        #expect(state.status == .disconnected)
        #expect(state.keychainItemID == nil)
        #expect(state.pendingCredentialReplacement == nil)
        #expect(state.keychainItemIDsPendingDeletion.isEmpty)
        #expect(state.links.allSatisfy { $0.status == .paused })
        #expect(credentials.deleteCalls() == [newItemID, supersededItemID, oldItemID])
    }

    @Test("disconnect deletion failure preserves the primary reference for retry")
    func disconnectDeletionFailure() async throws {
        let synthetic = try credential()
        let credentials = FaultingCredentialStore(values: [oldItemID: synthetic])
        credentials.failDeletion(of: oldItemID)
        let retainedLink = SimpleFINAccountLink(
            connectionKey: "synthetic-connection",
            remoteAccountID: "synthetic-account",
            localAccountID: AccountID(),
            lastSuccessfulPostedEpoch: testEpoch
        )
        var initial = activeState(itemID: oldItemID)
        initial.links = [retainedLink]
        let states = FaultingConnectionStateStore(state: initial)
        let lifecycle = SimpleFINCredentialLifecycle(credentials: credentials, states: states)

        await #expect(throws: SimpleFINCredentialLifecycleError.credentialDeletionFailed) {
            try await lifecycle.disconnect(nowEpoch: testEpoch + 1)
        }
        var state = try #require(await states.snapshot())
        #expect(state.status == .active)
        #expect(state.keychainItemID == oldItemID)
        #expect(state.credentialDisconnectPending)
        #expect(state.link(identity: retainedLink.identity) == retainedLink)
        #expect(state.disconnectPausedLinkIdentities.isEmpty)
        #expect(state.lastErrorRedacted == SimpleFINCredentialLifecycleError.deletionFailureDiagnostic)

        credentials.allowDeletion(of: oldItemID)
        try await lifecycle.retryPendingOperations(nowEpoch: testEpoch + 2)
        state = try #require(await states.snapshot())
        #expect(state.status == .disconnected)
        #expect(state.keychainItemID == nil)
        #expect(!state.credentialDisconnectPending)
        #expect(state.link(identity: retainedLink.identity)?.status == .paused)
        #expect(state.disconnectPausedLinkIdentities == [retainedLink.identity])
    }

    @Test("database finalization failure after delete retries idempotently")
    func disconnectDatabaseFinalizationFailure() async throws {
        let synthetic = try credential()
        let credentials = FaultingCredentialStore(values: [oldItemID: synthetic])
        let retainedLink = SimpleFINAccountLink(
            connectionKey: "synthetic-connection",
            remoteAccountID: "synthetic-account",
            localAccountID: AccountID(),
            lastSuccessfulPostedEpoch: testEpoch
        )
        var initial = activeState(itemID: oldItemID)
        initial.links = [retainedLink]
        let states = FaultingConnectionStateStore(
            state: initial,
            failingUpdateAttempts: [2]
        )
        let lifecycle = SimpleFINCredentialLifecycle(credentials: credentials, states: states)

        await #expect(throws: SyntheticStateStoreFailure.self) {
            try await lifecycle.disconnect(nowEpoch: testEpoch + 1)
        }
        var state = try #require(await states.snapshot())
        #expect(state.status == .active)
        #expect(state.keychainItemID == oldItemID)
        #expect(state.credentialDisconnectPending)
        #expect(state.link(identity: retainedLink.identity) == retainedLink)
        #expect(state.disconnectPausedLinkIdentities.isEmpty)
        #expect(!credentials.contains(oldItemID))

        try await lifecycle.retryPendingOperations(nowEpoch: testEpoch + 2)
        state = try #require(await states.snapshot())
        #expect(state.status == .disconnected)
        #expect(state.keychainItemID == nil)
        #expect(state.link(identity: retainedLink.identity)?.status == .paused)
        #expect(state.disconnectPausedLinkIdentities == [retainedLink.identity])
        #expect(credentials.deleteCalls() == [oldItemID, oldItemID])
    }

    @Test("legacy state blobs decode with empty lifecycle recovery fields")
    func legacyStateDecode() throws {
        let data = Data("""
        {
          "status": "active",
          "keychainItemID": "opaque-item",
          "baseHost": "bridge.simplefin.org",
          "basePort": 443,
          "credentialGeneration": 1,
          "createdAtEpoch": 1,
          "links": [],
          "extraTrustedHosts": []
        }
        """.utf8)
        let state = try JSONDecoder().decode(SimpleFINConnectionState.self, from: data)
        #expect(state.pendingCredentialReplacement == nil)
        #expect(state.keychainItemIDsPendingDeletion.isEmpty)
        #expect(!state.credentialDisconnectPending)
        #expect(!state.credentialAuthorizationRevoked)
        #expect(state.disconnectPausedLinkIdentities.isEmpty)
        #expect(state.authRevokedLinkIdentitiesAwaitingReconnect.isEmpty)

        var preGateState = activeState(itemID: oldItemID)
        preGateState.links = [SimpleFINAccountLink(
            connectionKey: "synthetic-connection",
            remoteAccountID: "synthetic-account",
            localAccountID: AccountID(),
            lastSuccessfulPostedEpoch: testEpoch,
            status: .paused,
            pauseReason: .authRevoked,
            lastErrorRedacted: "Synthetic authorization failure."
        )]
        let encoded = try JSONEncoder().encode(preGateState)
        var legacyObject = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        legacyObject.removeValue(forKey: "credentialAuthorizationRevoked")
        let legacyRevoked = try JSONDecoder().decode(
            SimpleFINConnectionState.self,
            from: JSONSerialization.data(withJSONObject: legacyObject)
        )
        #expect(legacyRevoked.credentialAuthorizationRevoked)
        #expect(legacyRevoked.activeCredentialPin == nil)
    }

    @Test("recovery upgrades a pre-5.7 disconnected blob with active links")
    func legacyDisconnectedLinkRecovery() async throws {
        let link = SimpleFINAccountLink(
            connectionKey: "synthetic-connection",
            remoteAccountID: "synthetic-account",
            localAccountID: AccountID(),
            lastSuccessfulPostedEpoch: testEpoch
        )
        var legacy = activeState(itemID: oldItemID)
        legacy.status = .disconnected
        legacy.keychainItemID = nil
        legacy.links = [link]
        let states = FaultingConnectionStateStore(state: legacy)
        let lifecycle = SimpleFINCredentialLifecycle(
            credentials: FaultingCredentialStore(),
            states: states
        )

        try await lifecycle.retryPendingOperations(nowEpoch: testEpoch + 1)

        let recovered = try #require(await states.snapshot())
        #expect(recovered.status == .disconnected)
        #expect(recovered.credentialGeneration == 1)
        #expect(recovered.link(identity: link.identity)?.status == .paused)
        #expect(recovered.disconnectPausedLinkIdentities == [link.identity])
        #expect(recovered.link(identity: link.identity)?.localAccountID == link.localAccountID)
        #expect(recovered.link(identity: link.identity)?.lastSuccessfulPostedEpoch == testEpoch)
    }

    @Test("connection pins reject disconnect and replacement generations")
    func connectionPinInvalidation() throws {
        var state = activeState(itemID: oldItemID)
        let activeLink = SimpleFINAccountLink(
            connectionKey: "synthetic-connection",
            remoteAccountID: "synthetic-account",
            localAccountID: AccountID(),
            lastSuccessfulPostedEpoch: testEpoch
        )
        state.links = [activeLink]
        let pin = try #require(state.activeCredentialPin)
        #expect(state.matchesActiveCredential(pin))

        state.credentialDisconnectPending = true
        #expect(state.activeCredentialPin == nil)
        #expect(!state.matchesActiveCredential(pin))

        state.credentialDisconnectPending = false
        state.markCredentialAuthorizationRevoked()
        #expect(state.credentialAuthorizationRevoked)
        #expect(state.activeCredentialPin == nil)
        #expect(!state.matchesActiveCredential(pin))
        #expect(state.link(identity: activeLink.identity)?.status == .paused)
        #expect(state.link(identity: activeLink.identity)?.pauseReason == .authRevoked)
        #expect(state.link(identity: activeLink.identity)?.localAccountID == activeLink.localAccountID)
        #expect(state.link(identity: activeLink.identity)?.lastSuccessfulPostedEpoch == testEpoch)

        state.credentialAuthorizationRevoked = false
        state.keychainItemID = newItemID
        state.credentialGeneration += 1
        #expect(!state.matchesActiveCredential(pin))
    }

    @Test("sync diagnostics cannot hide a pending credential deletion failure")
    func deletionDiagnosticPrecedence() {
        var state = activeState(itemID: newItemID)
        state.keychainItemIDsPendingDeletion = [oldItemID]
        state.recordCredentialLifecycleError(
            SimpleFINCredentialLifecycleError.deletionFailureDiagnostic
        )

        state.clearLastErrorAfterSuccessfulSync()
        #expect(state.lastErrorRedacted == SimpleFINCredentialLifecycleError.deletionFailureDiagnostic)
        state.recordConnectionSyncError("Synthetic sync failure.")
        #expect(state.lastErrorRedacted == SimpleFINCredentialLifecycleError.deletionFailureDiagnostic)

        state.keychainItemIDsPendingDeletion = []
        state.clearLastErrorAfterSuccessfulSync()
        #expect(state.lastErrorRedacted == nil)
        state.recordConnectionSyncError("Synthetic sync failure.")
        #expect(state.lastErrorRedacted == "Synthetic sync failure.")
    }
}

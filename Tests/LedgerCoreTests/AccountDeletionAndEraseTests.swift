import Foundation
import GRDB
import Testing
@testable import LedgerCore

private final class RecordingCredentialStore: SimpleFINCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var deleted: [String] = []
    var failDeletes = false
    func save(_ credential: SimpleFINCredential, itemID: String) throws {}
    func load(itemID: String) throws -> SimpleFINCredential { throw SimpleFINProtocolError.missingCredential }
    func delete(itemID: String) throws {
        if failDeletes { throw SimpleFINProtocolError.missingCredential }
        lock.lock(); deleted.append(itemID); lock.unlock()
    }
    var deletedIDs: [String] { lock.lock(); defer { lock.unlock() }; return deleted }
}

@Suite("Deleting closed accounts and erasing all data")
struct AccountDeletionAndEraseTests {

    @Test("Only closed accounts can be deleted, and deletion is audited")
    func guards() throws {
        var ws = try makeWorkspace(timeZone: "UTC")
        let open = try ws.addAccount(name: "Open", type: .checking, onBudget: true,
                                     openingBalance: usd(10), openingDate: date("2025-01-01"), nowEpoch: testEpoch)
        #expect(throws: MutationError.accountNotClosed) { try ws.deleteClosedAccount(accountID: open, nowEpoch: testEpoch) }
        #expect(throws: MutationError.accountNotFound) { try ws.deleteClosedAccount(accountID: AccountID(), nowEpoch: testEpoch) }

        let dup = try ws.addAccount(name: "Dup", type: .checking, onBudget: true,
                                    openingBalance: 0, openingDate: date("2025-01-01"), nowEpoch: testEpoch)
        try ws.closeAccount(accountID: dup, nowEpoch: testEpoch)
        let before = ws
        #expect(throws: Never.self) { try ws.deleteClosedAccount(accountID: dup, nowEpoch: testEpoch) }
        #expect(ws.accounts[dup] == nil)
        #expect(ws.budget.revision == before.budget.revision + 1)
        #expect(ws.auditEvents.contains { $0.eventKind == "accountDeleted" && $0.entityID == dup.description })
    }

    @Test("Void-closed duplicate is removed with its rows, imports, review items, schedules, and rules; other data is untouched")
    func removesEverythingOwned() throws {
        var ws = try makeWorkspace(timeZone: "UTC")
        let keep = try ws.addAccount(name: "Checking", type: .checking, onBudget: true,
                                     openingBalance: usd(300), openingDate: date("2025-01-01"), nowEpoch: testEpoch)
        let dup = try ws.addAccount(name: "Checking (dup)", type: .checking, onBudget: true,
                                    openingBalance: usd(300), openingDate: date("2025-01-01"), nowEpoch: testEpoch)
        let posted = try ws.calendar.noonEpoch(of: date("2025-01-06"))
        let imported = try ws.importPostedTransaction(accountID: dup, connectionKey: "c", remoteAccountID: "dup", remoteTransactionID: "t1",
                                                      postedEpoch: posted, payeeName: "Grocer", amountMilliunits: -usd(20), nowEpoch: testEpoch)
        _ = try ws.importPostedTransaction(accountID: keep, connectionKey: "c", remoteAccountID: "chk", remoteTransactionID: "t1",
                                           postedEpoch: posted, payeeName: "Grocer", amountMilliunits: -usd(20), nowEpoch: testEpoch)
        _ = try ws.addSchedule(Schedule(budgetID: ws.budget.id, name: "Rent", accountID: dup, payeeName: "Landlord",
                                        categoryID: ws.categoryID(named: "Rent"), amountMilliunits: -usd(100),
                                        recurrence: .monthly(every: 1, day: .day(1)), startDate: date("2025-02-01")), nowEpoch: testEpoch)
        let keptSchedule = try ws.addSchedule(Schedule(budgetID: ws.budget.id, name: "Pay", accountID: keep, payeeName: "Work",
                                                       categoryID: nil, amountMilliunits: usd(100),
                                                       recurrence: .monthly(every: 1, day: .day(15)), startDate: date("2025-02-15")), nowEpoch: testEpoch)
        let allRule = try ws.addRule(name: "Only dup", conditions: [.account(dup), .direction(.outflow)], actions: [.setFlag(.red)], nowEpoch: testEpoch)
        let anyRule = try ws.addRule(name: "Dup or big", matchMode: .any, conditions: [.account(dup), .amount(.greaterThan(usd(500)))],
                                     actions: [.setFlag(.blue)], nowEpoch: testEpoch)
        let unrelated = try ws.addRule(name: "Keep", conditions: [.account(keep)], actions: [.setFlag(.green)], nowEpoch: testEpoch)
        let record = try #require(ws.simpleFINImports[imported])
        _ = ws.recordSyncConflictIfNew(transactionID: imported, simpleFINImportID: record.id, eventKind: .remoteDisappeared,
                                       oldMetadata: SyncConflictMetadata(note: "a"), newMetadata: SyncConflictMetadata(note: "b"), nowEpoch: testEpoch)
        try ws.closeAccountVoidingHistory(accountID: dup, nowEpoch: testEpoch)
        _ = try ws.upsertOpenSnapshotDiscrepancy(accountID: dup, observedEpoch: posted, remoteBalanceMilliunits: usd(1),
                                                 localRegisterMilliunits: usd(300), nowEpoch: testEpoch)
        let keepBalance = try ws.projection().registerBalances[keep]
        let rtaBefore = try ws.projection().month(month("2025-01"))?.rtaEnd

        let summary = try ws.deleteClosedAccount(accountID: dup, nowEpoch: testEpoch + 60)
        #expect(ws.accounts[dup] == nil)
        #expect(!ws.transactions.values.contains { $0.accountID == dup })
        #expect(summary.removedTransactions == 1, "the voided import; void-and-close already removed the manual opening row")
        #expect(!ws.simpleFINImports.values.contains { $0.remoteAccountID == "dup" })
        #expect(ws.syncConflicts.isEmpty || !ws.syncConflicts.values.contains { $0.simpleFINImportID == record.id })
        #expect(!ws.snapshotDiscrepancies.values.contains { $0.accountID == dup })
        #expect(summary.removedSchedules == 1)
        #expect(ws.schedules[keptSchedule] != nil)
        #expect(ws.automationRules[allRule] == nil, "an all-conditions rule requiring the account can never match again")
        #expect(ws.automationRules[anyRule]?.conditions == [.amount(.greaterThan(usd(500)))])
        #expect(ws.automationRules[unrelated] != nil)
        #expect(summary.removedRules == 1 && summary.updatedRules == 1)
        #expect(try ws.projection().registerBalances[keep] == keepBalance)
        #expect(try ws.projection().month(month("2025-01"))?.rtaEnd == rtaBefore, "a void-closed account no longer counts, so RTA is unchanged")
        _ = try BudgetWorkspace(snapshot: ws.snapshot())
    }

    @Test("A deleted card's payment category is removed, or kept hidden when it holds assignments")
    func paymentCategory() throws {
        var ws = try makeWorkspace(timeZone: "UTC")
        _ = try ws.addAccount(name: "Checking", type: .checking, onBudget: true,
                              openingBalance: usd(500), openingDate: date("2025-01-01"), nowEpoch: testEpoch)
        let empty = try ws.addAccount(name: "Old Card", type: .creditCard, onBudget: true,
                                      openingBalance: 0, openingDate: date("2025-01-01"), nowEpoch: testEpoch)
        let funded = try ws.addAccount(name: "Funded Card", type: .creditCard, onBudget: true,
                                       openingBalance: 0, openingDate: date("2025-01-01"), nowEpoch: testEpoch)
        let emptyPayment = try #require(ws.paymentCategoryID(forCard: empty))
        let fundedPayment = try #require(ws.paymentCategoryID(forCard: funded))
        try ws.setBudgeted(categoryID: fundedPayment, month: month("2025-01"), value: usd(25))
        try ws.closeAccount(accountID: empty, nowEpoch: testEpoch)
        try ws.closeAccount(accountID: funded, nowEpoch: testEpoch)
        let rta = try ws.projection().month(month("2025-01"))?.rtaEnd

        let removed = try ws.deleteClosedAccount(accountID: empty, nowEpoch: testEpoch)
        #expect(removed.removedPaymentCategory)
        #expect(ws.categories[emptyPayment] == nil)

        let kept = try ws.deleteClosedAccount(accountID: funded, nowEpoch: testEpoch)
        #expect(kept.keptPaymentCategoryHidden)
        let category = try #require(ws.categories[fundedPayment])
        #expect(category.hidden && category.kind == .spending && category.linkedAccountID == nil)
        #expect(try ws.projection().month(month("2025-01"))?.rtaEnd == rta, "assignments keep their months intact")
    }

    @Test("Service deletion persists and drops a SimpleFIN link bound to the account")
    func serviceDeletesLink() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ledgerbar-delete-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LedgerWorkspaceStore(databaseURL: directory.appendingPathComponent("db.sqlite"))
        let service = BudgetMutationService(store: store)
        _ = try await service.createBudget(name: "B", currency: "USD", timeZoneIdentifier: "UTC",
                                           firstMonth: month("2025-01"), currentMonth: month("2025-01"), nowEpoch: testEpoch)
        let (dup, keep) = try await service.transact(nowEpoch: testEpoch) { ws in
            let keep = try ws.addAccount(name: "Keep", type: .checking, onBudget: true,
                                         openingBalance: usd(5), openingDate: date("2025-01-01"), nowEpoch: testEpoch)
            let dup = try ws.addAccount(name: "Dup", type: .checking, onBudget: true,
                                        openingBalance: 0, openingDate: date("2025-01-01"), nowEpoch: testEpoch)
            try ws.closeAccount(accountID: dup, nowEpoch: testEpoch)
            return (dup, keep)
        }
        _ = try await service.updateSimpleFINState(nowEpoch: testEpoch) { state in
            state = SimpleFINConnectionState(
                status: .active, keychainItemID: "item-1", baseHost: "bridge.simplefin.org", basePort: 443,
                credentialGeneration: 1, createdAtEpoch: testEpoch,
                links: [
                    SimpleFINAccountLink(connectionKey: "conn:c1", remoteAccountID: "dup", localAccountID: dup),
                    SimpleFINAccountLink(connectionKey: "conn:c1", remoteAccountID: "keep", localAccountID: keep)
                ],
                disconnectPausedLinkIdentities: [SimpleFINAccountLink.identity(connectionKey: "conn:c1", remoteAccountID: "dup")]
            )
        }
        try await service.deleteClosedAccount(dup, nowEpoch: testEpoch + 1)
        let reloaded = BudgetMutationService(store: store)
        let snapshot = try await reloaded.loadActive()
        #expect(!snapshot.accounts.contains { $0.id == dup })
        let state = try #require(try await reloaded.simpleFINState())
        #expect(state.links.map(\.remoteAccountID) == ["keep"])
        #expect(state.disconnectPausedLinkIdentities.isEmpty)
    }

    @Test("Erase deletes every referenced Keychain item first, then every row, and leaves no budget")
    func eraseAll() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ledgerbar-erase-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("ledgerbar.sqlite")
        let store = try LedgerWorkspaceStore(databaseURL: url)
        let safetyCopy = url.deletingPathExtension().appendingPathExtension("before-v10.sqlite")
        try Data("old".utf8).write(to: safetyCopy)
        let service = BudgetMutationService(store: store)
        for name in ["One", "Two"] {
            _ = try await service.createBudget(name: name, currency: "USD", timeZoneIdentifier: "UTC",
                                               firstMonth: month("2025-01"), currentMonth: month("2025-01"), nowEpoch: testEpoch)
            _ = try await service.transact(nowEpoch: testEpoch) { ws in
                _ = try ws.addAccount(name: "Checking", type: .checking, onBudget: true,
                                      openingBalance: usd(9), openingDate: date("2025-01-01"), nowEpoch: testEpoch)
            }
            _ = try await service.updateSimpleFINState(nowEpoch: testEpoch) { state in
                state = SimpleFINConnectionState(
                    status: .active, keychainItemID: "item-\(name)", baseHost: "bridge.simplefin.org", basePort: 443,
                    credentialGeneration: 1, createdAtEpoch: testEpoch,
                    keychainItemIDsPendingDeletion: ["stale-\(name)"]
                )
            }
        }
        try await service.setAppSetting("assistantSettings", value: "{}", nowEpoch: testEpoch)

        let failing = RecordingCredentialStore()
        failing.failDeletes = true
        await #expect(throws: (any Error).self) { try await service.eraseAllData(credentials: failing) }
        #expect(try await service.listBudgets().count == 2, "a Keychain failure erases nothing")

        let credentials = RecordingCredentialStore()
        try await service.eraseAllData(credentials: credentials)
        #expect(Set(credentials.deletedIDs) == ["item-One", "item-Two", "stale-One", "stale-Two"])
        #expect(try await service.listBudgets().isEmpty)
        #expect(await service.currentSnapshot() == nil)
        #expect(try await service.appSetting("assistantSettings") == nil)
        #expect(!FileManager.default.fileExists(atPath: safetyCopy.path))
        let counts = try await store.pool.read { db -> Int in
            let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name <> 'grdb_migrations'")
            return try tables.reduce(0) { $0 + (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \"\($1)\"") ?? 0) }
        }
        #expect(counts == 0)
        await #expect(throws: LedgerPersistenceError.workspaceNotFound) { _ = try await BudgetMutationService(store: store).loadActive() }

        // The app can start over in the same file.
        _ = try await service.createBudget(name: "Fresh", currency: "USD", timeZoneIdentifier: "UTC",
                                           firstMonth: month("2025-01"), currentMonth: month("2025-01"), nowEpoch: testEpoch)
        #expect(try await service.listBudgets().map(\.name) == ["Fresh"])
    }
}

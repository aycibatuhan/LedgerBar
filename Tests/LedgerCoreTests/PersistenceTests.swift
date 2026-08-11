import Foundation
import Testing
@testable import LedgerCore

@Suite("GRDB persistence and mutation service")
struct PersistenceTests {
    private func temporaryDatabase() throws -> (URL, LedgerWorkspaceStore) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledgerbar-tests-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("LedgerBar.sqlite")
        let store = try LedgerWorkspaceStore(databaseURL: url)
        return (url, store)
    }

    @Test("in-memory store supports the app failure renderer without filesystem access")
    func inMemoryStoreRoundTrip() throws {
        let store = try LedgerWorkspaceStore.inMemory()
        let workspace = try makeWorkspace()
        try store.save(workspace, nowEpoch: testEpoch)

        #expect(try store.load(budgetID: workspace.budget.id).snapshot() == workspace.snapshot())
    }

    @Test("workspace snapshots survive a SQLite round trip")
    func snapshotRoundTrip() throws {
        let (url, store) = try temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var workspace = try makeWorkspace()
        let checking = try workspace.addAccount(
            name: "Checking", type: .checking, onBudget: true,
            openingBalance: usd(250), openingDate: date("2025-01-01"), nowEpoch: testEpoch
        )
        let groceries = workspace.categoryID(named: "Groceries")
        try workspace.setBudgeted(categoryID: groceries, month: month("2025-01"), value: usd(100))
        _ = try workspace.addManualTransaction(
            accountID: checking, date: date("2025-01-03"), payeeName: "Market",
            categoryID: groceries, amountMilliunits: -usd(25), nowEpoch: testEpoch
        )
        try store.save(workspace, nowEpoch: testEpoch)
        let restored = try store.load(budgetID: workspace.budget.id)
        #expect(restored.snapshot() == workspace.snapshot())
        #expect(try restored.projection().month(month("2025-01"))?.rtaEnd == usd(150))
    }

    @Test("mutation service persists only after a successful candidate mutation")
    func mutationServiceTransactionBoundary() async throws {
        let (url, store) = try temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let workspace = try makeWorkspace()
        let service = BudgetMutationService(store: store)
        let created = try await service.createBudget(
            name: workspace.budget.name,
            currency: workspace.budget.currency,
            timeZoneIdentifier: workspace.budget.timeZoneIdentifier,
            firstMonth: workspace.budget.firstMonth,
            currentMonth: workspace.currentMonth,
            nowEpoch: testEpoch
        )
        let before = created.budget.revision
        _ = try await service.transact(nowEpoch: testEpoch) { candidate in
            try candidate.addCategoryGroup(name: "Goals")
        }
        let after = try #require(await service.currentSnapshot())
        #expect(after.budget.revision > before)
        #expect(after.categoryGroups.contains { $0.name == "Goals" })

        await #expect(throws: MutationError.negativeSetBudgeted) {
            try await service.transact(nowEpoch: testEpoch) { candidate in
                try candidate.setBudgeted(
                    categoryID: candidate.categoryID(named: "Groceries"),
                    month: candidate.currentMonth,
                    value: -1
                )
            }
        }
        let unchanged = try #require(await service.currentSnapshot())
        #expect(unchanged == after)
    }

    @Test("verified backup creates a readable SQLite copy")
    func verifiedBackup() throws {
        let (url, store) = try temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let workspace = try makeWorkspace()
        try store.save(workspace, nowEpoch: testEpoch)
        let destination = url.deletingLastPathComponent().appendingPathComponent("selected-backup.sqlite")
        try store.backup(to: destination)
        #expect(FileManager.default.fileExists(atPath: destination.path))
        let backup = try LedgerWorkspaceStore(databaseURL: destination)
        #expect(try backup.load(budgetID: workspace.budget.id).snapshot() == workspace.snapshot())
    }

    @Test("duplicate snapshot identities fail closed instead of trapping")
    func duplicateSnapshotIdentityFailsClosed() throws {
        var workspace = try makeWorkspace()
        _ = try workspace.addAccount(
            name: "Checking", type: .checking, onBudget: true,
            openingBalance: usd(100), openingDate: date("2025-01-01"), nowEpoch: testEpoch
        )
        var snapshot = workspace.snapshot()
        snapshot.accounts.append(try #require(snapshot.accounts.first))

        #expect(throws: LedgerPersistenceError.invalidSnapshot) {
            _ = try BudgetWorkspace(snapshot: snapshot)
        }
    }

    @Test("snapshot loader rejects dangling foreign keys across persisted row families")
    func danglingSnapshotReferencesFailClosed() throws {
        var workspace = try makeWorkspace()
        let checking = try workspace.addAccount(
            name: "Checking", type: .checking, onBudget: true,
            openingBalance: usd(100), openingDate: date("2025-01-01"), nowEpoch: testEpoch
        )
        let groceries = workspace.categoryID(named: "Groceries")
        try workspace.setBudgeted(categoryID: groceries, month: month("2025-01"), value: usd(20))
        _ = try workspace.addManualTransaction(
            accountID: checking, date: date("2025-01-03"), payeeName: "Market",
            categoryID: groceries, amountMilliunits: -usd(5), nowEpoch: testEpoch
        )
        let base = workspace.snapshot()
        let invalidID = AccountID()

        func expectInvalid(_ mutate: (inout BudgetWorkspaceSnapshot) -> Void) {
            var snapshot = base
            mutate(&snapshot)
            #expect(throws: LedgerPersistenceError.invalidSnapshot) {
                _ = try BudgetWorkspace(snapshot: snapshot)
            }
        }

        expectInvalid { snapshot in
            snapshot.transactions[0].accountID = invalidID
        }
        expectInvalid { snapshot in
            snapshot.transactions[0].categoryID = CategoryID()
        }
        expectInvalid { snapshot in
            snapshot.categories[0].groupID = CategoryGroupID()
        }
        expectInvalid { snapshot in
            snapshot.categories[0].linkedAccountID = invalidID
        }
        expectInvalid { snapshot in
            snapshot.payees[0].lastUsedCategoryID = CategoryID()
        }
        expectInvalid { snapshot in
            snapshot.allocations[0].categoryID = CategoryID()
        }
        expectInvalid { snapshot in
            snapshot.transactions[0].stageMetadata = StageMetadata(proposedCategoryID: CategoryID())
        }
        expectInvalid { snapshot in
            snapshot.closedMonths.append(ClosedMonthRow(
                budgetID: BudgetID(), month: month("2025-01"), status: .closed
            ))
        }
        expectInvalid { snapshot in
            snapshot.reconciliationMembership.append(TransactionID())
        }
        expectInvalid { snapshot in
            snapshot.snapshotDiscrepancies.append(SnapshotDiscrepancyRow(
                budgetID: snapshot.budget.id,
                accountID: invalidID,
                observedEpoch: testEpoch,
                remoteBalanceMilliunits: 0,
                localRegisterMilliunits: 0,
                differenceMilliunits: 0,
                createdAtEpoch: testEpoch
            ))
        }
        expectInvalid { snapshot in
            snapshot.creditCardPaymentsGroupID = CategoryGroupID()
        }
        expectInvalid { snapshot in
            snapshot.transactions[0].sourceKind = .simplefin
        }
    }

    @Test("verified backup replaces an existing destination atomically")
    func verifiedBackupReplacesExistingDestination() throws {
        let (url, store) = try temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let workspace = try makeWorkspace()
        try store.save(workspace, nowEpoch: testEpoch)
        let destination = url.deletingLastPathComponent().appendingPathComponent("selected-backup.sqlite")
        try Data("stale destination".utf8).write(to: destination)

        try store.backup(to: destination)

        let backup = try LedgerWorkspaceStore(databaseURL: destination)
        #expect(try backup.load(budgetID: workspace.budget.id).snapshot() == workspace.snapshot())
    }

    @Test("sync request logs persist outcomes and survive workspace replacement")
    func syncRequestLogRoundTripAndLatestStart() throws {
        let (url, store) = try temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let workspace = try makeWorkspace()
        try store.save(workspace, nowEpoch: testEpoch)

        let discovery = SyncRequestLog(
            budgetID: workspace.budget.id,
            connectionID: "primary",
            startedAtEpoch: testEpoch
        )
        try store.insertSyncRequestLog(discovery)
        try store.finishSyncRequestLog(
            id: discovery.id,
            status: .succeeded,
            completedAtEpoch: testEpoch + 2
        )

        let recurring = SyncRequestLog(
            budgetID: workspace.budget.id,
            connectionID: "primary",
            requestedStartEpoch: testEpoch - 86_400,
            requestedEndEpoch: testEpoch,
            startedAtEpoch: testEpoch + 10
        )
        try store.insertSyncRequestLog(recurring)
        try store.finishSyncRequestLog(
            id: recurring.id,
            status: .failed,
            completedAtEpoch: testEpoch + 11,
            httpStatus: 429,
            retryAfterSeconds: 3600
        )

        try store.save(workspace, nowEpoch: testEpoch + 20)
        let logs = try store.syncRequestLogs(budgetID: workspace.budget.id, limit: 10)
        #expect(logs.count == 2)
        #expect(logs.first?.id == recurring.id)
        #expect(logs.first?.status == .failed)
        #expect(logs.first?.httpStatus == 429)
        #expect(logs.first?.retryAfterSeconds == 3600)
        #expect(logs.last?.requestedStartEpoch == nil)
        #expect(try store.latestSyncRequestStartedAtEpoch(budgetID: workspace.budget.id) == testEpoch + 10)

        let reopened = try LedgerWorkspaceStore(databaseURL: url)
        #expect(try reopened.syncRequestLogs(budgetID: workspace.budget.id).count == 2)
    }

    @Test("separate mutation services reject stale workspace writes")
    func staleMutationServiceWriteFailsClosed() async throws {
        let (url, store) = try temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let creator = BudgetMutationService(store: store)
        let created = try await creator.createBudget(
            name: "Shared",
            currency: "USD",
            timeZoneIdentifier: "UTC",
            firstMonth: month("2025-01"),
            currentMonth: month("2025-01"),
            nowEpoch: testEpoch
        )
        let firstStore = try LedgerWorkspaceStore(databaseURL: url)
        let secondStore = try LedgerWorkspaceStore(databaseURL: url)
        let first = BudgetMutationService(store: firstStore)
        let second = BudgetMutationService(store: secondStore)
        _ = try await first.load(budgetID: created.budget.id)
        _ = try await second.load(budgetID: created.budget.id)

        _ = try await first.transact(nowEpoch: testEpoch + 1) { workspace in
            try workspace.addCategoryGroup(name: "First writer")
        }

        await #expect(throws: LedgerPersistenceError.concurrentModification(expectedRevision: 0, actualRevision: 1)) {
            try await second.transact(nowEpoch: testEpoch + 2) { workspace in
                try workspace.addCategoryGroup(name: "Stale writer")
            }
        }

        let persisted = try secondStore.load(budgetID: created.budget.id)
        #expect(persisted.categoryGroups.values.contains { $0.name == "First writer" })
        #expect(!persisted.categoryGroups.values.contains { $0.name == "Stale writer" })
        #expect(try await second.currentSnapshot()?.categoryGroups.contains { $0.name == "First writer" } == true)
        _ = try await second.transact(nowEpoch: testEpoch + 3) { workspace in
            try workspace.addCategoryGroup(name: "Recovered writer")
        }
        let recovered = try secondStore.load(budgetID: created.budget.id)
        #expect(recovered.categoryGroups.values.contains { $0.name == "Recovered writer" })
    }

    @Test("separate mutation services reject stale connection-state writes")
    func staleConnectionStateWriteFailsClosed() async throws {
        let (url, creatorStore) = try temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let creator = BudgetMutationService(store: creatorStore)
        let created = try await creator.createBudget(
            name: "Shared connection state",
            currency: "USD",
            timeZoneIdentifier: "UTC",
            firstMonth: month("2025-01"),
            currentMonth: month("2025-01"),
            nowEpoch: testEpoch
        )
        let first = BudgetMutationService(store: try LedgerWorkspaceStore(databaseURL: url))
        let second = BudgetMutationService(store: try LedgerWorkspaceStore(databaseURL: url))
        _ = try await first.load(budgetID: created.budget.id)
        _ = try await second.load(budgetID: created.budget.id)
        let firstState = SimpleFINConnectionState(
            status: .active,
            keychainItemID: "first-item",
            baseHost: "bridge.simplefin.org",
            basePort: 443,
            credentialGeneration: 1,
            createdAtEpoch: testEpoch
        )
        let staleState = SimpleFINConnectionState(
            status: .active,
            keychainItemID: "stale-item",
            baseHost: "bridge.simplefin.org",
            basePort: 443,
            credentialGeneration: 1,
            createdAtEpoch: testEpoch
        )

        _ = try await first.updateSimpleFINState(nowEpoch: testEpoch + 1) { state in
            state = firstState
        }
        #expect(try await second.simpleFINState()?.keychainItemID == "first-item")
        await #expect(throws: LedgerPersistenceError.concurrentSimpleFINStateModification) {
            _ = try await second.updateSimpleFINState(nowEpoch: testEpoch + 2) { state in
                state = staleState
            }
        }
        #expect(try await second.simpleFINState()?.keychainItemID == "first-item")
        _ = try await second.updateSimpleFINState(nowEpoch: testEpoch + 3) { state in
            state?.keychainItemID = "recovered-item"
        }
        #expect(try await second.simpleFINState()?.keychainItemID == "recovered-item")
        #expect(try await first.simpleFINState()?.keychainItemID == "recovered-item")
    }
}

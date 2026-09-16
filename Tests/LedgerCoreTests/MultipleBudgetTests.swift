import Foundation
import Testing
@testable import LedgerCore

@Suite("Multiple budgets — D8")
struct MultipleBudgetTests {

    private func temporaryStore() throws -> (URL, LedgerWorkspaceStore) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledgerbar-budgets-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("db.sqlite")
        return (directory, try LedgerWorkspaceStore(databaseURL: url))
    }

    @Test("Two budgets in one database are isolated; mutations never cross")
    func isolation() async throws {
        let (directory, store) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = BudgetMutationService(store: store)
        let personal = try await service.createBudget(name: "Personal", currency: "USD", timeZoneIdentifier: "UTC",
                                                      firstMonth: month("2025-01"), currentMonth: month("2025-01"), nowEpoch: testEpoch)
        _ = try await service.transact(nowEpoch: testEpoch) { workspace in
            _ = try workspace.addAccount(name: "Checking", type: .checking, onBudget: true,
                                         openingBalance: usd(500), openingDate: date("2025-01-01"), nowEpoch: testEpoch)
            _ = try workspace.addRule(name: "r", conditions: [.direction(.outflow)], actions: [.setFlag(.red)], nowEpoch: testEpoch)
        }
        let business = try await service.createBudget(name: "Side Business", currency: "USD", timeZoneIdentifier: "UTC",
                                                      firstMonth: month("2025-01"), currentMonth: month("2025-01"), nowEpoch: testEpoch)
        #expect(await service.loadedBudgetID == business.budget.id)
        #expect(try await service.activeBudgetID() == business.budget.id)
        _ = try await service.transact(nowEpoch: testEpoch) { workspace in
            _ = try workspace.addAccount(name: "Biz Checking", type: .checking, onBudget: true,
                                         openingBalance: usd(9000), openingDate: date("2025-01-01"), nowEpoch: testEpoch)
        }
        let businessSnapshot = try #require(await service.currentSnapshot())
        #expect(businessSnapshot.accounts.map(\.name) == ["Biz Checking"])
        #expect(businessSnapshot.automationRules.isEmpty, "rules are budget-scoped")

        let personalAgain = try await service.switchBudget(to: personal.budget.id, nowEpoch: testEpoch)
        #expect(personalAgain.accounts.map(\.name) == ["Checking"])
        #expect(personalAgain.automationRules.count == 1)
        #expect(try await service.cachedProjectionResult(through: nil)?.month(month("2025-01"))?.rtaEnd == usd(500))
        #expect(try await service.activeBudgetID() == personal.budget.id)

        let budgets = try await service.listBudgets()
        #expect(budgets.map(\.name) == ["Personal", "Side Business"])
        // The persisted registry matches the loaded state after a reload.
        let reloaded = try await BudgetMutationService(store: store).loadActive()
        #expect(reloaded.budget.id == personal.budget.id)
    }

    @Test("Deleting a budget removes every scoped row and nothing else")
    func deletion() async throws {
        let (directory, store) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = BudgetMutationService(store: store)
        let keep = try await service.createBudget(name: "Keep", currency: "USD", timeZoneIdentifier: "UTC",
                                                  firstMonth: month("2025-01"), currentMonth: month("2025-01"), nowEpoch: testEpoch)
        _ = try await service.transact(nowEpoch: testEpoch) { workspace in
            let checking = try workspace.addAccount(name: "Checking", type: .checking, onBudget: true,
                                                    openingBalance: usd(500), openingDate: date("2025-01-01"), nowEpoch: testEpoch)
            _ = try workspace.addManualTransaction(accountID: checking, date: date("2025-01-02"), payeeName: "A",
                                                   categoryID: workspace.categoryID(named: "Groceries"), amountMilliunits: -usd(5), nowEpoch: testEpoch)
        }
        let drop = try await service.createBudget(name: "Drop", currency: "USD", timeZoneIdentifier: "UTC",
                                                  firstMonth: month("2025-01"), currentMonth: month("2025-01"), nowEpoch: testEpoch)
        _ = try await service.transact(nowEpoch: testEpoch) { workspace in
            let checking = try workspace.addAccount(name: "X", type: .checking, onBudget: true,
                                                    openingBalance: usd(1), openingDate: date("2025-01-01"), nowEpoch: testEpoch)
            let id = try workspace.importPostedTransaction(accountID: checking, connectionKey: "c", remoteAccountID: "a", remoteTransactionID: "t",
                                                           postedEpoch: try workspace.calendar.noonEpoch(of: date("2025-01-03")),
                                                           payeeName: "P", amountMilliunits: -usd(2), nowEpoch: testEpoch)
            try workspace.setCleared(transactionID: id, cleared: .cleared, nowEpoch: testEpoch)
            _ = try workspace.completeReconciliation(accountID: checking, statementDate: date("2025-01-31"), statementBalanceMilliunits: -usd(1), nowEpoch: testEpoch)
            _ = try workspace.addSchedule(Schedule(budgetID: workspace.budget.id, name: "S", accountID: checking, payeeName: "P", categoryID: nil,
                                                   amountMilliunits: usd(1), recurrence: .once, startDate: date("2025-01-05")), nowEpoch: testEpoch)
        }
        // Cannot delete the loaded budget.
        await #expect(throws: BudgetMutationServiceError.budgetIsActive) {
            try await service.deleteBudget(drop.budget.id)
        }
        _ = try await service.switchBudget(to: keep.budget.id, nowEpoch: testEpoch)
        try await service.deleteBudget(drop.budget.id)
        let remaining = try await service.listBudgets()
        #expect(remaining.map(\.id) == [keep.budget.id])
        let dropID = drop.budget.id.description
        let counts = try await store.pool.read { db -> [Int] in
            var result = try ["transactions", "accounts", "simplefin_imports", "reconciliations", "schedules", "workspace_states", "categories", "payees", "audit_events"].map {
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \($0) WHERE budget_id = ?", arguments: [dropID]) ?? 0
            }
            result.append(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM budgets WHERE id = ?", arguments: [dropID]) ?? 0)
            return result
        }
        #expect(counts.allSatisfy { $0 == 0 })
        let keepID = keep.budget.id.description
        let keepCount = try await store.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transactions WHERE budget_id = ?", arguments: [keepID]) ?? 0
        }
        #expect(keepCount == 2, "the other budget's rows are untouched")
        #expect(try store.load(budgetID: keep.budget.id).transactions.count == 2)
        #expect(throws: LedgerPersistenceError.workspaceNotFound) { _ = try store.load(budgetID: drop.budget.id) }
    }

    @Test("Export/import copies a budget with fresh identities and identical accounting")
    func exportImport() async throws {
        let (directory, store) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = BudgetMutationService(store: store)
        _ = try await service.createBudget(name: "Original", currency: "USD", timeZoneIdentifier: "America/New_York",
                                           firstMonth: month("2025-01"), currentMonth: month("2025-02"), nowEpoch: testEpoch)
        _ = try await service.transact(nowEpoch: testEpoch) { workspace in
            let checking = try workspace.addAccount(name: "Checking", type: .checking, onBudget: true,
                                                    openingBalance: usd(1000), openingDate: date("2025-01-01"), nowEpoch: testEpoch)
            let card = try workspace.addAccount(name: "Card", type: .creditCard, onBudget: true,
                                                openingBalance: -usd(100), openingDate: date("2025-01-01"), nowEpoch: testEpoch)
            let groceries = workspace.categoryID(named: "Groceries")
            let dining = workspace.categoryID(named: "Dining")
            try workspace.setBudgeted(categoryID: groceries, month: month("2025-02"), value: usd(200))
            let purchase = try workspace.addManualTransaction(accountID: card, date: date("2025-02-03"), payeeName: "Costco", categoryID: nil,
                                                              amountMilliunits: -usd(90),
                                                              splits: [SplitComponent(categoryID: groceries, amountMilliunits: -usd(60)),
                                                                       SplitComponent(categoryID: dining, amountMilliunits: -usd(30))], nowEpoch: testEpoch)
            _ = try workspace.addManualTransaction(accountID: card, date: date("2025-02-04"), payeeName: "Costco", categoryID: dining,
                                                   amountMilliunits: usd(10), kind: .refund, refundOf: purchase, refundOfComponentIndex: 1, nowEpoch: testEpoch)
            _ = try workspace.createManualTransferPair(sourceAccountID: checking, destinationAccountID: card, amount: usd(50), date: date("2025-02-05"), nowEpoch: testEpoch)
            _ = try workspace.importPostedTransaction(accountID: checking, connectionKey: "c", remoteAccountID: "a", remoteTransactionID: "r1",
                                                      postedEpoch: try workspace.calendar.noonEpoch(of: date("2025-02-06")), payeeName: "SHOP", amountMilliunits: -usd(7), nowEpoch: testEpoch)
            _ = try workspace.addRule(name: "shop", conditions: [.importedDescription(.contains, "shop")], actions: [.setCategory(groceries)], nowEpoch: testEpoch)
            _ = try workspace.saveReport(name: "R", definition: ReportDefinition(kind: .netWorth), nowEpoch: testEpoch)
        }
        let original = try #require(await service.currentSnapshot())
        let originalProjection = try BudgetWorkspace(snapshot: original).projection()
        let export = BudgetExport(snapshot: original, exportedAtEpoch: testEpoch, appVersion: "test")
        let data = try BudgetTransfer.encode(export)
        #expect(!String(decoding: data, as: UTF8.self).contains("keychain"), "exports never carry credentials")
        let decoded = try BudgetTransfer.decode(data)
        let copy = try await service.importBudget(decoded, name: "Copy", nowEpoch: testEpoch)
        #expect(copy.budget.id != original.budget.id)
        #expect(copy.budget.name == "Copy")
        #expect(copy.transactions.count == original.transactions.count)
        #expect(Set(copy.transactions.map(\.id)).isDisjoint(with: original.transactions.map(\.id)), "fresh identities")
        #expect(copy.automationRules.count == 1 && copy.reports.count == 1)
        let copyWorkspace = try BudgetWorkspace(snapshot: copy)
        let copyProjection = try copyWorkspace.projection()
        #expect(copyProjection.months.map(\.rtaEnd) == originalProjection.months.map(\.rtaEnd))
        #expect(copyProjection.months.last?.categories.values.map(\.available).sorted() == originalProjection.months.last?.categories.values.map(\.available).sorted())
        #expect(try ConservationCheck.compute(copyWorkspace, month: month("2025-02")).holds)
        // References survived the remap: the refund still names its component origin.
        let refund = try #require(copy.transactions.first { $0.kind == .refund })
        #expect(refund.refundOfTransactionID != nil && copy.transactions.contains { $0.id == refund.refundOfTransactionID })
        #expect(copy.transactions.first { $0.transferPairID != nil }.map { pair in copy.transferPairs.contains { $0.id == pair.transferPairID } } == true)
        // Remote identities are not UUIDs and are preserved verbatim.
        #expect(copy.simpleFINImports.first?.remoteTransactionID == "r1")
        #expect(try await service.listBudgets().map(\.name) == ["Original", "Copy"])
        // Malformed and future-format exports are rejected.
        #expect(throws: BudgetTransferError.malformed) { _ = try BudgetTransfer.decode(Data("{}".utf8)) }
        var future = decoded
        future.formatVersion = 99
        #expect(throws: BudgetTransferError.unsupportedFormatVersion(99)) { _ = try BudgetTransfer.decode(try BudgetTransfer.encode(future)) }
    }

    @Test("Rename and archive persist in the registry")
    func renameArchive() async throws {
        let (directory, store) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = BudgetMutationService(store: store)
        let a = try await service.createBudget(name: "A", currency: "USD", timeZoneIdentifier: "UTC",
                                               firstMonth: month("2025-01"), currentMonth: month("2025-01"), nowEpoch: testEpoch)
        _ = try await service.transact(nowEpoch: testEpoch) { workspace in
            try workspace.renameBudget(to: "  Household ")
            try workspace.setBudgetArchived(true, nowEpoch: testEpoch)
        }
        let summary = try #require(await service.listBudgets().first { $0.id == a.budget.id })
        #expect(summary.name == "Household" && summary.archived)
        await #expect(throws: MutationError.nameEmpty) {
            try await service.transact(nowEpoch: testEpoch) { try $0.renameBudget(to: "  ") }
        }
        // An archived-only registry still loads something.
        let reloaded = try await BudgetMutationService(store: store).loadActive()
        #expect(reloaded.budget.id == a.budget.id)
    }
}

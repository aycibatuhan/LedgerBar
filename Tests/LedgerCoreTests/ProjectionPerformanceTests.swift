import Foundation
import GRDB
import Testing
@testable import LedgerCore

@Suite("Projection checkpoints and performance gates")
struct ProjectionPerformanceTests {
    @Test("five-year 50-category replay stays within the performance gate")
    func fiveYearFiftyCategoryReplayPerformanceGate() throws {
        let firstMonth = try #require(BudgetMonth(string: "2021-01"))
        let lastMonth = try #require(BudgetMonth(string: "2025-12"))
        let budget = BudgetRow(
            name: "Performance Budget",
            currency: "USD",
            timeZoneIdentifier: "UTC",
            firstMonth: firstMonth,
            lastObservedBudgetMonth: lastMonth
        )
        let groupID = CategoryGroupID()
        let rta = CategoryRow(
            budgetID: budget.id,
            groupID: groupID,
            name: "Ready to Assign",
            sortOrder: 0,
            kind: .inflow,
            systemKind: .readyToAssign
        )
        let uncategorized = CategoryRow(
            budgetID: budget.id,
            groupID: groupID,
            name: "Uncategorized",
            sortOrder: 1,
            kind: .spending,
            systemKind: .uncategorized
        )
        let userCategories = (0..<50).map { index in
            CategoryRow(
                budgetID: budget.id,
                groupID: groupID,
                name: "Category \(index)",
                sortOrder: index + 2,
                kind: .spending
            )
        }
        let categories = Dictionary(
            uniqueKeysWithValues: ([rta, uncategorized] + userCategories).map { ($0.id, $0) }
        )
        let allocations = firstMonth.months(through: lastMonth).flatMap { month in
            userCategories.map {
                AllocationRow(
                    budgetID: budget.id,
                    categoryID: $0.id,
                    month: month,
                    budgetedMilliunits: 1_000
                )
            }
        }
        let input = ReplayInput(
            budget: budget,
            accounts: [:],
            categories: categories,
            allocations: allocations,
            transactions: []
        )

        let startedAt = Date()
        let result = try ReplayEngine.replay(input)
        let elapsed = Date().timeIntervalSince(startedAt)

        #expect(result.months.count == 60)
        #expect(result.months.allSatisfy { $0.categories.count == 51 })
        #expect(elapsed < 5.0, "five-year/50-category replay took \(elapsed)s")
    }

    @Test("cached projection after a mutation matches a fresh full replay")
    func cachedProjectionMatchesFullReplayAfterMutation() async throws {
        let store = try LedgerWorkspaceStore.inMemory()
        let service = BudgetMutationService(store: store)
        let created = try await service.createBudget(
            name: "Checkpoint Budget",
            currency: "USD",
            timeZoneIdentifier: "UTC",
            firstMonth: month("2025-01"),
            currentMonth: month("2025-12"),
            nowEpoch: testEpoch
        )
        let checkingID = try await service.transact(nowEpoch: testEpoch) { workspace in
            try workspace.addAccount(
                name: "Checking",
                type: .checking,
                onBudget: true,
                openingBalance: usd(1_000),
                openingDate: date("2025-01-02"),
                nowEpoch: testEpoch
            )
        }
        _ = try await service.cachedProjectionResult(through: nil)

        let diningID = try #require(created.categories.first { $0.name == "Dining" }?.id)
        _ = try await service.transact(nowEpoch: testEpoch) { workspace in
            try workspace.setBudgeted(
                categoryID: diningID,
                month: month("2025-12"),
                value: usd(250)
            )
            _ = try workspace.addManualTransaction(
                accountID: checkingID,
                date: date("2025-12-10"),
                payeeName: "Checkpoint Vendor",
                categoryID: diningID,
                amountMilliunits: -usd(40),
                nowEpoch: testEpoch
            )
        }

        let cached = try #require(await service.cachedProjectionResult(through: nil))
        let current = try #require(await service.currentSnapshot())
        let full = try BudgetWorkspace(snapshot: current).projection()
        #expect(cached.months == full.months)
        #expect(cached.registerBalances == full.registerBalances)
        #expect(cached.projectionBalances == full.projectionBalances)
        #expect(cached.postingDecisions == full.postingDecisions)
        #expect(cached.checkpoints == full.checkpoints)
        #expect(cached.horizon == full.horizon)
    }

    @Test("projection checkpoints survive cold reload and old revisions are discarded")
    func durableProjectionCacheSurvivesReload() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledgerbar-projection-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("LedgerBar.sqlite")
        let store = try LedgerWorkspaceStore(databaseURL: url)
        let service = BudgetMutationService(store: store)
        let created = try await service.createBudget(
            name: "Durable Cache Budget",
            currency: "USD",
            timeZoneIdentifier: "UTC",
            firstMonth: month("2025-01"),
            currentMonth: month("2025-12"),
            nowEpoch: testEpoch
        )
        let horizon = month("2025-12")
        let original = try #require(await service.cachedProjectionResult(through: horizon))
        let originalRevision = try #require(await service.currentSnapshot()).budget.revision

        let storedBeforeReload: Int = try await DatabaseQueue(path: url.path).read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM projection_caches WHERE budget_id = ? AND revision = ?",
                arguments: [created.budget.id.description, originalRevision]
            ) ?? 0
        }
        #expect(storedBeforeReload == 1)

        let coldStore = try LedgerWorkspaceStore(databaseURL: url)
        let coldService = BudgetMutationService(store: coldStore)
        _ = try await coldService.loadFirst()
        let restored = try #require(await coldService.cachedProjectionResult(through: horizon))
        #expect(restored.months == original.months)
        #expect(restored.registerBalances == original.registerBalances)
        #expect(restored.projectionBalances == original.projectionBalances)
        #expect(restored.postingDecisions == original.postingDecisions)
        #expect(restored.checkpoints == original.checkpoints)
        #expect(restored.horizon == original.horizon)

        let groceriesID = try #require(created.categories.first { $0.name == "Groceries" }?.id)
        _ = try await coldService.transact(nowEpoch: testEpoch + 1) { workspace in
            try workspace.setBudgeted(
                categoryID: groceriesID,
                month: horizon,
                value: usd(25)
            )
        }
        let updatedRevision = try #require(await coldService.currentSnapshot()).budget.revision
        let cacheCounts: (old: Int, current: Int) = try await DatabaseQueue(path: url.path).read { db in
            let old = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM projection_caches WHERE budget_id = ? AND revision = ?",
                arguments: [created.budget.id.description, originalRevision]
            ) ?? 0
            let current = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM projection_caches WHERE budget_id = ? AND revision = ?",
                arguments: [created.budget.id.description, updatedRevision]
            ) ?? 0
            return (old, current)
        }
        #expect(cacheCounts.old == 0)
        #expect(cacheCounts.current == 1)
    }

    @Test("projection cache stays bounded across many requested horizons")
    func projectionCacheIsBounded() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledgerbar-projection-cache-bound-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("LedgerBar.sqlite")
        let store = try LedgerWorkspaceStore(databaseURL: url)
        let service = BudgetMutationService(store: store)
        let created = try await service.createBudget(
            name: "Bounded Cache Budget",
            currency: "USD",
            timeZoneIdentifier: "UTC",
            firstMonth: month("2025-01"),
            currentMonth: month("2025-12"),
            nowEpoch: testEpoch
        )

        let cacheLimit = 16
        var horizon = month("2025-01")
        for _ in 0..<(cacheLimit + 8) {
            _ = try await service.cachedProjectionResult(through: horizon)
            horizon = horizon.next
        }

        let revision = try #require(await service.currentSnapshot()).budget.revision
        let storedCount: Int = try await DatabaseQueue(path: url.path).read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM projection_caches WHERE budget_id = ? AND revision = ?",
                arguments: [created.budget.id.description, revision]
            ) ?? 0
        }
        #expect(storedCount <= cacheLimit)
    }
}

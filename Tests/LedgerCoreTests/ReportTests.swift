import Foundation
import Testing
@testable import LedgerCore

@Suite("Reports — D7")
struct ReportTests {

    /// Jan–Mar 2025 with checking, card, and an off-budget savings account;
    /// exercises every line role at least once.
    private func fixture() throws -> (ws: BudgetWorkspace, checking: AccountID, card: AccountID, tracking: AccountID) {
        var ws = try makeWorkspace(firstMonth: "2025-01", currentMonth: "2025-01")
        let checking = try ws.addAccount(name: "Checking", type: .checking, onBudget: true,
                                         openingBalance: usd(1000), openingDate: date("2025-01-01"), nowEpoch: testEpoch)
        let card = try ws.addAccount(name: "Card", type: .creditCard, onBudget: true,
                                     openingBalance: -usd(100), openingDate: date("2025-01-01"), nowEpoch: testEpoch)
        let tracking = try ws.addAccount(name: "Brokerage", type: .other, onBudget: false,
                                         openingBalance: usd(5000), openingDate: date("2025-01-01"), nowEpoch: testEpoch)
        let groceries = ws.categoryID(named: "Groceries")
        let dining = ws.categoryID(named: "Dining")
        let rent = ws.categoryID(named: "Rent")
        // January
        try ws.setBudgeted(categoryID: groceries, month: month("2025-01"), value: usd(300))
        _ = try ws.addManualTransaction(accountID: checking, date: date("2025-01-03"), payeeName: "Employer",
                                        categoryID: ws.rtaCategoryID, amountMilliunits: usd(2000), nowEpoch: testEpoch)
        _ = try ws.addManualTransaction(accountID: checking, date: date("2025-01-05"), payeeName: "Whole Foods",
                                        categoryID: groceries, amountMilliunits: -usd(120), nowEpoch: testEpoch)
        let cardPurchase = try ws.addManualTransaction(accountID: card, date: date("2025-01-06"), payeeName: "Bistro",
                                                       categoryID: dining, amountMilliunits: -usd(80), nowEpoch: testEpoch)
        _ = try ws.addManualTransaction(accountID: card, date: date("2025-01-08"), payeeName: "Bistro", categoryID: dining,
                                        amountMilliunits: usd(20), kind: .refund, refundOf: cardPurchase, nowEpoch: testEpoch)
        _ = try ws.createManualTransferPair(sourceAccountID: checking, destinationAccountID: card, amount: usd(50),
                                            date: date("2025-01-10"), nowEpoch: testEpoch) // card payment
        _ = try ws.createManualTransferPair(sourceAccountID: checking, destinationAccountID: tracking, amount: usd(200),
                                            date: date("2025-01-12"), onLegCategoryID: rent, nowEpoch: testEpoch) // on→off spending
        _ = try ws.addManualTransaction(accountID: checking, date: date("2025-01-15"), payeeName: "Target", categoryID: nil,
                                        amountMilliunits: -usd(90),
                                        splits: [SplitComponent(categoryID: groceries, amountMilliunits: -usd(60)),
                                                 SplitComponent(categoryID: dining, amountMilliunits: -usd(30))],
                                        nowEpoch: testEpoch)
        // February
        try ws.advanceObservedMonth(to: month("2025-02"))
        _ = try ws.addManualTransaction(accountID: checking, date: date("2025-02-03"), payeeName: "Employer",
                                        categoryID: ws.rtaCategoryID, amountMilliunits: usd(2000), nowEpoch: testEpoch)
        _ = try ws.addManualTransaction(accountID: checking, date: date("2025-02-07"), payeeName: "Whole Foods",
                                        categoryID: groceries, amountMilliunits: -usd(150), nowEpoch: testEpoch)
        let voided = try ws.importPostedTransaction(accountID: checking, connectionKey: "c", remoteAccountID: "a", remoteTransactionID: "v",
                                                    postedEpoch: try ws.calendar.noonEpoch(of: date("2025-02-09")),
                                                    payeeName: "GHOST", amountMilliunits: -usd(999), nowEpoch: testEpoch)
        try ws.deleteTransaction(voided, nowEpoch: testEpoch)
        // March (current)
        try ws.advanceObservedMonth(to: month("2025-03"))
        _ = try ws.addManualTransaction(accountID: checking, date: date("2025-03-04"), payeeName: "Whole Foods",
                                        categoryID: groceries, amountMilliunits: -usd(100), nowEpoch: testEpoch)
        return (ws, checking, card, tracking)
    }

    @Test("Line roles: transfers, card payments, refunds, splits, off-budget, voided")
    func lineRoles() throws {
        let f = try fixture()
        let lines = f.ws.snapshot().categoryLines()
        #expect(!lines.contains { $0.amountMilliunits == -usd(999) }, "voided rows never produce lines")
        let byRole = Dictionary(grouping: lines, by: \.role)
        #expect(byRole[.cardPayment]?.count == 2, "both legs of a card payment")
        #expect(byRole[.refund]?.count == 1)
        #expect(byRole[.opening]?.count == 2, "on-budget openings (cash + card)")
        #expect(byRole[.offBudget]?.count == 1, "the tracking opening")
        #expect(byRole[.transfer]?.count == 1, "the off-budget leg of the on→off pair")
        let spending = byRole[.spending] ?? []
        #expect(spending.contains { $0.amountMilliunits == -usd(200) }, "the on-budget leg of on→off is spending")
        #expect(spending.filter { $0.transactionID == spending.first { $0.componentIndex == 1 }?.transactionID }.count == 2, "split rows expand per component")
        #expect(byRole[.income]?.count == 2)
    }

    @Test("Spending by category nets refunds, counts split components, ignores transfers and staged rows")
    func spendingByCategory() throws {
        let f = try fixture()
        let groceries = f.ws.categoryID(named: "Groceries")
        let dining = f.ws.categoryID(named: "Dining")
        let rent = f.ws.categoryID(named: "Rent")
        let result = ReportEngine.evaluate(
            ReportDefinition(kind: .spendingByCategory, range: .relative(.allTime)),
            snapshot: f.ws.snapshot(), projection: nil
        )
        func value(_ id: CategoryID) -> Milliunits? { result.rows.first { $0.key == id.description }?.valueMilliunits }
        #expect(value(groceries) == usd(120 + 60 + 150 + 100))
        #expect(value(dining) == usd(80 - 20 + 30), "refund reduces net dining")
        #expect(value(rent) == usd(200), "on→off leg counts as spending in its category")
        #expect(result.totalMilliunits == usd(430 + 90 + 200))
        #expect(result.rows.first?.key == groceries.description, "ranked descending")
        #expect(result.rows.first { $0.key == groceries.description }?.count == 4)
        #expect(!result.rows.contains { $0.label.contains("Payment") })
        // Limit collapses the tail into Other.
        let limited = ReportEngine.evaluate(ReportDefinition(kind: .spendingByCategory, range: .relative(.allTime), limit: 1),
                                            snapshot: f.ws.snapshot(), projection: nil)
        #expect(limited.rows.count == 2 && limited.rows.last?.key == "other")
        #expect(limited.totalMilliunits == result.totalMilliunits)
    }

    @Test("Relative ranges resolve in the budget calendar across year boundaries")
    func relativeRanges() {
        let current = month("2025-02")
        let first = month("2024-06")
        #expect(ReportDateRange.relative(.thisMonth).months(current: current, first: first) == month("2025-02")...month("2025-02"))
        #expect(ReportDateRange.relative(.lastMonth).months(current: current, first: first) == month("2025-01")...month("2025-01"))
        #expect(ReportDateRange.relative(.last3Months).months(current: current, first: first) == month("2024-12")...month("2025-02"))
        #expect(ReportDateRange.relative(.last12Months).months(current: current, first: first) == month("2024-03")...month("2025-02"))
        #expect(ReportDateRange.relative(.yearToDate).months(current: current, first: first) == month("2025-01")...month("2025-02"))
        #expect(ReportDateRange.relative(.thisYear).months(current: current, first: first) == month("2025-01")...month("2025-12"))
        #expect(ReportDateRange.relative(.lastYear).months(current: current, first: first) == month("2024-01")...month("2024-12"))
        #expect(ReportDateRange.relative(.allTime).months(current: current, first: first) == first...current)
        #expect(ReportDateRange.absolute(from: month("2025-03"), to: month("2025-01")).months(current: current, first: first) == month("2025-01")...month("2025-03"))
        #expect(ReportEngine.previousRange(month("2025-01")...month("2025-03")) == month("2024-10")...month("2024-12"))
        let quarters = ReportEngine.makePeriods(month("2024-11")...month("2025-05"), granularity: .quarter)
        #expect(quarters.map(\.label) == ["Q4 2024", "Q1 2025", "Q2 2025"])
        #expect(quarters[0].end == month("2024-12") && quarters[2].end == month("2025-05"))
        let years = ReportEngine.makePeriods(month("2024-11")...month("2025-05"), granularity: .year)
        #expect(years.map(\.label) == ["2024", "2025"])
    }

    @Test("Spending over time, category breakdown, and previous-period comparison")
    func spendingOverTime() throws {
        let f = try fixture()
        let groceries = f.ws.categoryID(named: "Groceries")
        let result = ReportEngine.evaluate(
            ReportDefinition(kind: .spendingOverTime, range: .absolute(from: month("2025-01"), to: month("2025-03")), breakdownByCategory: true),
            snapshot: f.ws.snapshot(), projection: nil
        )
        #expect(result.periods.map(\.label) == ["Jan 2025", "Feb 2025", "Mar 2025"])
        let grocerySeries = try #require(result.series.first { $0.key == groceries.description })
        #expect(grocerySeries.points.map(\.valueMilliunits) == [usd(180), usd(150), usd(100)])
        let compare = ReportEngine.evaluate(
            ReportDefinition(kind: .spendingOverTime, range: .relative(.thisMonth), comparePreviousPeriod: true),
            snapshot: f.ws.snapshot(), projection: nil
        )
        #expect(compare.totalMilliunits == usd(100))
        #expect(compare.previousTotalMilliunits == usd(150))
        #expect(compare.rows.first?.deltaMilliunits == -usd(50))
        // Filters: only the card account.
        let cardOnly = ReportEngine.evaluate(
            ReportDefinition(kind: .spendingOverTime, range: .relative(.allTime), filters: ReportFilters(accountIDs: [f.card])),
            snapshot: f.ws.snapshot(), projection: nil
        )
        #expect(cardOnly.totalMilliunits == usd(60), "card dining $80 minus $20 refund; the payment is not spending")
        let search = ReportEngine.evaluate(
            ReportDefinition(kind: .spendingByPayee, range: .relative(.allTime), filters: ReportFilters(searchText: "whole")),
            snapshot: f.ws.snapshot(), projection: nil
        )
        #expect(search.rows.count == 1 && search.totalMilliunits == usd(370))
    }

    @Test("Income vs spending excludes openings and adjustments unless opted in")
    func incomeVsSpending() throws {
        var f = try fixture()
        try f.ws.addReconciliationAdjustment(accountID: f.checking, date: date("2025-03-10"), amountMilliunits: usd(7), nowEpoch: testEpoch)
        let result = ReportEngine.evaluate(ReportDefinition(kind: .incomeVsSpending, range: .relative(.allTime)),
                                           snapshot: f.ws.snapshot(), projection: nil)
        #expect(result.rows.first { $0.key == "income" }?.valueMilliunits == usd(4000))
        #expect(result.rows.first { $0.key == "spending" }?.valueMilliunits == usd(720))
        #expect(result.totalMilliunits == usd(4000 - 720))
        let withOpenings = ReportEngine.evaluate(
            ReportDefinition(kind: .incomeVsSpending, range: .relative(.allTime), filters: ReportFilters(includeOpeningsAndAdjustmentsAsIncome: true)),
            snapshot: f.ws.snapshot(), projection: nil
        )
        #expect(withOpenings.rows.first { $0.key == "income" }?.valueMilliunits == usd(4000 + 1000 - 100 + 7))
    }

    @Test("Net worth is month-end register balances across on- and off-budget accounts")
    func netWorth() throws {
        let f = try fixture()
        let result = ReportEngine.evaluate(ReportDefinition(kind: .netWorth, range: .absolute(from: month("2025-01"), to: month("2025-03"))),
                                           snapshot: f.ws.snapshot(), projection: nil)
        let net = try #require(result.series.first { $0.key == "net" })
        // Jan: checking 1000+2000-120-50-200-90 = 2540; card -100-80+20+50 = -110; brokerage 5000+200 = 5200.
        #expect(net.points[0].valueMilliunits == usd(2540 - 110 + 5200))
        #expect(net.points[1].valueMilliunits == usd(2540 - 110 + 5200 + 2000 - 150))
        #expect(net.points[2].valueMilliunits == usd(2540 - 110 + 5200 + 2000 - 150 - 100))
        #expect(result.series.first { $0.key == "liabilities" }?.points[0].valueMilliunits == -usd(110))
        #expect(result.rows.count == 3)
        #expect(result.totalMilliunits == net.points[2].valueMilliunits)
    }

    @Test("Budget vs actual mirrors the projection")
    func budgetVsActual() throws {
        let f = try fixture()
        let groceries = f.ws.categoryID(named: "Groceries")
        let projection = try f.ws.projection()
        let result = ReportEngine.evaluate(ReportDefinition(kind: .budgetVsActual, range: .relative(.allTime)),
                                           snapshot: f.ws.snapshot(), projection: projection)
        #expect(result.series.first { $0.key == "budgeted" }?.points[0].valueMilliunits == usd(300))
        #expect(result.series.first { $0.key == "actual" }?.points[0].valueMilliunits == usd(180 + 90 + 200))
        let groceryRow = try #require(result.rows.first { $0.key == groceries.description })
        #expect(groceryRow.valueMilliunits == usd(430) && groceryRow.previousValueMilliunits == usd(300))
        #expect(!result.rows.contains { $0.label.contains("Payment") })
    }

    @Test("Saved reports: CRUD, uniqueness, and persistence")
    func savedReports() throws {
        var f = try fixture()
        let definition = ReportDefinition(kind: .spendingByPayee, range: .relative(.last6Months), limit: 10)
        let id = try f.ws.saveReport(name: "Top merchants", definition: definition, nowEpoch: testEpoch)
        #expect(throws: MutationError.duplicateName) {
            try f.ws.saveReport(name: "top merchants", definition: definition, nowEpoch: testEpoch)
        }
        let copy = try f.ws.duplicateReport(id, nowEpoch: testEpoch)
        #expect(f.ws.reports[copy]?.name == "Top merchants copy")
        try f.ws.renameReport(copy, to: "Merchants 2", nowEpoch: testEpoch)
        var changed = definition
        changed.visualization = .donut
        try f.ws.updateReportDefinition(id, definition: changed, nowEpoch: testEpoch)
        #expect(f.ws.reports[id]?.definition.visualization == .donut)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledgerbar-reports-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LedgerWorkspaceStore(databaseURL: directory.appendingPathComponent("db.sqlite"))
        try store.save(f.ws, nowEpoch: testEpoch)
        let restored = try store.load(budgetID: f.ws.budget.id)
        #expect(restored.snapshot() == f.ws.snapshot())
        #expect(restored.reports.count == 2)
        try f.ws.deleteReport(copy)
        #expect(f.ws.reports.count == 1)
        // Evaluation is deterministic across repeated runs.
        let a = ReportEngine.evaluate(changed, snapshot: f.ws.snapshot(), projection: nil)
        let b = ReportEngine.evaluate(changed, snapshot: f.ws.snapshot(), projection: nil)
        #expect(a == b)
    }
}

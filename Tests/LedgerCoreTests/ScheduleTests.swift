import Foundation
import Testing
@testable import LedgerCore

@Suite("Schedules — D5")
struct ScheduleTests {

    private func fixture() throws -> (ws: BudgetWorkspace, checking: AccountID, card: AccountID) {
        var ws = try makeWorkspace(firstMonth: "2024-11", currentMonth: "2025-01")
        let checking = try ws.addAccount(name: "Checking", type: .checking, onBudget: true,
                                         openingBalance: usd(3000), openingDate: date("2024-11-01"), nowEpoch: testEpoch)
        let card = try ws.addAccount(name: "Card", type: .creditCard, onBudget: true,
                                     openingBalance: -usd(200), openingDate: date("2024-11-01"), nowEpoch: testEpoch)
        return (ws, checking, card)
    }

    private func dates(_ rule: RecurrenceRule, start: String, from: String, through: String, end: String? = nil) -> [String] {
        RecurrenceEngine.nominalDates(rule: rule, start: date(start), end: end.map(date), in: date(from)...date(through)).map(\.description)
    }

    @Test("Recurrence: month lengths, last day, leap years, intervals, weekdays, end dates, year boundaries")
    func recurrence() {
        #expect(dates(.monthly(every: 1, day: .day(31)), start: "2025-01-31", from: "2025-01-01", through: "2025-05-31")
                == ["2025-01-31", "2025-02-28", "2025-03-31", "2025-04-30", "2025-05-31"])
        #expect(dates(.monthly(every: 1, day: .lastDay), start: "2024-01-15", from: "2024-01-01", through: "2024-03-31")
                == ["2024-01-31", "2024-02-29", "2024-03-31"])
        #expect(dates(.yearly(month: 2, day: 29), start: "2024-02-29", from: "2024-01-01", through: "2026-12-31")
                == ["2024-02-29", "2025-02-28", "2026-02-28"])
        #expect(dates(.weekly(every: 2, weekday: 6), start: "2024-12-30", from: "2024-12-01", through: "2025-02-01")
                == ["2025-01-03", "2025-01-17", "2025-01-31"], "first Friday on/after the start, then every two weeks")
        #expect(dates(.daily(every: 10), start: "2024-12-25", from: "2025-01-01", through: "2025-01-31")
                == ["2025-01-04", "2025-01-14", "2025-01-24"])
        #expect(dates(.monthly(every: 3, day: .day(1)), start: "2024-11-01", from: "2024-11-01", through: "2025-12-31", end: "2025-06-30")
                == ["2024-11-01", "2025-02-01", "2025-05-01"], "quarterly with an end date")
        #expect(dates(.once, start: "2025-03-15", from: "2025-01-01", through: "2025-12-31") == ["2025-03-15"])
        #expect(dates(.once, start: "2025-03-15", from: "2025-04-01", through: "2025-12-31") == [])
        #expect(RecurrenceEngine.weekday(of: date("2025-01-04")) == 7, "Saturday")
        #expect(RecurrenceEngine.applyWeekendPolicy(date("2025-01-04"), .previousBusinessDay) == date("2025-01-03"))
        #expect(RecurrenceEngine.applyWeekendPolicy(date("2025-01-04"), .nextBusinessDay) == date("2025-01-06"))
        #expect(RecurrenceEngine.applyWeekendPolicy(date("2025-01-05"), .exact) == date("2025-01-05"))
        #expect(RecurrenceEngine.date(fromDayNumber: RecurrenceEngine.dayNumber(date("2000-02-29"))) == date("2000-02-29"))
        // Monotonic, no repeats across a long horizon.
        let long = RecurrenceEngine.nominalDates(rule: .monthly(every: 1, day: .day(30)), start: date("2024-01-30"), end: nil, in: date("2024-01-01")...date("2027-12-31"))
        #expect(long.count == 48 && long == long.sorted() && Set(long).count == long.count)
    }

    @Test("Schedule CRUD validation")
    func crud() throws {
        var f = try fixture()
        let rent = f.ws.categoryID(named: "Rent")
        func draft(_ amount: Milliunits = -usd(1200), category: CategoryID? = nil, transfer: AccountID? = nil, end: BudgetDate? = nil) -> Schedule {
            Schedule(budgetID: f.ws.budget.id, name: "Rent", accountID: f.checking, payeeName: "Landlord", categoryID: category,
                     transferToAccountID: transfer, amountMilliunits: amount, recurrence: .monthly(every: 1, day: .day(1)),
                     startDate: date("2024-11-01"), endDate: end)
        }
        #expect(throws: MutationError.scheduleInvalid) { try f.ws.addSchedule(draft(0, category: rent), nowEpoch: testEpoch) }
        #expect(throws: MutationError.scheduleInvalid) { try f.ws.addSchedule(draft(category: rent, end: date("2024-10-01")), nowEpoch: testEpoch) }
        #expect(throws: MutationError.categoryNotAllowed) { try f.ws.addSchedule(draft(category: f.ws.rtaCategoryID), nowEpoch: testEpoch) }
        #expect(throws: MutationError.categoryNotAllowed) { try f.ws.addSchedule(draft(category: rent, transfer: f.card), nowEpoch: testEpoch) }
        let id = try f.ws.addSchedule(draft(category: rent), nowEpoch: testEpoch)
        #expect(f.ws.schedules[id]?.status == .active)
        try f.ws.setScheduleStatus(id, status: .paused, nowEpoch: testEpoch)
        #expect(f.ws.expectedOccurrences(in: date("2024-11-01")...date("2025-03-01"), asOf: date("2025-01-15")).isEmpty, "paused schedules expect nothing")
        try f.ws.setScheduleStatus(id, status: .active, nowEpoch: testEpoch)
        try f.ws.deleteSchedule(id, nowEpoch: testEpoch)
        #expect(f.ws.schedules.isEmpty)
    }

    @Test("Automatic matching links an unambiguous import; ties open a review; nothing is created")
    func matching() throws {
        var f = try fixture()
        let subscriptions = try f.ws.addCategory(groupID: f.ws.categoryGroups.values.first { $0.name == "Fixed Expenses" }!.id, name: "Subscriptions")
        let netflix = try f.ws.addSchedule(Schedule(
            budgetID: f.ws.budget.id, name: "Netflix", accountID: f.card, payeeName: "Netflix", categoryID: subscriptions,
            amountMilliunits: -22_990, recurrence: .monthly(every: 1, day: .day(18)), startDate: date("2024-11-18")
        ), nowEpoch: testEpoch)
        let countBefore = f.ws.transactions.count
        // Import a day early with the provider's descriptor.
        let imported = try f.ws.importPostedTransaction(
            accountID: f.card, connectionKey: "c", remoteAccountID: "a", remoteTransactionID: "n1",
            postedEpoch: try f.ws.calendar.noonEpoch(of: date("2025-01-17")),
            payeeName: "NETFLIX.COM", amountMilliunits: -22_990, nowEpoch: testEpoch
        )
        #expect(f.ws.transactions.count == countBefore + 1, "matching never creates rows")
        let occurrence = try #require(f.ws.scheduleOccurrence(for: imported))
        #expect(occurrence.dueDate == date("2025-01-18") && occurrence.status == .matched && occurrence.matchScore == 5)
        // Past occurrences with no rows stay expected (overdue), never auto-skipped.
        let expected = f.ws.expectedOccurrences(in: date("2024-11-01")...date("2025-02-28"), asOf: date("2025-01-20"))
        #expect(expected.map(\.dueDate) == [date("2024-11-18"), date("2024-12-18"), date("2025-02-18")])
        #expect(expected.filter(\.isOverdue).count == 2)
        #expect(f.ws.nextDueDate(for: netflix, asOf: date("2025-01-20")) == date("2025-02-18"))

        // Two equally good candidates for one occurrence → a review, no match.
        let gym = try f.ws.addSchedule(Schedule(
            budgetID: f.ws.budget.id, name: "Gym", accountID: f.checking, payeeName: "Gym", categoryID: subscriptions,
            amountMilliunits: -usd(40), recurrence: .monthly(every: 1, day: .day(10)), startDate: date("2025-01-10")
        ), nowEpoch: testEpoch)
        let a = try f.ws.importPostedTransaction(accountID: f.checking, connectionKey: "c", remoteAccountID: "b", remoteTransactionID: "g1",
                                                 postedEpoch: try f.ws.calendar.noonEpoch(of: date("2025-01-09")), payeeName: "GYM CO", amountMilliunits: -usd(40), nowEpoch: testEpoch)
        #expect(f.ws.scheduleOccurrence(for: a)?.status == .matched, "first arrival is unambiguous")
        try f.ws.unmatchOccurrence(scheduleID: gym, dueDate: date("2025-01-10"), nowEpoch: testEpoch)
        let b = try f.ws.importPostedTransaction(accountID: f.checking, connectionKey: "c", remoteAccountID: "b", remoteTransactionID: "g2",
                                                 postedEpoch: try f.ws.calendar.noonEpoch(of: date("2025-01-11")), payeeName: "GYM CO", amountMilliunits: -usd(40), nowEpoch: testEpoch)
        #expect(f.ws.scheduleOccurrence(for: a) == nil && f.ws.scheduleOccurrence(for: b) == nil)
        let review = try #require(f.ws.scheduleReviews.values.first { $0.status == .open })
        #expect(review.scheduleID == gym && Set(review.candidateTransactionIDs) == [a, b])
        // Explicit choice resolves the review; the other row stays free.
        try f.ws.matchOccurrence(scheduleID: gym, dueDate: date("2025-01-10"), transactionID: b, nowEpoch: testEpoch)
        #expect(f.ws.scheduleReviews[review.id]?.status == .dismissed)
        #expect(throws: MutationError.scheduleOccurrenceResolved) {
            try f.ws.matchOccurrence(scheduleID: gym, dueDate: date("2025-01-10"), transactionID: a, nowEpoch: testEpoch)
        }
        // Amount outside tolerance never matches; within tolerance scores lower.
        try f.ws.advanceObservedMonth(to: month("2025-03"))
        var variable = f.ws.schedules[netflix]!
        variable.amountToleranceMilliunits = 5_000
        try f.ws.updateSchedule(variable, nowEpoch: testEpoch)
        let higher = try f.ws.importPostedTransaction(accountID: f.card, connectionKey: "c", remoteAccountID: "a", remoteTransactionID: "n2",
                                                      postedEpoch: try f.ws.calendar.noonEpoch(of: date("2025-02-18")), payeeName: "NETFLIX.COM", amountMilliunits: -24_990, nowEpoch: testEpoch)
        #expect(f.ws.scheduleOccurrence(for: higher)?.matchScore == 5, "tolerance 2 + payee 2 + same day 1")
        let far = try f.ws.importPostedTransaction(accountID: f.card, connectionKey: "c", remoteAccountID: "a", remoteTransactionID: "n3",
                                                   postedEpoch: try f.ws.calendar.noonEpoch(of: date("2025-03-18")), payeeName: "NETFLIX.COM", amountMilliunits: -40_000, nowEpoch: testEpoch)
        #expect(f.ws.scheduleOccurrence(for: far) == nil)
        #expect(try ConservationCheck.compute(f.ws, month: month("2025-01")).holds)
    }

    @Test("Enter now creates the transaction once; a later import raises a duplicate conflict, not a second match")
    func enterNow() throws {
        var f = try fixture()
        let rent = f.ws.categoryID(named: "Rent")
        let schedule = try f.ws.addSchedule(Schedule(
            budgetID: f.ws.budget.id, name: "Rent", accountID: f.checking, payeeName: "Landlord", categoryID: rent,
            amountMilliunits: -usd(1200), recurrence: .monthly(every: 1, day: .day(1)), startDate: date("2025-01-01")
        ), nowEpoch: testEpoch)
        let entered = try f.ws.enterOccurrence(scheduleID: schedule, dueDate: date("2025-01-01"), nowEpoch: testEpoch)
        #expect(f.ws.transactions[entered]?.sourceKind == .manual)
        #expect(f.ws.transactions[entered]?.categoryID == rent)
        #expect(f.ws.scheduleOccurrence(for: entered)?.status == .entered)
        #expect(throws: MutationError.scheduleOccurrenceResolved) {
            _ = try f.ws.enterOccurrence(scheduleID: schedule, dueDate: date("2025-01-01"), nowEpoch: testEpoch)
        }
        let imported = try f.ws.importPostedTransaction(
            accountID: f.checking, connectionKey: "c", remoteAccountID: "a", remoteTransactionID: "rent",
            postedEpoch: try f.ws.calendar.noonEpoch(of: date("2025-01-01")), payeeName: "LANDLORD LLC",
            amountMilliunits: -usd(1200), nowEpoch: testEpoch
        )
        #expect(f.ws.scheduleOccurrence(for: imported) == nil, "the occurrence is already served")
        let conflicts = f.ws.recordManualPotentialDuplicateConflicts(for: imported, nowEpoch: testEpoch)
        #expect(conflicts.count == 1, "the existing duplicate workflow handles the bank copy")
        // Transfer schedule (card payment) enters as a pair.
        let payment = try f.ws.addSchedule(Schedule(
            budgetID: f.ws.budget.id, name: "Card payment", accountID: f.checking, payeeName: "Card", categoryID: nil,
            transferToAccountID: f.card, amountMilliunits: -usd(100), recurrence: .monthly(every: 1, day: .day(15)), startDate: date("2025-01-15")
        ), nowEpoch: testEpoch)
        let leg = try f.ws.enterOccurrence(scheduleID: payment, dueDate: date("2025-01-15"), nowEpoch: testEpoch)
        #expect(f.ws.transactions[leg]?.transferPairID != nil)
        #expect(try f.ws.projection().projectionBalances[f.card] == -usd(100))
        #expect(try ConservationCheck.compute(f.ws, month: month("2025-01")).holds)
    }

    @Test("Skips advance the series; forecast adds only unresolved expected amounts")
    func skipAndForecast() throws {
        var f = try fixture()
        let rent = f.ws.categoryID(named: "Rent")
        let schedule = try f.ws.addSchedule(Schedule(
            budgetID: f.ws.budget.id, name: "Rent", accountID: f.checking, payeeName: "Landlord", categoryID: rent,
            amountMilliunits: -usd(1000), recurrence: .monthly(every: 1, day: .day(5)), startDate: date("2025-01-05")
        ), nowEpoch: testEpoch)
        let salary = try f.ws.addSchedule(Schedule(
            budgetID: f.ws.budget.id, name: "Salary", accountID: f.checking, payeeName: "Employer", categoryID: nil,
            amountMilliunits: usd(2500), recurrence: .weekly(every: 2, weekday: 6), startDate: date("2025-01-10")
        ), nowEpoch: testEpoch)
        _ = salary
        try f.ws.skipOccurrence(scheduleID: schedule, dueDate: date("2025-01-05"), nowEpoch: testEpoch)
        #expect(f.ws.nextDueDate(for: schedule, asOf: date("2025-01-01")) == date("2025-02-05"))
        #expect(throws: MutationError.scheduleOccurrenceResolved) {
            try f.ws.skipOccurrence(scheduleID: schedule, dueDate: date("2025-01-05"), nowEpoch: testEpoch)
        }
        // Register is 3000; through Jan 31 the plan expects +2500 (Jan 10) +2500 (Jan 24), rent skipped.
        let projected = try f.ws.projectedRegisterBalance(accountID: f.checking, through: date("2025-01-31"), asOf: date("2025-01-01"), registerBalance: usd(3000))
        #expect(projected == usd(8000))
        let february = try f.ws.projectedRegisterBalance(accountID: f.checking, through: date("2025-02-06"), asOf: date("2025-01-01"), registerBalance: usd(3000))
        #expect(february == usd(8000 - 1000), "February rent is expected")
        #expect(try f.ws.projection().registerBalances[f.checking] == usd(3000), "projections never touch the ledger")
    }

    @Test("Persistence round-trips schedules, occurrences, and reviews")
    func persistence() throws {
        var f = try fixture()
        let rent = f.ws.categoryID(named: "Rent")
        let id = try f.ws.addSchedule(Schedule(
            budgetID: f.ws.budget.id, name: "Rent", accountID: f.checking, payeeName: "Landlord", categoryID: rent,
            amountMilliunits: -usd(1000), recurrence: .monthly(every: 1, day: .lastDay), startDate: date("2024-11-30"),
            weekendPolicy: .previousBusinessDay
        ), nowEpoch: testEpoch)
        try f.ws.skipOccurrence(scheduleID: id, dueDate: date("2024-11-29"), nowEpoch: testEpoch)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledgerbar-schedules-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LedgerWorkspaceStore(databaseURL: directory.appendingPathComponent("db.sqlite"))
        try store.save(f.ws, nowEpoch: testEpoch)
        let restored = try store.load(budgetID: f.ws.budget.id)
        #expect(restored.snapshot() == f.ws.snapshot())
        #expect(restored.schedules[id]?.recurrence == .monthly(every: 1, day: .lastDay))
        #expect(restored.scheduleOccurrences.count == 1)
        let mirrored = try store.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM schedule_occurrences WHERE status = 'skipped'") ?? 0
        }
        #expect(mirrored == 1)
    }
}

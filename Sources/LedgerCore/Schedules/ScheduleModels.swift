import Foundation

// MARK: - Model (docs/DESIGN.md D5)

public enum MonthDay: Sendable, Codable, Equatable, Hashable {
    /// 1…31; days past the month's length clamp to its last day.
    case day(Int)
    case lastDay
}

public enum RecurrenceRule: Sendable, Codable, Equatable, Hashable {
    case once
    case daily(every: Int)
    /// `weekday`: 1 = Sunday … 7 = Saturday.
    case weekly(every: Int, weekday: Int)
    case monthly(every: Int, day: MonthDay)
    case yearly(month: Int, day: Int)

    public var summary: String {
        switch self {
        case .once: return "Once"
        case .daily(let n): return n == 1 ? "Daily" : "Every \(n) days"
        case let .weekly(n, weekday):
            let name = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"][max(0, min(6, weekday - 1))]
            return n == 1 ? "Weekly on \(name)" : "Every \(n) weeks on \(name)"
        case let .monthly(n, day):
            let dayText: String
            switch day {
            case .day(let d): dayText = "day \(d)"
            case .lastDay: dayText = "the last day"
            }
            return n == 1 ? "Monthly on \(dayText)" : "Every \(n) months on \(dayText)"
        case let .yearly(month, day):
            let names = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
            return "Yearly on \(names[max(0, min(11, month - 1))]) \(day)"
        }
    }
}

public enum WeekendPolicy: String, Sendable, Codable, CaseIterable {
    case exact
    case previousBusinessDay
    case nextBusinessDay
}

public enum ScheduleStatus: String, Sendable, Codable, CaseIterable {
    case active
    case paused
    case ended
}

/// An expected financial event. It never claims a transaction happened;
/// occurrences record what did happen (matched, entered, skipped).
public struct Schedule: Sendable, Codable, Equatable, Identifiable, Hashable {
    public var id: ScheduleID
    public var budgetID: BudgetID
    public var name: String
    public var accountID: AccountID
    public var payeeName: String
    public var categoryID: CategoryID?
    /// When set, the schedule is a transfer to this account (a card payment
    /// when the destination is a credit card).
    public var transferToAccountID: AccountID?
    /// Signed expected amount from the source account's point of view.
    public var amountMilliunits: Milliunits
    /// Absolute tolerance for variable amounts (0 = exact).
    public var amountToleranceMilliunits: Milliunits
    public var recurrence: RecurrenceRule
    public var startDate: BudgetDate
    public var endDate: BudgetDate?
    public var status: ScheduleStatus
    /// Days on either side of the (weekend-adjusted) due date to look for a match.
    public var dateWindowDays: Int
    public var weekendPolicy: WeekendPolicy
    /// Automatic linking of unambiguous high-confidence matches (D5.3).
    public var autoMatch: Bool
    public var memo: String?
    public var createdAtEpoch: Int64
    public var updatedAtEpoch: Int64

    public init(
        id: ScheduleID = ScheduleID(),
        budgetID: BudgetID,
        name: String,
        accountID: AccountID,
        payeeName: String,
        categoryID: CategoryID?,
        transferToAccountID: AccountID? = nil,
        amountMilliunits: Milliunits,
        amountToleranceMilliunits: Milliunits = 0,
        recurrence: RecurrenceRule,
        startDate: BudgetDate,
        endDate: BudgetDate? = nil,
        status: ScheduleStatus = .active,
        dateWindowDays: Int = 4,
        weekendPolicy: WeekendPolicy = .exact,
        autoMatch: Bool = true,
        memo: String? = nil,
        createdAtEpoch: Int64 = 0,
        updatedAtEpoch: Int64 = 0
    ) {
        self.id = id
        self.budgetID = budgetID
        self.name = name
        self.accountID = accountID
        self.payeeName = payeeName
        self.categoryID = categoryID
        self.transferToAccountID = transferToAccountID
        self.amountMilliunits = amountMilliunits
        self.amountToleranceMilliunits = amountToleranceMilliunits
        self.recurrence = recurrence
        self.startDate = startDate
        self.endDate = endDate
        self.status = status
        self.dateWindowDays = dateWindowDays
        self.weekendPolicy = weekendPolicy
        self.autoMatch = autoMatch
        self.memo = memo
        self.createdAtEpoch = createdAtEpoch
        self.updatedAtEpoch = updatedAtEpoch
    }
}

public enum ScheduleOccurrenceStatus: String, Sendable, Codable {
    case matched
    case entered
    case skipped
}

public struct ScheduleOccurrenceKey: Sendable, Codable, Equatable, Hashable {
    public var scheduleID: ScheduleID
    public var dueDate: BudgetDate
    public init(scheduleID: ScheduleID, dueDate: BudgetDate) {
        self.scheduleID = scheduleID
        self.dueDate = dueDate
    }
}

/// Sparse: only occurrences that were matched, entered, or skipped exist.
public struct ScheduleOccurrence: Sendable, Codable, Equatable, Hashable {
    public var scheduleID: ScheduleID
    public var dueDate: BudgetDate
    public var status: ScheduleOccurrenceStatus
    public var transactionID: TransactionID?
    public var resolvedAtEpoch: Int64
    /// Score of an automatic match, for audit; nil for manual decisions.
    public var matchScore: Int?

    public var key: ScheduleOccurrenceKey { ScheduleOccurrenceKey(scheduleID: scheduleID, dueDate: dueDate) }

    public init(scheduleID: ScheduleID, dueDate: BudgetDate, status: ScheduleOccurrenceStatus, transactionID: TransactionID?, resolvedAtEpoch: Int64, matchScore: Int? = nil) {
        self.scheduleID = scheduleID
        self.dueDate = dueDate
        self.status = status
        self.transactionID = transactionID
        self.resolvedAtEpoch = resolvedAtEpoch
        self.matchScore = matchScore
    }
}

public enum ScheduleReviewStatus: String, Sendable, Codable {
    case open
    case resolved
    case dismissed
}

/// An ambiguous match surfaced in the Review Queue (D5.3).
public struct ScheduleMatchReview: Sendable, Codable, Equatable, Identifiable {
    public var id: ScheduleReviewID
    public var budgetID: BudgetID
    public var scheduleID: ScheduleID
    public var dueDate: BudgetDate
    public var candidateTransactionIDs: [TransactionID]
    public var status: ScheduleReviewStatus
    public var createdAtEpoch: Int64
    public var resolvedAtEpoch: Int64?

    public init(
        id: ScheduleReviewID = ScheduleReviewID(),
        budgetID: BudgetID,
        scheduleID: ScheduleID,
        dueDate: BudgetDate,
        candidateTransactionIDs: [TransactionID],
        status: ScheduleReviewStatus = .open,
        createdAtEpoch: Int64,
        resolvedAtEpoch: Int64? = nil
    ) {
        self.id = id
        self.budgetID = budgetID
        self.scheduleID = scheduleID
        self.dueDate = dueDate
        self.candidateTransactionIDs = candidateTransactionIDs
        self.status = status
        self.createdAtEpoch = createdAtEpoch
        self.resolvedAtEpoch = resolvedAtEpoch
    }
}

// MARK: - Recurrence (D5.2)

public enum RecurrenceEngine {

    /// Days since 1970-01-01 (proleptic Gregorian); inverse below.
    public static func dayNumber(_ date: BudgetDate) -> Int {
        BudgetWorkspace.civilDayNumber(date)
    }

    public static func date(fromDayNumber z0: Int) -> BudgetDate {
        // Howard Hinnant's civil_from_days.
        let z = z0 + 719468
        let era = (z >= 0 ? z : z - 146096) / 146097
        let doe = z - era * 146097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        let year = m <= 2 ? y + 1 : y
        return BudgetDate(year: year, month: m, day: d)!
    }

    public static func adding(days: Int, to date: BudgetDate) -> BudgetDate {
        self.date(fromDayNumber: dayNumber(date) + days)
    }

    /// 1 = Sunday … 7 = Saturday.
    public static func weekday(of date: BudgetDate) -> Int {
        RuleEngine.weekday(of: date)
    }

    static func clampedDate(year: Int, month: Int, day: MonthDay) -> BudgetDate? {
        guard let budgetMonth = BudgetMonth(year: year, month: month) else { return nil }
        let length = BudgetDate.daysIn(month: budgetMonth)
        switch day {
        case .lastDay: return BudgetDate(year: year, month: month, day: length)
        case .day(let d): return BudgetDate(year: year, month: month, day: max(1, min(d, length)))
        }
    }

    public static func applyWeekendPolicy(_ date: BudgetDate, _ policy: WeekendPolicy) -> BudgetDate {
        guard policy != .exact else { return date }
        var current = date
        var guardCount = 0
        while [1, 7].contains(weekday(of: current)), guardCount < 3 {
            current = adding(days: policy == .previousBusinessDay ? -1 : 1, to: current)
            guardCount += 1
        }
        return current
    }

    /// Nominal (pre-weekend-policy) occurrences of `rule` starting at
    /// `start`, bounded by `end`, that fall within `range`. Deterministic and
    /// monotonic; never repeats a date.
    public static func nominalDates(
        rule: RecurrenceRule,
        start: BudgetDate,
        end: BudgetDate?,
        in range: ClosedRange<BudgetDate>,
        limit: Int = 2_000
    ) -> [BudgetDate] {
        var result: [BudgetDate] = []
        let hardEnd = end.map { min($0, range.upperBound) } ?? range.upperBound
        guard start <= hardEnd else { return [] }
        func emit(_ date: BudgetDate) -> Bool {
            if date > hardEnd { return false }
            if date >= range.lowerBound { result.append(date) }
            return result.count < limit
        }
        switch rule {
        case .once:
            _ = emit(start)
        case .daily(let every):
            let step = max(1, every)
            var day = dayNumber(start)
            // Skip ahead to the range start in one step.
            let first = dayNumber(range.lowerBound)
            if day < first { day += ((first - day + step - 1) / step) * step }
            while emit(date(fromDayNumber: day)) { day += step }
        case let .weekly(every, weekday):
            let step = 7 * max(1, every)
            // First occurrence on or after start with the requested weekday.
            var day = dayNumber(start)
            let startWeekday = self.weekday(of: start)
            let target = max(1, min(7, weekday))
            day += ((target - startWeekday) + 7) % 7
            let first = dayNumber(range.lowerBound)
            if day < first { day += ((first - day + step - 1) / step) * step }
            while emit(date(fromDayNumber: day)) { day += step }
        case let .monthly(every, monthDay):
            let step = max(1, every)
            var year = start.year
            var month = start.month
            var iterations = 0
            while iterations < 100_000 {
                iterations += 1
                if let candidate = clampedDate(year: year, month: month, day: monthDay), candidate >= start {
                    if !emit(candidate) { break }
                    if candidate > hardEnd { break }
                }
                var next = month + step
                while next > 12 { next -= 12; year += 1 }
                month = next
                if BudgetMonth(year: year, month: month)! > hardEnd.budgetMonth { break }
            }
        case let .yearly(month, day):
            var year = start.year
            var iterations = 0
            while iterations < 10_000 {
                iterations += 1
                // Feb 29 in a non-leap year falls on Feb 28.
                if let candidate = clampedDate(year: year, month: max(1, min(12, month)), day: .day(day)), candidate >= start {
                    if !emit(candidate) { break }
                }
                year += 1
                if year > hardEnd.year { break }
            }
        }
        return result
    }

    /// Expected due dates (weekend-adjusted) in `range`, excluding stored
    /// occurrences. Ended and paused schedules yield nothing.
    public static func expectedDates(
        _ schedule: Schedule,
        in range: ClosedRange<BudgetDate>,
        occurrences: Set<BudgetDate>
    ) -> [BudgetDate] {
        guard schedule.status == .active else { return [] }
        // Widen by a week so weekend shifting near the range edges is stable.
        let widened = adding(days: -7, to: range.lowerBound)...adding(days: 7, to: range.upperBound)
        return nominalDates(rule: schedule.recurrence, start: schedule.startDate, end: schedule.endDate, in: widened)
            .map { applyWeekendPolicy($0, schedule.weekendPolicy) }
            .filter { range.contains($0) && !occurrences.contains($0) }
    }
}

// MARK: - Matching (D5.3)

public enum ScheduleMatcher {
    public static let autoMatchThreshold = 5
    public static let reviewThreshold = 3

    public struct Candidate: Sendable, Equatable {
        public var transactionID: TransactionID
        public var score: Int
    }

    /// Deterministic score of a row for an expected occurrence. Amount within
    /// tolerance is required; payee similarity and date closeness add.
    public static func score(
        schedule: Schedule,
        dueDate: BudgetDate,
        row: TransactionRow,
        payeeDisplayName: String?
    ) -> Int? {
        guard row.accountID == schedule.accountID, row.postingState != .voided else { return nil }
        guard (row.amountMilliunits < 0) == (schedule.amountMilliunits < 0) else { return nil }
        let distanceDays = abs(RecurrenceEngine.dayNumber(row.date) - RecurrenceEngine.dayNumber(dueDate))
        guard distanceDays <= schedule.dateWindowDays else { return nil }
        let (difference, overflow) = row.amountMilliunits.subtractingReportingOverflow(schedule.amountMilliunits)
        guard !overflow else { return nil }
        let magnitude = Int64(difference.magnitude)
        var score = 0
        if magnitude == 0 {
            score += 3
        } else if magnitude <= schedule.amountToleranceMilliunits {
            score += 2
        } else {
            return nil
        }
        // Payee similarity: every token of the schedule payee appears in the
        // row's payee/imported text ("Netflix" ⊂ "NETFLIX.COM") → 2; some → 1.
        let scheduleTokens = BudgetWorkspace.normalizePayeeName(schedule.payeeName).split(separator: " ").map(String.init).filter { $0.count > 1 }
        let rowText = BudgetWorkspace.normalizePayeeName([payeeDisplayName ?? "", row.importedDescription ?? ""].joined(separator: " "))
        if !scheduleTokens.isEmpty {
            if scheduleTokens.allSatisfy({ rowText.contains($0) }) {
                score += 2
            } else if scheduleTokens.contains(where: { rowText.contains($0) }) {
                score += 1
            }
        }
        if distanceDays == 0 { score += 1 }
        return score
    }
}

import Foundation

/// A budget month (`YYYY-MM`) in the immutable budget calendar.
public struct BudgetMonth: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let year: Int
    public let month: Int // 1...12

    public init?(year: Int, month: Int) {
        guard (1...12).contains(month), (1...9999).contains(year) else { return nil }
        self.year = year
        self.month = month
    }

    /// Parses `"YYYY-MM"`.
    public init?(string: String) {
        let parts = string.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 4, parts[1].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1])
        else { return nil }
        self.init(year: y, month: m)
    }

    public var next: BudgetMonth {
        month == 12 ? BudgetMonth(year: year + 1, month: 1)! : BudgetMonth(year: year, month: month + 1)!
    }

    public var previous: BudgetMonth {
        month == 1 ? BudgetMonth(year: year - 1, month: 12)! : BudgetMonth(year: year, month: month - 1)!
    }

    public static func < (lhs: BudgetMonth, rhs: BudgetMonth) -> Bool {
        (lhs.year, lhs.month) < (rhs.year, rhs.month)
    }

    public var description: String {
        String(format: "%04d-%02d", year, month)
    }

    /// Inclusive sequence `self...end`; empty when `end < self`.
    public func months(through end: BudgetMonth) -> [BudgetMonth] {
        var result: [BudgetMonth] = []
        var current = self
        while current <= end {
            result.append(current)
            current = current.next
        }
        return result
    }
}

/// A budget-calendar date (`YYYY-MM-DD`). Validity of the day-of-month is
/// checked against the proleptic Gregorian calendar.
public struct BudgetDate: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init?(year: Int, month: Int, day: Int) {
        guard let m = BudgetMonth(year: year, month: month) else { return nil }
        guard day >= 1, day <= BudgetDate.daysIn(month: m) else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    /// Parses `"YYYY-MM-DD"`.
    public init?(string: String) {
        let parts = string.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2])
        else { return nil }
        self.init(year: y, month: m, day: d)
    }

    public var budgetMonth: BudgetMonth { BudgetMonth(year: year, month: month)! }

    public static func < (lhs: BudgetDate, rhs: BudgetDate) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    public var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    static func daysIn(month: BudgetMonth) -> Int {
        switch month.month {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        default:
            let y = month.year
            let leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
            return leap ? 29 : 28
        }
    }
}

public enum BudgetCalendarError: Error, Equatable, Sendable {
    case invalidTimeZoneIdentifier(String)
    case unrepresentableDate
}

/// Epoch ↔ budget-date conversion pinned to the immutable budget time zone.
/// The zone is captured at budget creation so an epoch always maps to the same
/// budget date.
public struct BudgetCalendar: Sendable {
    public let timeZoneIdentifier: String
    private let calendar: Calendar

    public init(timeZoneIdentifier: String) throws {
        guard let zone = TimeZone(identifier: timeZoneIdentifier) else {
            throw BudgetCalendarError.invalidTimeZoneIdentifier(timeZoneIdentifier)
        }
        self.timeZoneIdentifier = timeZoneIdentifier
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        self.calendar = cal
    }

    /// Converts a Unix epoch (integer seconds, UTC) to the budget-calendar date.
    public func budgetDate(fromEpoch epoch: Int64) -> BudgetDate? {
        let date = Date(timeIntervalSince1970: TimeInterval(epoch))
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        guard let y = comps.year, let m = comps.month, let d = comps.day else { return nil }
        return BudgetDate(year: y, month: m, day: d)
    }

    /// Local noon of the given budget date, as a Unix epoch. Used as the
    /// effective ordering timestamp for manually entered transactions.
    public func noonEpoch(of date: BudgetDate) throws -> Int64 {
        var comps = DateComponents()
        comps.year = date.year
        comps.month = date.month
        comps.day = date.day
        comps.hour = 12
        comps.minute = 0
        comps.second = 0
        guard let noon = calendar.date(from: comps) else {
            throw BudgetCalendarError.unrepresentableDate
        }
        return Int64(noon.timeIntervalSince1970.rounded())
    }

    /// Epoch of the first instant of the budget month (used for anchor
    /// truncation at `budget.first_month`).
    public func monthStartEpoch(of month: BudgetMonth) throws -> Int64 {
        var comps = DateComponents()
        comps.year = month.year
        comps.month = month.month
        comps.day = 1
        comps.hour = 0
        comps.minute = 0
        comps.second = 0
        guard let start = calendar.date(from: comps) else {
            throw BudgetCalendarError.unrepresentableDate
        }
        return Int64(start.timeIntervalSince1970.rounded())
    }
}

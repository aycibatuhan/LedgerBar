import Foundation

/// Resolved period with the interpretation the assistant states back.
public struct ResolvedPeriod: Sendable, Equatable {
    public var start: BudgetDate
    public var end: BudgetDate
    public var months: ClosedRange<BudgetMonth>
    public var interpretation: String

    public init(start: BudgetDate, end: BudgetDate, interpretation: String) {
        self.start = start
        self.end = end
        self.months = start.budgetMonth...end.budgetMonth
        self.interpretation = interpretation
    }
}

/// Deterministic relative-date resolution in the budget calendar (A3).
/// Ambiguity is resolved by fixed rules and always stated in
/// `interpretation`; nothing here consults the model.
public enum DateExpressionResolver {
    private static let monthNames = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]
    private static let monthAbbreviations = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    public static func resolve(_ expression: String, today: BudgetDate, firstMonth: BudgetMonth) -> ResolvedPeriod? {
        let text = expression.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "  ", with: " ")
        let currentMonth = today.budgetMonth
        func monthRange(_ range: ClosedRange<BudgetMonth>, _ label: String) -> ResolvedPeriod {
            let start = BudgetDate(year: range.lowerBound.year, month: range.lowerBound.month, day: 1)!
            let end = BudgetDate(year: range.upperBound.year, month: range.upperBound.month, day: BudgetDate.daysIn(month: range.upperBound))!
            return ResolvedPeriod(start: start, end: end, interpretation: label)
        }
        func back(_ n: Int) -> BudgetMonth { var m = currentMonth; for _ in 0..<n { m = m.previous }; return m }

        switch text {
        case "", "all time", "ever", "everything", "overall", "all":
            return monthRange(firstMonth...currentMonth, "all time (\(firstMonth.description) to \(currentMonth.description))")
        case "today":
            return ResolvedPeriod(start: today, end: today, interpretation: "today (\(today.description))")
        case "yesterday":
            let d = RecurrenceEngine.adding(days: -1, to: today)
            return ResolvedPeriod(start: d, end: d, interpretation: "yesterday (\(d.description))")
        case "tomorrow":
            let d = RecurrenceEngine.adding(days: 1, to: today)
            return ResolvedPeriod(start: d, end: d, interpretation: "tomorrow (\(d.description))")
        case "next week", "the next week", "coming week":
            let end = RecurrenceEngine.adding(days: 7, to: today)
            return ResolvedPeriod(start: today, end: end, interpretation: "the next 7 days (\(today.description) to \(end.description))")
        case "next month", "the next month":
            return monthRange(currentMonth.next...currentMonth.next, "next month (\(currentMonth.next.description))")
        case "next 30 days", "the next 30 days", "next month or so":
            let end = RecurrenceEngine.adding(days: 30, to: today)
            return ResolvedPeriod(start: today, end: end, interpretation: "the next 30 days (\(today.description) to \(end.description))")
        case "this month", "current month", "month to date", "mtd":
            return monthRange(currentMonth...currentMonth, "this month (\(currentMonth.description))")
        case "last month", "previous month", "prior month":
            return monthRange(back(1)...back(1), "last month (\(back(1).description))")
        case "this year", "year to date", "ytd":
            let start = BudgetMonth(year: currentMonth.year, month: 1)!
            return monthRange(start...currentMonth, "this year so far (\(start.description) to \(currentMonth.description))")
        case "last year", "previous year":
            let y = currentMonth.year - 1
            return monthRange(BudgetMonth(year: y, month: 1)!...BudgetMonth(year: y, month: 12)!, "last year (\(y))")
        case "this quarter":
            let q = (currentMonth.month - 1) / 3
            let start = BudgetMonth(year: currentMonth.year, month: q * 3 + 1)!
            return monthRange(start...currentMonth, "this quarter so far (Q\(q + 1) \(currentMonth.year))")
        case "last quarter", "previous quarter":
            let q = (currentMonth.month - 1) / 3
            var year = currentMonth.year
            var quarter = q - 1
            if quarter < 0 { quarter = 3; year -= 1 }
            let start = BudgetMonth(year: year, month: quarter * 3 + 1)!
            let end = BudgetMonth(year: year, month: quarter * 3 + 3)!
            return monthRange(start...end, "last quarter (Q\(quarter + 1) \(year))")
        case "this week":
            let weekday = RecurrenceEngine.weekday(of: today)
            let start = RecurrenceEngine.adding(days: -(weekday - 1), to: today)
            return ResolvedPeriod(start: start, end: today, interpretation: "this week so far (\(start.description) to \(today.description))")
        case "last week":
            let weekday = RecurrenceEngine.weekday(of: today)
            let thisStart = RecurrenceEngine.adding(days: -(weekday - 1), to: today)
            let start = RecurrenceEngine.adding(days: -7, to: thisStart)
            let end = RecurrenceEngine.adding(days: -1, to: thisStart)
            return ResolvedPeriod(start: start, end: end, interpretation: "last week (\(start.description) to \(end.description))")
        default:
            break
        }

        // "last N months|weeks|days|years", "past N …"
        let scanner = text.replacingOccurrences(of: "past ", with: "last ").replacingOccurrences(of: "previous ", with: "last ")
        if scanner.hasPrefix("last ") || scanner.hasPrefix("next ") {
            let parts = scanner.split(separator: " ").map(String.init)
            if parts.count == 3, let n = Int(parts[1]) ?? wordNumber(parts[1]), n > 0 {
                let future = parts[0] == "next"
                switch parts[2].trimmingCharacters(in: CharacterSet(charactersIn: "s")) {
                case "month":
                    if future {
                        var end = currentMonth; for _ in 0..<n { end = end.next }
                        return monthRange(currentMonth.next...end, "the next \(n) month(s)")
                    }
                    return monthRange(back(n - 1)...currentMonth, "the last \(n) month(s) including this one (\(back(n - 1).description) to \(currentMonth.description))")
                case "week", "day":
                    let days = parts[2].hasPrefix("week") ? n * 7 : n
                    if future {
                        let end = RecurrenceEngine.adding(days: days, to: today)
                        return ResolvedPeriod(start: today, end: end, interpretation: "the next \(days) days (\(today.description) to \(end.description))")
                    }
                    let start = RecurrenceEngine.adding(days: -(days - 1), to: today)
                    return ResolvedPeriod(start: start, end: today, interpretation: "the last \(days) days (\(start.description) to \(today.description))")
                case "year":
                    let start = BudgetMonth(year: currentMonth.year - n + 1, month: 1)!
                    return monthRange(start...currentMonth, "the last \(n) year(s) to date")
                default: break
                }
            }
        }
        // Quarter: "q3", "q3 2025", "third quarter"
        if let match = text.range(of: #"^q([1-4])(?:\s+(\d{4}))?$"#, options: .regularExpression) {
            let body = String(text[match])
            let q = Int(body.dropFirst().prefix(1))!
            let year = body.split(separator: " ").count > 1 ? Int(body.split(separator: " ")[1]) ?? currentMonth.year : currentMonth.year
            let start = BudgetMonth(year: year, month: (q - 1) * 3 + 1)!
            let end = BudgetMonth(year: year, month: (q - 1) * 3 + 3)!
            return monthRange(start...end, "Q\(q) \(year)")
        }
        // Year alone
        if text.count == 4, let year = Int(text), (1970...2100).contains(year) {
            return monthRange(BudgetMonth(year: year, month: 1)!...BudgetMonth(year: year, month: 12)!, "the year \(year)")
        }
        // "since march", "since 2025-03", "from march"
        if text.hasPrefix("since ") || text.hasPrefix("from ") {
            let remainder = String(text.drop(while: { $0 != " " }).dropFirst())
            if let start = monthFromText(remainder, currentMonth: currentMonth) {
                let startMonth = start <= currentMonth ? start : BudgetMonth(year: start.year - 1, month: start.month)!
                return monthRange(startMonth...currentMonth, "since \(startMonth.description)")
            }
        }
        // A month name, optionally with a year; a bare month means the most recent occurrence.
        if let m = monthFromText(text, currentMonth: currentMonth) {
            let resolved = m <= currentMonth || text.contains(where: \.isNumber) ? m : BudgetMonth(year: m.year - 1, month: m.month)!
            return monthRange(resolved...resolved, "\(ReportEngine.monthLabel(resolved))")
        }
        // ISO month or date ranges "2025-01 to 2025-03", "2025-01-05 to 2025-02-10"
        let separators = [" to ", " through ", " - ", "..", " until "]
        for separator in separators where text.contains(separator) {
            let sides = text.components(separatedBy: separator)
            guard sides.count == 2 else { continue }
            if let a = BudgetMonth(string: sides[0].trimmingCharacters(in: .whitespaces)), let b = BudgetMonth(string: sides[1].trimmingCharacters(in: .whitespaces)) {
                return monthRange(min(a, b)...max(a, b), "\(min(a, b).description) to \(max(a, b).description)")
            }
            if let a = BudgetDate(string: sides[0].trimmingCharacters(in: .whitespaces)), let b = BudgetDate(string: sides[1].trimmingCharacters(in: .whitespaces)) {
                return ResolvedPeriod(start: min(a, b), end: max(a, b), interpretation: "\(min(a, b).description) to \(max(a, b).description)")
            }
        }
        if let m = BudgetMonth(string: text) { return monthRange(m...m, m.description) }
        if let d = BudgetDate(string: text) { return ResolvedPeriod(start: d, end: d, interpretation: d.description) }
        return nil
    }

    static func monthFromText(_ text: String, currentMonth: BudgetMonth) -> BudgetMonth? {
        let parts = text.split(separator: " ").map(String.init)
        guard let first = parts.first else { return nil }
        let index = monthNames.firstIndex(of: first) ?? monthAbbreviations.firstIndex(of: String(first.prefix(3)))
        guard let monthIndex = index, monthNames[monthIndex].hasPrefix(String(first.prefix(3))) else { return nil }
        let year = parts.count > 1 ? Int(parts[1]) : nil
        guard parts.count <= 2 else { return nil }
        return BudgetMonth(year: year ?? currentMonth.year, month: monthIndex + 1)
    }

    static func wordNumber(_ word: String) -> Int? {
        ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "twelve": 12][word]
    }
}

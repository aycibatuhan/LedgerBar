import Foundation

// MARK: - Definition (docs/DESIGN.md D7.1)

public enum ReportKind: String, Sendable, Codable, CaseIterable {
    case spendingByCategory
    case spendingByGroup
    case spendingByPayee
    case spendingByAccount
    case spendingOverTime
    case incomeVsSpending
    case netWorth
    case budgetVsActual

    public var title: String {
        switch self {
        case .spendingByCategory: return "Spending by Category"
        case .spendingByGroup: return "Spending by Group"
        case .spendingByPayee: return "Spending by Payee"
        case .spendingByAccount: return "Spending by Account"
        case .spendingOverTime: return "Spending Over Time"
        case .incomeVsSpending: return "Income vs Spending"
        case .netWorth: return "Net Worth"
        case .budgetVsActual: return "Budget vs Actual"
        }
    }

    /// Whether the report is a series over periods (true) or a ranked
    /// breakdown at a single total (false).
    public var isTimeSeries: Bool {
        switch self {
        case .spendingOverTime, .incomeVsSpending, .netWorth, .budgetVsActual: return true
        default: return false
        }
    }
}

public enum RelativePeriod: String, Sendable, Codable, CaseIterable {
    case thisMonth, lastMonth, last3Months, last6Months, last12Months, yearToDate, thisYear, lastYear, allTime

    public var title: String {
        switch self {
        case .thisMonth: return "This month"
        case .lastMonth: return "Last month"
        case .last3Months: return "Last 3 months"
        case .last6Months: return "Last 6 months"
        case .last12Months: return "Last 12 months"
        case .yearToDate: return "Year to date"
        case .thisYear: return "This year"
        case .lastYear: return "Last year"
        case .allTime: return "All time"
        }
    }
}

public enum ReportDateRange: Sendable, Codable, Equatable, Hashable {
    case relative(RelativePeriod)
    case absolute(from: BudgetMonth, to: BudgetMonth)

    /// Resolves to an inclusive month range in the budget calendar. `current`
    /// is the budget's observed month; `first` bounds `allTime` and clamps.
    public func months(current: BudgetMonth, first: BudgetMonth) -> ClosedRange<BudgetMonth> {
        switch self {
        case .absolute(let from, let to):
            return min(from, to)...max(from, to)
        case .relative(let period):
            func back(_ n: Int) -> BudgetMonth {
                var m = current
                for _ in 0..<n { m = m.previous }
                return m
            }
            switch period {
            case .thisMonth: return current...current
            case .lastMonth: return current.previous...current.previous
            case .last3Months: return back(2)...current
            case .last6Months: return back(5)...current
            case .last12Months: return back(11)...current
            case .yearToDate, .thisYear:
                let start = BudgetMonth(year: current.year, month: 1)!
                let end = period == .thisYear ? BudgetMonth(year: current.year, month: 12)! : current
                return start...end
            case .lastYear:
                return BudgetMonth(year: current.year - 1, month: 1)!...BudgetMonth(year: current.year - 1, month: 12)!
            case .allTime:
                return first...current
            }
        }
    }
}

public enum ReportGranularity: String, Sendable, Codable, CaseIterable {
    case month, quarter, year

    public var title: String { rawValue.capitalized }
}

public enum ReportDirection: String, Sendable, Codable {
    case outflow, inflow
}

public struct ReportFilters: Sendable, Codable, Equatable, Hashable {
    public var accountIDs: Set<AccountID>?
    public var accountTypes: Set<AccountType>?
    public var categoryIDs: Set<CategoryID>?
    public var groupIDs: Set<CategoryGroupID>?
    public var payeeIDs: Set<PayeeID>?
    public var direction: ReportDirection?
    public var minMagnitudeMilliunits: Milliunits?
    public var maxMagnitudeMilliunits: Milliunits?
    public var searchText: String?
    /// Staged rows are excluded from category reports by default (D7.2).
    public var includeStaged: Bool
    /// Openings and adjustments count as income only when opted in.
    public var includeOpeningsAndAdjustmentsAsIncome: Bool
    public var onlyApproved: Bool

    public init(
        accountIDs: Set<AccountID>? = nil,
        accountTypes: Set<AccountType>? = nil,
        categoryIDs: Set<CategoryID>? = nil,
        groupIDs: Set<CategoryGroupID>? = nil,
        payeeIDs: Set<PayeeID>? = nil,
        direction: ReportDirection? = nil,
        minMagnitudeMilliunits: Milliunits? = nil,
        maxMagnitudeMilliunits: Milliunits? = nil,
        searchText: String? = nil,
        includeStaged: Bool = false,
        includeOpeningsAndAdjustmentsAsIncome: Bool = false,
        onlyApproved: Bool = false
    ) {
        self.accountIDs = accountIDs
        self.accountTypes = accountTypes
        self.categoryIDs = categoryIDs
        self.groupIDs = groupIDs
        self.payeeIDs = payeeIDs
        self.direction = direction
        self.minMagnitudeMilliunits = minMagnitudeMilliunits
        self.maxMagnitudeMilliunits = maxMagnitudeMilliunits
        self.searchText = searchText
        self.includeStaged = includeStaged
        self.includeOpeningsAndAdjustmentsAsIncome = includeOpeningsAndAdjustmentsAsIncome
        self.onlyApproved = onlyApproved
    }
}

public enum ReportVisualization: String, Sendable, Codable, CaseIterable {
    case bar, stackedBar, line, area, donut, table

    public var title: String {
        switch self {
        case .bar: return "Bar"
        case .stackedBar: return "Stacked bar"
        case .line: return "Line"
        case .area: return "Area"
        case .donut: return "Donut"
        case .table: return "Table"
        }
    }
}

public struct ReportDefinition: Sendable, Codable, Equatable, Hashable {
    public var kind: ReportKind
    public var range: ReportDateRange
    public var granularity: ReportGranularity
    public var filters: ReportFilters
    public var comparePreviousPeriod: Bool
    /// Top-N cutoff for breakdowns; the remainder is summarized as "Other".
    public var limit: Int?
    public var visualization: ReportVisualization
    /// For stacked/over-time reports: split each period by category (true)
    /// or show one total series (false).
    public var breakdownByCategory: Bool

    public init(
        kind: ReportKind,
        range: ReportDateRange = .relative(.last12Months),
        granularity: ReportGranularity = .month,
        filters: ReportFilters = ReportFilters(),
        comparePreviousPeriod: Bool = false,
        limit: Int? = nil,
        visualization: ReportVisualization? = nil,
        breakdownByCategory: Bool = false
    ) {
        self.kind = kind
        self.range = range
        self.granularity = granularity
        self.filters = filters
        self.comparePreviousPeriod = comparePreviousPeriod
        self.limit = limit
        self.visualization = visualization ?? kind.defaultVisualization
        self.breakdownByCategory = breakdownByCategory
    }
}

public extension ReportKind {
    var defaultVisualization: ReportVisualization {
        switch self {
        case .spendingByCategory, .spendingByGroup, .spendingByPayee, .spendingByAccount: return .bar
        case .spendingOverTime: return .bar
        case .incomeVsSpending: return .bar
        case .netWorth: return .line
        case .budgetVsActual: return .bar
        }
    }
}

/// A saved report (budget-scoped).
public struct ReportRow: Sendable, Codable, Equatable, Identifiable {
    public var id: ReportID
    public var budgetID: BudgetID
    public var name: String
    public var definition: ReportDefinition
    public var sortOrder: Int
    public var createdAtEpoch: Int64
    public var updatedAtEpoch: Int64

    public init(
        id: ReportID = ReportID(),
        budgetID: BudgetID,
        name: String,
        definition: ReportDefinition,
        sortOrder: Int,
        createdAtEpoch: Int64,
        updatedAtEpoch: Int64
    ) {
        self.id = id
        self.budgetID = budgetID
        self.name = name
        self.definition = definition
        self.sortOrder = sortOrder
        self.createdAtEpoch = createdAtEpoch
        self.updatedAtEpoch = updatedAtEpoch
    }
}

// MARK: - Result

/// One column of a time-series report, or the single period of a breakdown.
public struct ReportPeriod: Sendable, Equatable, Hashable, Identifiable {
    public var start: BudgetMonth
    public var end: BudgetMonth
    public var label: String
    public var id: String { start.description }
}

public struct ReportPoint: Sendable, Equatable {
    public var periodIndex: Int
    public var valueMilliunits: Milliunits
}

public struct ReportSeries: Sendable, Equatable, Identifiable {
    public var key: String
    public var label: String
    public var points: [ReportPoint]
    public var id: String { key }
}

/// A ranked row of a breakdown, or a per-series total for time series.
public struct ReportTableRow: Sendable, Equatable, Identifiable {
    public var key: String
    public var label: String
    public var valueMilliunits: Milliunits
    public var count: Int
    public var previousValueMilliunits: Milliunits?
    /// Line ids contributing to this row (bounded to 500).
    public var lineIDs: [String]
    public var id: String { key }

    public var deltaMilliunits: Milliunits? {
        guard let previous = previousValueMilliunits else { return nil }
        let (delta, overflow) = valueMilliunits.subtractingReportingOverflow(previous)
        return overflow ? nil : delta
    }
}

public struct ReportResult: Sendable, Equatable {
    public var definition: ReportDefinition
    public var title: String
    public var months: ClosedRange<BudgetMonth>
    public var periods: [ReportPeriod]
    public var series: [ReportSeries]
    public var rows: [ReportTableRow]
    public var totalMilliunits: Milliunits
    public var previousTotalMilliunits: Milliunits?
    /// Names to print beside excluded accounts (currency mismatch).
    public var excludedAccountNames: [String]
    /// Human-readable statement of the semantics applied (D7.2).
    public var semanticsNote: String
}

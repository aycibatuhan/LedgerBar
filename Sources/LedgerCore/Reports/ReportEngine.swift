import Foundation

/// Pure report evaluation over a snapshot (and, for budget-vs-actual, the
/// projection). Deterministic: identical inputs yield identical results,
/// including row and series order.
public enum ReportEngine {

    private static let provenanceLimit = 500

    public static func evaluate(
        _ definition: ReportDefinition,
        snapshot: BudgetWorkspaceSnapshot,
        projection: ProjectionResult?
    ) -> ReportResult {
        let current = snapshot.budget.lastObservedBudgetMonth
        let months = definition.range.months(current: current, first: snapshot.budget.firstMonth)
        let periods = makePeriods(months, granularity: definition.granularity)
        let accountsByID = Dictionary(uniqueKeysWithValues: snapshot.accounts.map { ($0.id, $0) })
        let categoriesByID = Dictionary(uniqueKeysWithValues: snapshot.categories.map { ($0.id, $0) })
        let groupsByID = Dictionary(uniqueKeysWithValues: snapshot.categoryGroups.map { ($0.id, $0) })
        let payeesByID = Dictionary(uniqueKeysWithValues: snapshot.payees.map { ($0.id, $0) })
        let excluded = snapshot.accounts.filter { $0.currency != snapshot.budget.currency }.map(\.name).sorted()
        let lines = snapshot.categoryLines()

        switch definition.kind {
        case .netWorth:
            return netWorth(definition, snapshot: snapshot, months: months, periods: periods, excluded: excluded)
        case .budgetVsActual:
            return budgetVsActual(definition, snapshot: snapshot, projection: projection, months: months, periods: periods, categoriesByID: categoriesByID, excluded: excluded)
        default:
            break
        }

        let filtered = lines.filter { line in
            months.contains(line.month) && passesFilters(line, definition.filters, accountsByID: accountsByID, categoriesByID: categoriesByID, payeesByID: payeesByID)
        }
        let previousMonths: ClosedRange<BudgetMonth>? = definition.comparePreviousPeriod ? previousRange(months) : nil
        let previous: [CategoryLine] = previousMonths.map { range in
            lines.filter { line in
                range.contains(line.month) && passesFilters(line, definition.filters, accountsByID: accountsByID, categoriesByID: categoriesByID, payeesByID: payeesByID)
            }
        } ?? []

        switch definition.kind {
        case .spendingByCategory, .spendingByGroup, .spendingByPayee, .spendingByAccount:
            return breakdown(definition, current: filtered, previous: previous, months: months, periods: periods,
                             categoriesByID: categoriesByID, groupsByID: groupsByID, payeesByID: payeesByID,
                             accountsByID: accountsByID, excluded: excluded)
        case .spendingOverTime:
            return spendingOverTime(definition, current: filtered, previous: previous, months: months, periods: periods,
                                    previousMonths: previousMonths, categoriesByID: categoriesByID, excluded: excluded)
        case .incomeVsSpending:
            return incomeVsSpending(definition, current: filtered, months: months, periods: periods, excluded: excluded)
        case .netWorth, .budgetVsActual:
            fatalError("handled above")
        }
    }

    // MARK: - Semantics helpers (D7.2)

    /// Spending lines: role spending (negative) and refund (positive). Net
    /// spending is `-(spending + refunds)` so a $50 purchase refunded $10
    /// reads as $40 spent.
    static func isSpendingLine(_ line: CategoryLine, includeStaged: Bool) -> Bool {
        switch line.role {
        case .spending, .refund: return true
        case .staged: return includeStaged && line.amountMilliunits < 0
        default: return false
        }
    }

    static func isIncomeLine(_ line: CategoryLine, filters: ReportFilters) -> Bool {
        switch line.role {
        case .income: return true
        case .opening, .adjustment: return filters.includeOpeningsAndAdjustmentsAsIncome
        case .staged: return filters.includeStaged && line.amountMilliunits > 0
        default: return false
        }
    }

    static func passesFilters(
        _ line: CategoryLine,
        _ filters: ReportFilters,
        accountsByID: [AccountID: AccountRow],
        categoriesByID: [CategoryID: CategoryRow],
        payeesByID: [PayeeID: PayeeRow]
    ) -> Bool {
        if let accounts = filters.accountIDs, !accounts.contains(line.accountID) { return false }
        if let types = filters.accountTypes, let account = accountsByID[line.accountID], !types.contains(account.type) { return false }
        if let categories = filters.categoryIDs {
            guard let category = line.categoryID, categories.contains(category) else { return false }
        }
        if let groups = filters.groupIDs {
            guard let category = line.categoryID, let groupID = categoriesByID[category]?.groupID, groups.contains(groupID) else { return false }
        }
        if let payees = filters.payeeIDs {
            guard let payee = line.payeeID, payees.contains(payee) else { return false }
        }
        if let direction = filters.direction {
            switch direction {
            case .outflow: if line.amountMilliunits >= 0 { return false }
            case .inflow: if line.amountMilliunits <= 0 { return false }
            }
        }
        let magnitude = line.amountMilliunits.magnitude
        if let minimum = filters.minMagnitudeMilliunits, magnitude < minimum.magnitude { return false }
        if let maximum = filters.maxMagnitudeMilliunits, magnitude > maximum.magnitude { return false }
        if filters.onlyApproved && !line.approved { return false }
        if let text = filters.searchText, !text.isEmpty {
            let needle = BudgetWorkspace.normalizePayeeName(text)
            let haystacks = [
                line.payeeID.flatMap { payeesByID[$0]?.displayName }, line.memo, line.importedDescription
            ].compactMap { $0 }.map { BudgetWorkspace.normalizePayeeName($0) }
            guard haystacks.contains(where: { $0.contains(needle) }) else { return false }
        }
        return true
    }

    static func previousRange(_ months: ClosedRange<BudgetMonth>) -> ClosedRange<BudgetMonth> {
        let length = months.lowerBound.months(through: months.upperBound).count
        var end = months.lowerBound.previous
        var start = end
        for _ in 1..<max(length, 1) { start = start.previous }
        if length == 0 { end = start }
        return start...end
    }

    public static func makePeriods(_ months: ClosedRange<BudgetMonth>, granularity: ReportGranularity) -> [ReportPeriod] {
        var periods: [ReportPeriod] = []
        var cursor = months.lowerBound
        while cursor <= months.upperBound {
            let end: BudgetMonth
            let label: String
            switch granularity {
            case .month:
                end = cursor
                label = monthLabel(cursor)
            case .quarter:
                let quarterEndMonth = ((cursor.month - 1) / 3 + 1) * 3
                end = min(BudgetMonth(year: cursor.year, month: quarterEndMonth)!, months.upperBound)
                label = "Q\((cursor.month - 1) / 3 + 1) \(cursor.year)"
            case .year:
                end = min(BudgetMonth(year: cursor.year, month: 12)!, months.upperBound)
                label = String(cursor.year)
            }
            periods.append(ReportPeriod(start: cursor, end: end, label: label))
            cursor = end.next
        }
        return periods
    }

    public static func monthLabel(_ month: BudgetMonth) -> String {
        let names = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return "\(names[month.month - 1]) \(month.year)"
    }

    static func periodIndex(for month: BudgetMonth, in periods: [ReportPeriod]) -> Int? {
        periods.firstIndex { $0.start <= month && month <= $0.end }
    }

    private static func sumChecked(_ values: [Milliunits]) -> Milliunits {
        var total: Milliunits = 0
        for value in values {
            let (sum, overflow) = total.addingReportingOverflow(value)
            if overflow { return total }
            total = sum
        }
        return total
    }

    // MARK: - Breakdowns

    private static func breakdown(
        _ definition: ReportDefinition,
        current: [CategoryLine],
        previous: [CategoryLine],
        months: ClosedRange<BudgetMonth>,
        periods: [ReportPeriod],
        categoriesByID: [CategoryID: CategoryRow],
        groupsByID: [CategoryGroupID: CategoryGroupRow],
        payeesByID: [PayeeID: PayeeRow],
        accountsByID: [AccountID: AccountRow],
        excluded: [String]
    ) -> ReportResult {
        func key(_ line: CategoryLine) -> (String, String)? {
            switch definition.kind {
            case .spendingByCategory:
                guard let id = line.categoryID else { return nil }
                return (id.description, categoriesByID[id]?.name ?? "?")
            case .spendingByGroup:
                guard let id = line.categoryID, let groupID = categoriesByID[id]?.groupID else { return nil }
                return (groupID.description, groupsByID[groupID]?.name ?? "?")
            case .spendingByPayee:
                guard let id = line.payeeID else { return ("none", "No payee") }
                return (id.description, payeesByID[id]?.displayName ?? "?")
            case .spendingByAccount:
                return (line.accountID.description, accountsByID[line.accountID]?.name ?? "?")
            default:
                return nil
            }
        }
        struct Bucket { var label: String; var total: Milliunits = 0; var count = 0; var lineIDs: [String] = [] }
        var buckets: [String: Bucket] = [:]
        for line in current where isSpendingLine(line, includeStaged: definition.filters.includeStaged) {
            guard let (k, label) = key(line) else { continue }
            var bucket = buckets[k] ?? Bucket(label: label)
            bucket.total = sumChecked([bucket.total, -line.amountMilliunits])
            bucket.count += 1
            if bucket.lineIDs.count < provenanceLimit { bucket.lineIDs.append(line.id) }
            buckets[k] = bucket
        }
        var previousTotals: [String: Milliunits] = [:]
        for line in previous where isSpendingLine(line, includeStaged: definition.filters.includeStaged) {
            guard let (k, _) = key(line) else { continue }
            previousTotals[k] = sumChecked([previousTotals[k] ?? 0, -line.amountMilliunits])
        }
        var rows = buckets.map { k, bucket in
            ReportTableRow(key: k, label: bucket.label, valueMilliunits: bucket.total, count: bucket.count,
                           previousValueMilliunits: definition.comparePreviousPeriod ? (previousTotals[k] ?? 0) : nil,
                           lineIDs: bucket.lineIDs)
        }
        .sorted { ($0.valueMilliunits, $1.label) > ($1.valueMilliunits, $0.label) }
        if let limit = definition.limit, rows.count > limit, limit > 0 {
            let rest = rows[limit...]
            let other = ReportTableRow(
                key: "other", label: "Other (\(rest.count))",
                valueMilliunits: sumChecked(rest.map(\.valueMilliunits)), count: rest.reduce(0) { $0 + $1.count },
                previousValueMilliunits: definition.comparePreviousPeriod ? sumChecked(rest.compactMap(\.previousValueMilliunits)) : nil,
                lineIDs: Array(rest.flatMap(\.lineIDs).prefix(provenanceLimit))
            )
            rows = Array(rows.prefix(limit)) + [other]
        }
        let total = sumChecked(rows.map(\.valueMilliunits))
        let previousTotal = definition.comparePreviousPeriod ? sumChecked(previousTotals.values.map { $0 }) : nil
        let series = [ReportSeries(key: "spending", label: "Net spending",
                                   points: rows.enumerated().map { ReportPoint(periodIndex: $0.offset, valueMilliunits: $0.element.valueMilliunits) })]
        return ReportResult(
            definition: definition, title: definition.kind.title, months: months, periods: periods, series: series,
            rows: rows, totalMilliunits: total, previousTotalMilliunits: previousTotal, excludedAccountNames: excluded,
            semanticsNote: spendingNote(definition.filters)
        )
    }

    private static func spendingNote(_ filters: ReportFilters) -> String {
        var note = "Net spending = category outflows minus refunds. Transfers and credit-card payments are not spending; voided rows are never counted"
        note += filters.includeStaged ? "; staged rows are included." : "; staged rows are excluded."
        return note
    }

    // MARK: - Time series

    private static func spendingOverTime(
        _ definition: ReportDefinition,
        current: [CategoryLine],
        previous: [CategoryLine],
        months: ClosedRange<BudgetMonth>,
        periods: [ReportPeriod],
        previousMonths: ClosedRange<BudgetMonth>?,
        categoriesByID: [CategoryID: CategoryRow],
        excluded: [String]
    ) -> ReportResult {
        var seriesTotals: [String: (label: String, values: [Milliunits], lineIDs: [String], count: Int)] = [:]
        func add(_ key: String, _ label: String, periodIndex: Int, amount: Milliunits, lineID: String) {
            var entry = seriesTotals[key] ?? (label, [Milliunits](repeating: 0, count: periods.count), [], 0)
            entry.values[periodIndex] = sumChecked([entry.values[periodIndex], amount])
            entry.count += 1
            if entry.lineIDs.count < provenanceLimit { entry.lineIDs.append(lineID) }
            seriesTotals[key] = entry
        }
        for line in current where isSpendingLine(line, includeStaged: definition.filters.includeStaged) {
            guard let index = periodIndex(for: line.month, in: periods) else { continue }
            if definition.breakdownByCategory, let categoryID = line.categoryID {
                add(categoryID.description, categoriesByID[categoryID]?.name ?? "?", periodIndex: index, amount: -line.amountMilliunits, lineID: line.id)
            } else {
                add("spending", "Net spending", periodIndex: index, amount: -line.amountMilliunits, lineID: line.id)
            }
        }
        var series = seriesTotals.map { key, entry in
            ReportSeries(key: key, label: entry.label, points: entry.values.enumerated().map { ReportPoint(periodIndex: $0.offset, valueMilliunits: $0.element) })
        }
        .sorted { (sumChecked($0.points.map(\.valueMilliunits)), $1.label) > (sumChecked($1.points.map(\.valueMilliunits)), $0.label) }
        if let limit = definition.limit, definition.breakdownByCategory, series.count > limit, limit > 0 {
            let rest = series[limit...]
            var otherValues = [Milliunits](repeating: 0, count: periods.count)
            for s in rest { for p in s.points { otherValues[p.periodIndex] = sumChecked([otherValues[p.periodIndex], p.valueMilliunits]) } }
            series = Array(series.prefix(limit)) + [ReportSeries(key: "other", label: "Other", points: otherValues.enumerated().map { ReportPoint(periodIndex: $0.offset, valueMilliunits: $0.element) })]
        }
        if definition.comparePreviousPeriod, let previousMonths {
            let previousPeriods = makePeriods(previousMonths, granularity: definition.granularity)
            var values = [Milliunits](repeating: 0, count: periods.count)
            for line in previous where isSpendingLine(line, includeStaged: definition.filters.includeStaged) {
                guard let index = periodIndex(for: line.month, in: previousPeriods), index < values.count else { continue }
                values[index] = sumChecked([values[index], -line.amountMilliunits])
            }
            series.append(ReportSeries(key: "previous", label: "Previous period", points: values.enumerated().map { ReportPoint(periodIndex: $0.offset, valueMilliunits: $0.element) }))
        }
        let rows = series.filter { $0.key != "previous" }.map { s in
            ReportTableRow(key: s.key, label: s.label, valueMilliunits: sumChecked(s.points.map(\.valueMilliunits)),
                           count: seriesTotals[s.key]?.count ?? 0,
                           previousValueMilliunits: definition.comparePreviousPeriod ? sumChecked(series.first { $0.key == "previous" }?.points.map(\.valueMilliunits) ?? []) : nil,
                           lineIDs: seriesTotals[s.key]?.lineIDs ?? [])
        }
        let total = sumChecked(rows.map(\.valueMilliunits))
        return ReportResult(
            definition: definition, title: definition.kind.title, months: months, periods: periods, series: series,
            rows: rows, totalMilliunits: total,
            previousTotalMilliunits: definition.comparePreviousPeriod ? sumChecked(series.first { $0.key == "previous" }?.points.map(\.valueMilliunits) ?? []) : nil,
            excludedAccountNames: excluded, semanticsNote: spendingNote(definition.filters)
        )
    }

    private static func incomeVsSpending(
        _ definition: ReportDefinition,
        current: [CategoryLine],
        months: ClosedRange<BudgetMonth>,
        periods: [ReportPeriod],
        excluded: [String]
    ) -> ReportResult {
        var income = [Milliunits](repeating: 0, count: periods.count)
        var spending = [Milliunits](repeating: 0, count: periods.count)
        var incomeIDs: [String] = []
        var spendingIDs: [String] = []
        var incomeCount = 0, spendingCount = 0
        for line in current {
            guard let index = periodIndex(for: line.month, in: periods) else { continue }
            if isIncomeLine(line, filters: definition.filters) {
                income[index] = sumChecked([income[index], line.amountMilliunits])
                incomeCount += 1
                if incomeIDs.count < provenanceLimit { incomeIDs.append(line.id) }
            } else if isSpendingLine(line, includeStaged: definition.filters.includeStaged) {
                spending[index] = sumChecked([spending[index], -line.amountMilliunits])
                spendingCount += 1
                if spendingIDs.count < provenanceLimit { spendingIDs.append(line.id) }
            }
        }
        let net = zip(income, spending).map { sumChecked([$0, -$1]) }
        let series = [
            ReportSeries(key: "income", label: "Income", points: income.enumerated().map { ReportPoint(periodIndex: $0.offset, valueMilliunits: $0.element) }),
            ReportSeries(key: "spending", label: "Spending", points: spending.enumerated().map { ReportPoint(periodIndex: $0.offset, valueMilliunits: $0.element) }),
            ReportSeries(key: "net", label: "Net", points: net.enumerated().map { ReportPoint(periodIndex: $0.offset, valueMilliunits: $0.element) })
        ]
        let rows = [
            ReportTableRow(key: "income", label: "Income", valueMilliunits: sumChecked(income), count: incomeCount, previousValueMilliunits: nil, lineIDs: incomeIDs),
            ReportTableRow(key: "spending", label: "Spending", valueMilliunits: sumChecked(spending), count: spendingCount, previousValueMilliunits: nil, lineIDs: spendingIDs),
            ReportTableRow(key: "net", label: "Net", valueMilliunits: sumChecked(net), count: 0, previousValueMilliunits: nil, lineIDs: [])
        ]
        return ReportResult(
            definition: definition, title: definition.kind.title, months: months, periods: periods, series: series, rows: rows,
            totalMilliunits: sumChecked(net), previousTotalMilliunits: nil, excludedAccountNames: excluded,
            semanticsNote: "Income = inflows to Ready to Assign (including off-budget → on-budget transfers)" + (definition.filters.includeOpeningsAndAdjustmentsAsIncome ? ", openings, and adjustments" : "; openings and adjustments excluded") + ". Spending = net category outflows. Transfers and card payments are neither."
        )
    }

    /// Net worth: month-end register balances of every account in the
    /// budget currency (on- and off-budget), staged rows included because
    /// they are real money in the account.
    private static func netWorth(
        _ definition: ReportDefinition,
        snapshot: BudgetWorkspaceSnapshot,
        months: ClosedRange<BudgetMonth>,
        periods: [ReportPeriod],
        excluded: [String]
    ) -> ReportResult {
        let eligibleAccounts = snapshot.accounts.filter { $0.currency == snapshot.budget.currency }
        let accountFilter = definition.filters.accountIDs
        let included = eligibleAccounts.filter { accountFilter?.contains($0.id) ?? true }
        let includedIDs = Set(included.map(\.id))
        let rows = snapshot.transactions
            .filter { $0.postingState != .voided && includedIDs.contains($0.accountID) }
            .sorted { ($0.date, $0.id) < ($1.date, $1.id) }
        var assets = [Milliunits](repeating: 0, count: periods.count)
        var liabilities = [Milliunits](repeating: 0, count: periods.count)
        var perAccount: [AccountID: [Milliunits]] = [:]
        for (index, period) in periods.enumerated() {
            var balances: [AccountID: Milliunits] = [:]
            for row in rows where row.date.budgetMonth <= period.end {
                balances[row.accountID] = sumChecked([balances[row.accountID] ?? 0, row.amountMilliunits])
            }
            for account in included {
                let balance = balances[account.id] ?? 0
                perAccount[account.id, default: [Milliunits](repeating: 0, count: periods.count)][index] = balance
                if account.type == .creditCard || balance < 0 {
                    liabilities[index] = sumChecked([liabilities[index], balance])
                } else {
                    assets[index] = sumChecked([assets[index], balance])
                }
            }
        }
        let net = zip(assets, liabilities).map { sumChecked([$0, $1]) }
        var series = [
            ReportSeries(key: "net", label: "Net worth", points: net.enumerated().map { ReportPoint(periodIndex: $0.offset, valueMilliunits: $0.element) }),
            ReportSeries(key: "assets", label: "Assets", points: assets.enumerated().map { ReportPoint(periodIndex: $0.offset, valueMilliunits: $0.element) }),
            ReportSeries(key: "liabilities", label: "Liabilities", points: liabilities.enumerated().map { ReportPoint(periodIndex: $0.offset, valueMilliunits: $0.element) })
        ]
        if definition.breakdownByCategory { // reuse the flag as "by account"
            series = included.sorted { $0.name < $1.name }.map { account in
                ReportSeries(key: account.id.description, label: account.name, points: (perAccount[account.id] ?? []).enumerated().map { ReportPoint(periodIndex: $0.offset, valueMilliunits: $0.element) })
            }
        }
        let tableRows = included.sorted { $0.name < $1.name }.map { account in
            ReportTableRow(key: account.id.description, label: account.name, valueMilliunits: perAccount[account.id]?.last ?? 0,
                           count: rows.filter { $0.accountID == account.id }.count,
                           previousValueMilliunits: periods.count > 1 ? perAccount[account.id]?.first : nil, lineIDs: [])
        }
        return ReportResult(
            definition: definition, title: definition.kind.title, months: months, periods: periods, series: series, rows: tableRows,
            totalMilliunits: net.last ?? 0, previousTotalMilliunits: periods.count > 1 ? net.first : nil,
            excludedAccountNames: excluded,
            semanticsNote: "Net worth = month-end register balances of all \(snapshot.budget.currency) accounts, on- and off-budget, including staged rows. Credit cards and negative balances are liabilities."
        )
    }

    private static func budgetVsActual(
        _ definition: ReportDefinition,
        snapshot: BudgetWorkspaceSnapshot,
        projection: ProjectionResult?,
        months: ClosedRange<BudgetMonth>,
        periods: [ReportPeriod],
        categoriesByID: [CategoryID: CategoryRow],
        excluded: [String]
    ) -> ReportResult {
        var budgeted = [Milliunits](repeating: 0, count: periods.count)
        var activity = [Milliunits](repeating: 0, count: periods.count)
        struct CategoryTotals { var budgeted: Milliunits = 0; var activity: Milliunits = 0 }
        var perCategory: [CategoryID: CategoryTotals] = [:]
        let categoryFilter = definition.filters.categoryIDs
        let groupFilter = definition.filters.groupIDs
        for month in months.lowerBound.months(through: months.upperBound) {
            guard let index = periodIndex(for: month, in: periods), let snap = projection?.month(month) else { continue }
            for (categoryID, values) in snap.categories {
                guard let category = categoriesByID[categoryID], category.systemKind == nil else { continue }
                if let categoryFilter, !categoryFilter.contains(categoryID) { continue }
                if let groupFilter, !groupFilter.contains(category.groupID) { continue }
                budgeted[index] = sumChecked([budgeted[index], values.budgeted])
                activity[index] = sumChecked([activity[index], -values.activity])
                var totals = perCategory[categoryID] ?? CategoryTotals()
                totals.budgeted = sumChecked([totals.budgeted, values.budgeted])
                totals.activity = sumChecked([totals.activity, -values.activity])
                perCategory[categoryID] = totals
            }
        }
        let series = [
            ReportSeries(key: "budgeted", label: "Budgeted", points: budgeted.enumerated().map { ReportPoint(periodIndex: $0.offset, valueMilliunits: $0.element) }),
            ReportSeries(key: "actual", label: "Spent", points: activity.enumerated().map { ReportPoint(periodIndex: $0.offset, valueMilliunits: $0.element) })
        ]
        let rows = perCategory.map { id, totals in
            ReportTableRow(key: id.description, label: categoriesByID[id]?.name ?? "?", valueMilliunits: totals.activity, count: 0,
                           previousValueMilliunits: totals.budgeted, lineIDs: [])
        }
        .sorted { ($0.valueMilliunits, $1.label) > ($1.valueMilliunits, $0.label) }
        return ReportResult(
            definition: definition, title: definition.kind.title, months: months, periods: periods, series: series, rows: rows,
            totalMilliunits: sumChecked(activity), previousTotalMilliunits: sumChecked(budgeted), excludedAccountNames: excluded,
            semanticsNote: "Budgeted and spent per category from the same replay the budget grid shows; spent is net activity (refunds reduce it). Payment categories are excluded."
        )
    }
}

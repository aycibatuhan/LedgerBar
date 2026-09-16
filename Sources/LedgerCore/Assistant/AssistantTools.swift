import Foundation

/// The fixed tool registry (docs/LOCAL-AI.md A3). A tool is either here or
/// it does not exist for the model; there is no generic HTTP, file, shell,
/// or SQL tool. Every executor closes over one loaded budget's snapshot, so
/// cross-budget access is impossible by construction.
public struct AssistantToolExecutor: Sendable {
    public let snapshot: BudgetWorkspaceSnapshot
    public let projection: ProjectionResult?
    public let today: BudgetDate
    public let lineLimit: Int

    private let lines: [CategoryLine]
    private let accountsByID: [AccountID: AccountRow]
    private let categoriesByID: [CategoryID: CategoryRow]
    private let groupsByID: [CategoryGroupID: CategoryGroupRow]
    private let payeesByID: [PayeeID: PayeeRow]

    public init(snapshot: BudgetWorkspaceSnapshot, projection: ProjectionResult?, today: BudgetDate, lineLimit: Int = 200) {
        self.snapshot = snapshot
        self.projection = projection
        self.today = today
        self.lineLimit = lineLimit
        self.lines = snapshot.categoryLines()
        self.accountsByID = Dictionary(uniqueKeysWithValues: snapshot.accounts.map { ($0.id, $0) })
        self.categoriesByID = Dictionary(uniqueKeysWithValues: snapshot.categories.map { ($0.id, $0) })
        self.groupsByID = Dictionary(uniqueKeysWithValues: snapshot.categoryGroups.map { ($0.id, $0) })
        self.payeesByID = Dictionary(uniqueKeysWithValues: snapshot.payees.map { ($0.id, $0) })
    }

    private var currency: String { snapshot.budget.currency }

    // MARK: - Catalog

    public static let catalog: [AssistantToolDescriptor] = [
        AssistantToolDescriptor(name: "resolveDateRange", description: "Resolve a relative period ('last month', 'Q3', 'since March', 'last 90 days', '2025') into exact dates in the budget calendar. Always call this before a query with a period.", parameters: [
            ToolParameter("expression", .string, "The period as the user said it", required: true)
        ], permission: .read),
        AssistantToolDescriptor(name: "listCategories", description: "All budget categories with their groups and ids.", parameters: [], permission: .read),
        AssistantToolDescriptor(name: "listAccounts", description: "All accounts with type, on/off budget, and current balances.", parameters: [], permission: .read),
        AssistantToolDescriptor(name: "listPayees", description: "Search payees by name fragment.", parameters: [
            ToolParameter("query", .string, "Name fragment (case-insensitive)", required: true),
            ToolParameter("limit", .integer, "Max results (default 20)", minimum: 1, maximum: 100)
        ], permission: .read),
        AssistantToolDescriptor(name: "searchTransactions", description: "Find transactions by period, accounts, categories, payees, text, amount, or status. Returns bounded rows and a total.", parameters: [
            ToolParameter("start", .string, "Start date YYYY-MM-DD"),
            ToolParameter("end", .string, "End date YYYY-MM-DD"),
            ToolParameter("accountIDs", .stringArray, "Account ids"),
            ToolParameter("categoryIDs", .stringArray, "Category ids"),
            ToolParameter("payeeIDs", .stringArray, "Payee ids"),
            ToolParameter("text", .string, "Payee, memo, or imported description contains"),
            ToolParameter("minAmount", .number, "Minimum magnitude in currency units"),
            ToolParameter("maxAmount", .number, "Maximum magnitude in currency units"),
            ToolParameter("direction", .string, "outflow or inflow", enumValues: ["outflow", "inflow"]),
            ToolParameter("status", .string, "Row status filter", enumValues: ["needsCategory", "staged", "unapproved", "uncleared", "any"]),
            ToolParameter("sort", .string, "Sort order", enumValues: ["dateDesc", "amountDesc"]),
            ToolParameter("limit", .integer, "Max rows (default 50, max 200)", minimum: 1, maximum: 200)
        ], permission: .read),
        AssistantToolDescriptor(name: "spendingByCategory", description: "Net spending per category (outflows minus refunds) for a period.", parameters: [
            ToolParameter("start", .string, "Start date YYYY-MM-DD", required: true),
            ToolParameter("end", .string, "End date YYYY-MM-DD", required: true),
            ToolParameter("groupBy", .string, "category or group", enumValues: ["category", "group"]),
            ToolParameter("accountIDs", .stringArray, "Restrict to accounts"),
            ToolParameter("categoryIDs", .stringArray, "Restrict to categories"),
            ToolParameter("limit", .integer, "Top N", minimum: 1, maximum: 100)
        ], permission: .read),
        AssistantToolDescriptor(name: "spendingByPayee", description: "Net spending per payee (merchant) for a period.", parameters: [
            ToolParameter("start", .string, "Start date YYYY-MM-DD", required: true),
            ToolParameter("end", .string, "End date YYYY-MM-DD", required: true),
            ToolParameter("categoryIDs", .stringArray, "Restrict to categories"),
            ToolParameter("limit", .integer, "Top N", minimum: 1, maximum: 100)
        ], permission: .read),
        AssistantToolDescriptor(name: "spendingOverTime", description: "Net spending per month (or quarter/year) for a period, optionally for specific categories or payees.", parameters: [
            ToolParameter("start", .string, "Start date YYYY-MM-DD", required: true),
            ToolParameter("end", .string, "End date YYYY-MM-DD", required: true),
            ToolParameter("granularity", .string, "month, quarter, or year", enumValues: ["month", "quarter", "year"]),
            ToolParameter("categoryIDs", .stringArray, "Restrict to categories"),
            ToolParameter("payeeIDs", .stringArray, "Restrict to payees"),
            ToolParameter("accountIDs", .stringArray, "Restrict to accounts")
        ], permission: .read),
        AssistantToolDescriptor(name: "income", description: "Income (inflows to Ready to Assign) for a period, by month.", parameters: [
            ToolParameter("start", .string, "Start date YYYY-MM-DD", required: true),
            ToolParameter("end", .string, "End date YYYY-MM-DD", required: true)
        ], permission: .read),
        AssistantToolDescriptor(name: "comparePeriods", description: "Compare net spending between two periods, by category or payee, with the contributing transactions of the biggest changes.", parameters: [
            ToolParameter("startA", .string, "Period A start", required: true),
            ToolParameter("endA", .string, "Period A end", required: true),
            ToolParameter("startB", .string, "Period B start", required: true),
            ToolParameter("endB", .string, "Period B end", required: true),
            ToolParameter("dimension", .string, "category or payee", enumValues: ["category", "payee"]),
            ToolParameter("categoryIDs", .stringArray, "Restrict to categories")
        ], permission: .read),
        AssistantToolDescriptor(name: "budgetStatus", description: "Budgeted, activity, and available per category plus Ready to Assign for a month (default: current month).", parameters: [
            ToolParameter("month", .string, "YYYY-MM")
        ], permission: .read),
        AssistantToolDescriptor(name: "accountBalances", description: "Register and budget-projection balances for every account, with staged/needs-category counts.", parameters: [], permission: .read),
        AssistantToolDescriptor(name: "netWorthHistory", description: "Month-end net worth (all accounts in the budget currency) for a period.", parameters: [
            ToolParameter("start", .string, "Start date YYYY-MM-DD", required: true),
            ToolParameter("end", .string, "End date YYYY-MM-DD", required: true)
        ], permission: .read),
        AssistantToolDescriptor(name: "recurringMerchants", description: "Deterministic detection of recurring charges (same payee, similar amount, regular cadence) over a period, with cadence, typical amount, and drift.", parameters: [
            ToolParameter("start", .string, "Start date YYYY-MM-DD", required: true),
            ToolParameter("end", .string, "End date YYYY-MM-DD", required: true)
        ], permission: .read),
        AssistantToolDescriptor(name: "upcomingScheduled", description: "Expected scheduled events (bills, income, transfers) in a period, overdue items, and projected account balances at the end of the period.", parameters: [
            ToolParameter("start", .string, "Start date YYYY-MM-DD"),
            ToolParameter("end", .string, "End date YYYY-MM-DD")
        ], permission: .read),
        AssistantToolDescriptor(name: "uncategorized", description: "Transactions still needing a category, and staged rows awaiting resolution.", parameters: [
            ToolParameter("limit", .integer, "Max rows", minimum: 1, maximum: 200)
        ], permission: .read),
        AssistantToolDescriptor(name: "unusualTransactions", description: "Transactions in a period that are unusually large for their payee or category (fixed statistical rule), or first-seen payees above a threshold.", parameters: [
            ToolParameter("start", .string, "Start date YYYY-MM-DD", required: true),
            ToolParameter("end", .string, "End date YYYY-MM-DD", required: true)
        ], permission: .read),
        AssistantToolDescriptor(name: "evaluateReport", description: "Run a report definition (the same engine as the Reports view) and get its dataset; the UI can render it as a chart and save it.", parameters: [
            ToolParameter("kind", .string, "Report kind", required: true, enumValues: ReportKind.allCases.map(\.rawValue)),
            ToolParameter("start", .string, "Start month YYYY-MM", required: true),
            ToolParameter("end", .string, "End month YYYY-MM", required: true),
            ToolParameter("granularity", .string, "month, quarter, or year", enumValues: ["month", "quarter", "year"]),
            ToolParameter("categoryIDs", .stringArray, "Restrict to categories"),
            ToolParameter("accountIDs", .stringArray, "Restrict to accounts"),
            ToolParameter("payeeIDs", .stringArray, "Restrict to payees"),
            ToolParameter("breakdownByCategory", .boolean, "Split series by category"),
            ToolParameter("comparePreviousPeriod", .boolean, "Add the previous period"),
            ToolParameter("visualization", .string, "Chart type", enumValues: ReportVisualization.allCases.map(\.rawValue)),
            ToolParameter("title", .string, "Suggested report name")
        ], permission: .draft),
        AssistantToolDescriptor(name: "proposeCategorize", description: "Draft a categorization of transactions. The user must confirm before anything changes.", parameters: [
            ToolParameter("transactionIDs", .stringArray, "Transaction ids", required: true),
            ToolParameter("categoryID", .string, "Category id", required: true)
        ], permission: .draft),
        AssistantToolDescriptor(name: "proposeRenamePayee", description: "Draft renaming the payee of transactions (the bank's original description is kept).", parameters: [
            ToolParameter("transactionIDs", .stringArray, "Transaction ids", required: true),
            ToolParameter("name", .string, "New payee name", required: true)
        ], permission: .draft),
        AssistantToolDescriptor(name: "proposeRule", description: "Draft an automation rule: when the imported description contains text, rename and/or categorize.", parameters: [
            ToolParameter("name", .string, "Rule name", required: true),
            ToolParameter("descriptionContains", .string, "Imported description fragment", required: true),
            ToolParameter("categoryID", .string, "Category id to assign"),
            ToolParameter("renameTo", .string, "Payee name to set"),
            ToolParameter("accountID", .string, "Only on this account")
        ], permission: .draft),
        AssistantToolDescriptor(name: "proposeSplit", description: "Draft a split of one outflow across categories; amounts are magnitudes in currency units and must sum to the transaction.", parameters: [
            ToolParameter("transactionID", .string, "Transaction id", required: true),
            ToolParameter("categoryIDs", .stringArray, "Category ids in order", required: true),
            ToolParameter("amounts", .stringArray, "Magnitudes as decimal strings, same order", required: true)
        ], permission: .draft),
        AssistantToolDescriptor(name: "proposeSchedule", description: "Draft a recurring schedule (expected event).", parameters: [
            ToolParameter("name", .string, "Schedule name", required: true),
            ToolParameter("accountID", .string, "Account id", required: true),
            ToolParameter("payee", .string, "Payee", required: true),
            ToolParameter("amount", .string, "Signed amount in currency units (negative = outflow)", required: true),
            ToolParameter("frequency", .string, "once, daily, weekly, monthly, yearly", required: true, enumValues: ["once", "daily", "weekly", "monthly", "yearly"]),
            ToolParameter("startDate", .string, "First due date YYYY-MM-DD", required: true),
            ToolParameter("categoryID", .string, "Category id for outflows"),
            ToolParameter("dayOfMonth", .integer, "For monthly: 1–31 (31 = last day)", minimum: 1, maximum: 31),
            ToolParameter("weekday", .integer, "For weekly: 1=Sunday…7=Saturday", minimum: 1, maximum: 7),
            ToolParameter("interval", .integer, "Every N periods", minimum: 1, maximum: 52)
        ], permission: .draft),
        AssistantToolDescriptor(name: "proposeMoveMoney", description: "Draft moving budgeted money between categories or Ready to Assign in the current month.", parameters: [
            ToolParameter("fromCategoryID", .string, "Source category id, or 'rta'", required: true),
            ToolParameter("toCategoryID", .string, "Destination category id, or 'rta'", required: true),
            ToolParameter("amount", .string, "Positive amount in currency units", required: true)
        ], permission: .draft)
    ]

    public static func descriptor(named name: String) -> AssistantToolDescriptor? {
        catalog.first { $0.name == name }
    }

    // MARK: - Validation (A8)

    public static func validate(_ call: AssistantToolCall) -> AssistantToolError? {
        guard let descriptor = descriptor(named: call.name) else {
            return AssistantToolError(.unknownTool, "No tool named \(call.name). Available: \(catalog.map(\.name).joined(separator: ", "))")
        }
        guard let object = call.arguments.objectValue else {
            return AssistantToolError(.invalidArguments, "Arguments must be a JSON object")
        }
        for parameter in descriptor.parameters {
            guard let value = object[parameter.name], value != .null else {
                if parameter.required { return AssistantToolError(.invalidArguments, "Missing required parameter \(parameter.name)") }
                continue
            }
            switch parameter.kind {
            case .string:
                guard let s = value.stringValue else { return AssistantToolError(.invalidArguments, "\(parameter.name) must be a string") }
                if let allowed = parameter.enumValues, !allowed.contains(s) { return AssistantToolError(.invalidArguments, "\(parameter.name) must be one of \(allowed.joined(separator: ", "))") }
            case .integer:
                guard let n = value.intValue else { return AssistantToolError(.invalidArguments, "\(parameter.name) must be an integer") }
                if let minimum = parameter.minimum, Double(n) < minimum { return AssistantToolError(.invalidArguments, "\(parameter.name) must be ≥ \(Int(minimum))") }
                if let maximum = parameter.maximum, Double(n) > maximum { return AssistantToolError(.invalidArguments, "\(parameter.name) must be ≤ \(Int(maximum))") }
            case .number:
                guard value.doubleValue != nil else { return AssistantToolError(.invalidArguments, "\(parameter.name) must be a number") }
            case .boolean:
                guard value.boolValue != nil else { return AssistantToolError(.invalidArguments, "\(parameter.name) must be true or false") }
            case .stringArray:
                guard value.stringArray != nil, value.arrayValue?.count == value.stringArray?.count else { return AssistantToolError(.invalidArguments, "\(parameter.name) must be an array of strings") }
            }
        }
        let unknown = Set(object.keys).subtracting(descriptor.parameters.map(\.name))
        if !unknown.isEmpty { return AssistantToolError(.invalidArguments, "Unknown parameter(s): \(unknown.sorted().joined(separator: ", "))") }
        return nil
    }

    // MARK: - Execution

    public func execute(_ call: AssistantToolCall) -> AssistantToolResult {
        if let error = Self.validate(call) {
            return AssistantToolResult(callID: call.id, name: call.name, payload: .null, error: error)
        }
        do {
            return try run(call)
        } catch let error as AssistantToolError {
            return AssistantToolResult(callID: call.id, name: call.name, payload: .null, error: error)
        } catch {
            return AssistantToolResult(callID: call.id, name: call.name, payload: .null, error: AssistantToolError(.unsupported, "\(error)"))
        }
    }

    private func run(_ call: AssistantToolCall) throws -> AssistantToolResult {
        let args = call.arguments
        switch call.name {
        case "resolveDateRange":
            guard let resolved = DateExpressionResolver.resolve(args["expression"]?.stringValue ?? "", today: today, firstMonth: snapshot.budget.firstMonth) else {
                throw AssistantToolError(.invalidArguments, "Could not interpret that period; ask the user to clarify (e.g. 'last 3 months', 'March 2025').")
            }
            return result(call, .object([
                "start": .string(resolved.start.description), "end": .string(resolved.end.description),
                "startMonth": .string(resolved.months.lowerBound.description), "endMonth": .string(resolved.months.upperBound.description),
                "interpretation": .string(resolved.interpretation), "today": .string(today.description)
            ]))
        case "listCategories":
            let rows = snapshot.categories.filter { $0.kind != .inflow }.sorted { ($0.groupID.description, $0.sortOrder) < ($1.groupID.description, $1.sortOrder) }.map { category -> JSONValue in
                .object(["id": .string(category.id.description), "name": .string(category.name),
                         "group": .string(groupsByID[category.groupID]?.name ?? ""), "groupID": .string(category.groupID.description),
                         "kind": .string(category.kind.rawValue), "hidden": .bool(category.hidden),
                         "system": .bool(category.systemKind != nil)])
            }
            return result(call, .object(["categories": .array(rows), "readyToAssignID": .string(snapshot.rtaCategoryID.description), "uncategorizedID": .string(snapshot.uncategorizedID.description)]))
        case "listAccounts", "accountBalances":
            let rows = snapshot.accounts.sorted { $0.name < $1.name }.map { account -> JSONValue in
                let register = projection?.registerBalances[account.id] ?? 0
                let projected = projection?.projectionBalances[account.id]
                let pending = snapshot.transactions.filter { $0.accountID == account.id && ($0.postingState == .needsCategory || $0.postingState == .staged) }.count
                var object: [String: JSONValue] = [
                    "id": .string(account.id.description), "name": .string(account.name), "type": .string(account.type.rawValue),
                    "onBudget": .bool(account.onBudget), "closed": .bool(account.closed), "currency": .string(account.currency),
                    "registerBalance": AssistantFormat.money(register, currency: account.currency),
                    "needsAttentionCount": .number(Double(pending))
                ]
                if let projected { object["projectionBalance"] = AssistantFormat.money(projected, currency: account.currency) }
                return .object(object)
            }
            return result(call, .object(["accounts": .array(rows)]))
        case "listPayees":
            let query = BudgetWorkspace.normalizePayeeName(args["query"]?.stringValue ?? "")
            let limit = args["limit"]?.intValue ?? 20
            let rows = snapshot.payees.filter { $0.systemKind == nil && !$0.hidden && $0.name.contains(query) }
                .sorted { $0.displayName < $1.displayName }.prefix(limit).map { payee -> JSONValue in
                    let count = lines.filter { $0.payeeID == payee.id }.count
                    return .object(["id": .string(payee.id.description), "name": .string(payee.displayName), "transactionCount": .number(Double(count)),
                                    "usualCategory": .string(payee.lastUsedCategoryID.flatMap { categoriesByID[$0]?.name } ?? "")])
                }
            return result(call, .object(["payees": .array(Array(rows))]))
        case "searchTransactions":
            return try searchTransactions(call)
        case "spendingByCategory":
            let (start, end) = try period(args)
            let groupBy = args["groupBy"]?.stringValue ?? "category"
            let accounts = idSet(args["accountIDs"], AccountID.self)
            let categoryFilter = idSet(args["categoryIDs"], CategoryID.self)
            var totals: [String: (label: String, total: Milliunits, count: Int, ids: [String])] = [:]
            for line in spendingLines(start...end) where accounts?.contains(line.accountID) ?? true {
                guard let categoryID = line.categoryID else { continue }
                if let categoryFilter, !categoryFilter.contains(categoryID) { continue }
                let key: String
                let label: String
                if groupBy == "group", let group = categoriesByID[categoryID]?.groupID {
                    key = group.description; label = groupsByID[group]?.name ?? "?"
                } else {
                    key = categoryID.description; label = categoriesByID[categoryID]?.name ?? "?"
                }
                var entry = totals[key] ?? (label, 0, 0, [])
                entry.total = checkedSum(entry.total, -line.amountMilliunits)
                entry.count += 1
                if entry.ids.count < lineLimit { entry.ids.append(line.id) }
                totals[key] = entry
            }
            let sorted = totals.sorted { ($0.value.total, $1.key) > ($1.value.total, $0.key) }
            let limit = args["limit"]?.intValue ?? 50
            let rows = sorted.prefix(limit).map { key, entry -> JSONValue in
                .object(["id": .string(key), "name": .string(entry.label), "netSpending": AssistantFormat.money(entry.total, currency: currency), "transactionCount": .number(Double(entry.count))])
            }
            let total = sorted.reduce(Milliunits(0)) { checkedSum($0, $1.value.total) }
            return AssistantToolResult(callID: call.id, name: call.name, payload: .object([
                "start": .string(start.description), "end": .string(end.description), "groupBy": .string(groupBy),
                "rows": .array(Array(rows)), "total": AssistantFormat.money(total, currency: currency),
                "semantics": .string("Net spending = category outflows minus refunds; transfers and card payments excluded; staged and voided excluded.")
            ]), provenanceLineIDs: Array(sorted.flatMap { $0.value.ids }.prefix(lineLimit)), truncated: sorted.count > limit)
        case "spendingByPayee":
            let (start, end) = try period(args)
            let categories = idSet(args["categoryIDs"], CategoryID.self)
            var totals: [String: (label: String, total: Milliunits, count: Int, ids: [String])] = [:]
            for line in spendingLines(start...end) where categories.map { set in line.categoryID.map(set.contains) ?? false } ?? true {
                let key = line.payeeID?.description ?? "none"
                let label = line.payeeID.flatMap { payeesByID[$0]?.displayName } ?? "No payee"
                var entry = totals[key] ?? (label, 0, 0, [])
                entry.total = checkedSum(entry.total, -line.amountMilliunits)
                entry.count += 1
                if entry.ids.count < lineLimit { entry.ids.append(line.id) }
                totals[key] = entry
            }
            let sorted = totals.sorted { ($0.value.total, $1.key) > ($1.value.total, $0.key) }
            let limit = args["limit"]?.intValue ?? 25
            let rows = sorted.prefix(limit).map { key, entry -> JSONValue in
                .object(["id": .string(key), "payee": .string(entry.label), "netSpending": AssistantFormat.money(entry.total, currency: currency), "transactionCount": .number(Double(entry.count))])
            }
            let total = sorted.reduce(Milliunits(0)) { checkedSum($0, $1.value.total) }
            return AssistantToolResult(callID: call.id, name: call.name, payload: .object([
                "start": .string(start.description), "end": .string(end.description), "rows": .array(Array(rows)), "total": AssistantFormat.money(total, currency: currency)
            ]), provenanceLineIDs: Array(sorted.flatMap { $0.value.ids }.prefix(lineLimit)), truncated: sorted.count > limit)
        case "spendingOverTime":
            let (start, end) = try period(args)
            let granularity = ReportGranularity(rawValue: args["granularity"]?.stringValue ?? "month") ?? .month
            let categories = idSet(args["categoryIDs"], CategoryID.self)
            let payees = idSet(args["payeeIDs"], PayeeID.self)
            let accounts = idSet(args["accountIDs"], AccountID.self)
            let periods = ReportEngine.makePeriods(start.budgetMonth...end.budgetMonth, granularity: granularity)
            var values = [Milliunits](repeating: 0, count: periods.count)
            var counts = [Int](repeating: 0, count: periods.count)
            var ids: [String] = []
            for line in spendingLines(start...end) {
                if let categories, !(line.categoryID.map(categories.contains) ?? false) { continue }
                if let payees, !(line.payeeID.map(payees.contains) ?? false) { continue }
                if let accounts, !accounts.contains(line.accountID) { continue }
                guard let index = ReportEngine.periodIndex(for: line.month, in: periods) else { continue }
                values[index] = checkedSum(values[index], -line.amountMilliunits)
                counts[index] += 1
                if ids.count < lineLimit { ids.append(line.id) }
            }
            let rows = periods.enumerated().map { index, period -> JSONValue in
                .object(["period": .string(period.label), "start": .string(period.start.description), "end": .string(period.end.description),
                         "netSpending": AssistantFormat.money(values[index], currency: currency), "transactionCount": .number(Double(counts[index]))])
            }
            let total = values.reduce(Milliunits(0), checkedSum)
            let average = periods.isEmpty ? 0 : total / Milliunits(periods.count)
            return AssistantToolResult(callID: call.id, name: call.name, payload: .object([
                "granularity": .string(granularity.rawValue), "rows": .array(rows), "total": AssistantFormat.money(total, currency: currency),
                "averagePerPeriod": AssistantFormat.money(average, currency: currency)
            ]), provenanceLineIDs: ids)
        case "income":
            let (start, end) = try period(args)
            let periods = ReportEngine.makePeriods(start.budgetMonth...end.budgetMonth, granularity: .month)
            var values = [Milliunits](repeating: 0, count: periods.count)
            var ids: [String] = []
            for line in lines where line.role == .income && (start...end).contains(line.date) {
                guard let index = ReportEngine.periodIndex(for: line.month, in: periods) else { continue }
                values[index] = checkedSum(values[index], line.amountMilliunits)
                if ids.count < lineLimit { ids.append(line.id) }
            }
            let rows = periods.enumerated().map { index, period -> JSONValue in
                .object(["period": .string(period.label), "income": AssistantFormat.money(values[index], currency: currency)])
            }
            return AssistantToolResult(callID: call.id, name: call.name, payload: .object([
                "rows": .array(rows), "total": AssistantFormat.money(values.reduce(0, checkedSum), currency: currency),
                "semantics": .string("Income = inflows to Ready to Assign, including off-budget → on-budget transfers; openings and adjustments excluded.")
            ]), provenanceLineIDs: ids)
        case "comparePeriods":
            return try comparePeriods(call)
        case "budgetStatus":
            let month = args["month"]?.stringValue.flatMap(BudgetMonth.init(string:)) ?? snapshot.budget.lastObservedBudgetMonth
            guard let monthSnapshot = projection?.month(month) else {
                throw AssistantToolError(.notFound, "No budget data for \(month.description)")
            }
            let categories = monthSnapshot.categories.compactMap { id, values -> JSONValue? in
                guard let category = categoriesByID[id], category.systemKind == nil || id == snapshot.uncategorizedID else { return nil }
                return .object(["id": .string(id.description), "name": .string(category.name), "group": .string(groupsByID[category.groupID]?.name ?? ""),
                                "budgeted": AssistantFormat.money(values.budgeted, currency: currency), "activity": AssistantFormat.money(values.activity, currency: currency),
                                "available": AssistantFormat.money(values.available, currency: currency), "creditOverspending": AssistantFormat.money(values.creditDebt, currency: currency)])
            }.sorted { ($0["name"]?.stringValue ?? "") < ($1["name"]?.stringValue ?? "") }
            let payments = monthSnapshot.payments.compactMap { id, values -> JSONValue? in
                guard let category = categoriesByID[id] else { return nil }
                return .object(["id": .string(id.description), "name": .string(category.name), "budgeted": AssistantFormat.money(values.budgeted, currency: currency),
                                "activity": AssistantFormat.money(values.activity, currency: currency), "available": AssistantFormat.money(values.available, currency: currency)])
            }
            return result(call, .object([
                "month": .string(month.description), "readyToAssign": AssistantFormat.money(monthSnapshot.rtaEnd, currency: currency),
                "totalAssigned": AssistantFormat.money(monthSnapshot.totalAssigned, currency: currency),
                "cashOverspending": AssistantFormat.money(monthSnapshot.cashOverspendingAtEnd, currency: currency),
                "categories": .array(categories), "creditCardPayments": .array(payments)
            ]))
        case "netWorthHistory":
            let (start, end) = try period(args)
            let evaluated = ReportEngine.evaluate(ReportDefinition(kind: .netWorth, range: .absolute(from: start.budgetMonth, to: end.budgetMonth)), snapshot: snapshot, projection: projection)
            let net = evaluated.series.first { $0.key == "net" }?.points ?? []
            let rows = evaluated.periods.enumerated().map { index, period -> JSONValue in
                .object(["period": .string(period.label), "netWorth": AssistantFormat.money(net.first { $0.periodIndex == index }?.valueMilliunits ?? 0, currency: currency)])
            }
            return AssistantToolResult(callID: call.id, name: call.name, payload: .object(["rows": .array(rows), "semantics": .string(evaluated.semanticsNote)]), reportDefinition: evaluated.definition)
        case "recurringMerchants":
            return try recurringMerchants(call)
        case "upcomingScheduled":
            return try upcomingScheduled(call)
        case "uncategorized":
            let limit = args["limit"]?.intValue ?? 50
            let rows = snapshot.transactions.filter { $0.postingState == .needsCategory || $0.postingState == .staged }
                .sorted { ($0.date, $0.id) > ($1.date, $1.id) }
            return AssistantToolResult(callID: call.id, name: call.name, payload: .object([
                "count": .number(Double(rows.count)),
                "rows": .array(rows.prefix(limit).map(transactionJSON))
            ]), provenanceLineIDs: rows.prefix(limit).map { "\($0.id.description)#0" }, truncated: rows.count > limit)
        case "unusualTransactions":
            return try unusualTransactions(call)
        case "evaluateReport":
            return try evaluateReport(call)
        case "proposeCategorize":
            let ids = try transactionIDs(args["transactionIDs"])
            let categoryID = try id(args["categoryID"], CategoryID.self)
            guard categoriesByID[categoryID] != nil else { throw AssistantToolError(.notFound, "Unknown category id") }
            return proposal(call, .categorize(transactionIDs: ids, categoryID: categoryID))
        case "proposeRenamePayee":
            let ids = try transactionIDs(args["transactionIDs"])
            return proposal(call, .renamePayee(transactionIDs: ids, name: args["name"]?.stringValue ?? ""))
        case "proposeRule":
            var conditions: [RuleCondition] = [.importedDescription(.contains, args["descriptionContains"]?.stringValue ?? "")]
            if let account = args["accountID"]?.stringValue { conditions.append(.account(try id(.string(account), AccountID.self))) }
            var actions: [RuleAction] = []
            if let rename = args["renameTo"]?.stringValue, !rename.isEmpty { actions.append(.setPayee(rename)) }
            if let category = args["categoryID"]?.stringValue { actions.append(.setCategory(try id(.string(category), CategoryID.self))) }
            guard !actions.isEmpty else { throw AssistantToolError(.invalidArguments, "A rule needs a categoryID or renameTo") }
            return proposal(call, .createRule(name: args["name"]?.stringValue ?? "", conditions: conditions, actions: actions))
        case "proposeSplit":
            let transactionID = try id(args["transactionID"], TransactionID.self)
            let categories = try (args["categoryIDs"]?.stringArray ?? []).map { try id(.string($0), CategoryID.self) }
            let amounts = try (args["amounts"]?.stringArray ?? []).map { try MoneyParser.milliunits(fromDecimalString: $0) }
            guard categories.count == amounts.count, categories.count >= 2 else { throw AssistantToolError(.invalidArguments, "categoryIDs and amounts must have the same length (≥ 2)") }
            let components = zip(categories, amounts).map { SplitComponent(categoryID: $0, amountMilliunits: -abs($1)) }
            return proposal(call, .split(transactionID: transactionID, components: components))
        case "proposeSchedule":
            let accountID = try id(args["accountID"], AccountID.self)
            let amount = try MoneyParser.milliunits(fromDecimalString: args["amount"]?.stringValue ?? "")
            guard let startDate = BudgetDate(string: args["startDate"]?.stringValue ?? "") else { throw AssistantToolError(.invalidArguments, "startDate must be YYYY-MM-DD") }
            let interval = args["interval"]?.intValue ?? 1
            let recurrence: RecurrenceRule
            switch args["frequency"]?.stringValue ?? "monthly" {
            case "once": recurrence = .once
            case "daily": recurrence = .daily(every: interval)
            case "weekly": recurrence = .weekly(every: interval, weekday: args["weekday"]?.intValue ?? RecurrenceEngine.weekday(of: startDate))
            case "yearly": recurrence = .yearly(month: startDate.month, day: startDate.day)
            default:
                let day = args["dayOfMonth"]?.intValue ?? startDate.day
                recurrence = .monthly(every: interval, day: day >= 31 ? .lastDay : .day(day))
            }
            let categoryID = try args["categoryID"]?.stringValue.map { try id(.string($0), CategoryID.self) }
            let schedule = Schedule(budgetID: snapshot.budget.id, name: args["name"]?.stringValue ?? "", accountID: accountID,
                                    payeeName: args["payee"]?.stringValue ?? "", categoryID: categoryID, amountMilliunits: amount,
                                    recurrence: recurrence, startDate: startDate)
            return proposal(call, .createSchedule(schedule))
        case "proposeMoveMoney":
            func endpoint(_ value: JSONValue?) throws -> MoveMoneyEndpointCodable {
                let text = value?.stringValue ?? ""
                if text.lowercased() == "rta" || text.lowercased() == "ready to assign" { return .rta }
                return .category(try id(.string(text), CategoryID.self))
            }
            let amount = try MoneyParser.milliunits(fromDecimalString: args["amount"]?.stringValue ?? "")
            return proposal(call, .moveMoney(source: try endpoint(args["fromCategoryID"]), destination: try endpoint(args["toCategoryID"]), amountMilliunits: amount, month: snapshot.budget.lastObservedBudgetMonth))
        default:
            throw AssistantToolError(.unknownTool, "No tool named \(call.name)")
        }
    }

    // MARK: - Helpers

    private func result(_ call: AssistantToolCall, _ payload: JSONValue) -> AssistantToolResult {
        AssistantToolResult(callID: call.id, name: call.name, payload: payload)
    }

    private func proposal(_ call: AssistantToolCall, _ action: ProposedAction) -> AssistantToolResult {
        let preview = (try? BudgetWorkspace(snapshot: snapshot))?.previewProposal(action)
        var payload: [String: JSONValue] = ["proposal": .string(action.title), "requiresUserConfirmation": .bool(true)]
        if let preview {
            payload["preview"] = .array(preview.lines.map(JSONValue.string))
            if let error = preview.error { payload["validationError"] = .string(error) }
        }
        return AssistantToolResult(callID: call.id, name: call.name, payload: .object(payload), proposal: action)
    }

    private func checkedSum(_ a: Milliunits, _ b: Milliunits) -> Milliunits {
        let (sum, overflow) = a.addingReportingOverflow(b)
        return overflow ? a : sum
    }

    private func period(_ args: JSONValue) throws -> (BudgetDate, BudgetDate) {
        guard let start = BudgetDate(string: args["start"]?.stringValue ?? ""), let end = BudgetDate(string: args["end"]?.stringValue ?? "") else {
            throw AssistantToolError(.invalidArguments, "start and end must be YYYY-MM-DD (use resolveDateRange first)")
        }
        return (min(start, end), max(start, end))
    }

    private func id<Tag>(_ value: JSONValue?, _ type: EntityID<Tag>.Type) throws -> EntityID<Tag> {
        guard let text = value?.stringValue, let uuid = UUID(uuidString: text) else {
            throw AssistantToolError(.invalidArguments, "Expected an id from a list tool")
        }
        return EntityID<Tag>(uuid)
    }

    private func idSet<Tag>(_ value: JSONValue?, _ type: EntityID<Tag>.Type) -> Set<EntityID<Tag>>? {
        guard let strings = value?.stringArray, !strings.isEmpty else { return nil }
        return Set(strings.compactMap { UUID(uuidString: $0).map(EntityID<Tag>.init) })
    }

    private func transactionIDs(_ value: JSONValue?) throws -> [TransactionID] {
        let ids = (value?.stringArray ?? []).compactMap { UUID(uuidString: $0).map(TransactionID.init) }
        guard !ids.isEmpty else { throw AssistantToolError(.invalidArguments, "transactionIDs must contain ids from searchTransactions") }
        for id in ids where !snapshot.transactions.contains(where: { $0.id == id }) {
            throw AssistantToolError(.notFound, "Unknown transaction id \(id.description)")
        }
        return ids
    }

    private func spendingLines(_ range: ClosedRange<BudgetDate>) -> [CategoryLine] {
        lines.filter { range.contains($0.date) && ($0.role == .spending || $0.role == .refund) }
    }

    private func transactionJSON(_ row: TransactionRow) -> JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(row.id.description), "date": .string(row.date.description),
            "account": .string(accountsByID[row.accountID]?.name ?? ""), "accountID": .string(row.accountID.description),
            "payee": .string(row.payeeID.flatMap { payeesByID[$0]?.displayName } ?? ""),
            "amount": AssistantFormat.money(row.amountMilliunits, currency: currency),
            "status": .string(row.postingState.rawValue), "source": .string(row.sourceKind.rawValue), "approved": .bool(row.approved)
        ]
        if let category = row.categoryID { object["category"] = .string(categoriesByID[category]?.name ?? ""); object["categoryID"] = .string(category.description) }
        if let splits = row.splits { object["splits"] = .array(splits.map { .object(["category": .string(categoriesByID[$0.categoryID]?.name ?? ""), "amount": AssistantFormat.money($0.amountMilliunits, currency: currency)]) }) }
        if let memo = row.memo { object["memo"] = .string(memo) }
        if let imported = row.importedDescription { object["importedDescription"] = .string(imported) }
        if row.transferPairID != nil { object["transfer"] = .bool(true) }
        if let occurrence = snapshot.scheduleOccurrences.first(where: { $0.transactionID == row.id }),
           let schedule = snapshot.schedules.first(where: { $0.id == occurrence.scheduleID }) {
            object["schedule"] = .string(schedule.name)
        }
        return .object(object)
    }

    private func searchTransactions(_ call: AssistantToolCall) throws -> AssistantToolResult {
        let args = call.arguments
        let start = args["start"]?.stringValue.flatMap(BudgetDate.init(string:))
        let end = args["end"]?.stringValue.flatMap(BudgetDate.init(string:))
        let accounts = idSet(args["accountIDs"], AccountID.self)
        let categories = idSet(args["categoryIDs"], CategoryID.self)
        let payees = idSet(args["payeeIDs"], PayeeID.self)
        let text = args["text"]?.stringValue.map(BudgetWorkspace.normalizePayeeName)
        let minimum = try args["minAmount"]?.stringValue.map { try MoneyParser.milliunits(fromDecimalString: $0) } ?? args["minAmount"]?.doubleValue.map { Milliunits(($0 * 1000).rounded()) }
        let maximum = try args["maxAmount"]?.stringValue.map { try MoneyParser.milliunits(fromDecimalString: $0) } ?? args["maxAmount"]?.doubleValue.map { Milliunits(($0 * 1000).rounded()) }
        let direction = args["direction"]?.stringValue
        let status = args["status"]?.stringValue ?? "any"
        let limit = min(args["limit"]?.intValue ?? 50, lineLimit)
        var rows = snapshot.transactions.filter { row in
            guard row.postingState != .voided else { return false }
            if let start, row.date < start { return false }
            if let end, row.date > end { return false }
            if let accounts, !accounts.contains(row.accountID) { return false }
            if let categories {
                let rowCategories = Set((row.splits?.map(\.categoryID) ?? []) + (row.categoryID.map { [$0] } ?? []))
                if rowCategories.isDisjoint(with: categories) { return false }
            }
            if let payees, !(row.payeeID.map(payees.contains) ?? false) { return false }
            if let text, !text.isEmpty {
                let haystack = BudgetWorkspace.normalizePayeeName([row.payeeID.flatMap { payeesByID[$0]?.displayName } ?? "", row.memo ?? "", row.importedDescription ?? ""].joined(separator: " "))
                if !haystack.contains(text) { return false }
            }
            let magnitude = Milliunits(row.amountMilliunits.magnitude)
            if let minimum, magnitude < minimum { return false }
            if let maximum, magnitude > maximum { return false }
            if direction == "outflow", row.amountMilliunits >= 0 { return false }
            if direction == "inflow", row.amountMilliunits <= 0 { return false }
            switch status {
            case "needsCategory": if row.postingState != .needsCategory { return false }
            case "staged": if row.postingState != .staged { return false }
            case "unapproved": if row.approved { return false }
            case "uncleared": if row.cleared != .uncleared { return false }
            default: break
            }
            return true
        }
        if args["sort"]?.stringValue == "amountDesc" {
            rows.sort { ($0.amountMilliunits.magnitude, $1.date) > ($1.amountMilliunits.magnitude, $0.date) }
        } else {
            rows.sort { ($0.date, $0.id) > ($1.date, $1.id) }
        }
        let total = rows.reduce(Milliunits(0)) { checkedSum($0, $1.amountMilliunits) }
        return AssistantToolResult(callID: call.id, name: call.name, payload: .object([
            "matchCount": .number(Double(rows.count)), "total": AssistantFormat.money(total, currency: currency),
            "rows": .array(rows.prefix(limit).map(transactionJSON))
        ]), provenanceLineIDs: rows.prefix(limit).map { "\($0.id.description)#0" }, truncated: rows.count > limit)
    }

    private func comparePeriods(_ call: AssistantToolCall) throws -> AssistantToolResult {
        let args = call.arguments
        guard let startA = BudgetDate(string: args["startA"]?.stringValue ?? ""), let endA = BudgetDate(string: args["endA"]?.stringValue ?? ""),
              let startB = BudgetDate(string: args["startB"]?.stringValue ?? ""), let endB = BudgetDate(string: args["endB"]?.stringValue ?? "") else {
            throw AssistantToolError(.invalidArguments, "Dates must be YYYY-MM-DD")
        }
        let dimension = args["dimension"]?.stringValue ?? "category"
        let categories = idSet(args["categoryIDs"], CategoryID.self)
        func totals(_ range: ClosedRange<BudgetDate>) -> [String: (label: String, total: Milliunits, ids: [String])] {
            var result: [String: (String, Milliunits, [String])] = [:]
            for line in spendingLines(range) {
                if let categories, !(line.categoryID.map(categories.contains) ?? false) { continue }
                let key: String
                let label: String
                if dimension == "payee" {
                    key = line.payeeID?.description ?? "none"; label = line.payeeID.flatMap { payeesByID[$0]?.displayName } ?? "No payee"
                } else {
                    guard let category = line.categoryID else { continue }
                    key = category.description; label = categoriesByID[category]?.name ?? "?"
                }
                var entry = result[key] ?? (label, 0, [])
                entry.1 = checkedSum(entry.1, -line.amountMilliunits)
                if entry.2.count < 25 { entry.2.append(line.id) }
                result[key] = entry
            }
            return result
        }
        let a = totals(min(startA, endA)...max(startA, endA))
        let b = totals(min(startB, endB)...max(startB, endB))
        let keys = Set(a.keys).union(b.keys)
        var rows = keys.map { key -> (key: String, label: String, a: Milliunits, b: Milliunits, ids: [String]) in
            (key, a[key]?.label ?? b[key]?.label ?? "?", a[key]?.total ?? 0, b[key]?.total ?? 0, (a[key]?.ids ?? []) + (b[key]?.ids ?? []))
        }
        rows.sort { abs($0.b - $0.a) > abs($1.b - $1.a) }
        let totalA = a.values.reduce(Milliunits(0)) { checkedSum($0, $1.total) }
        let totalB = b.values.reduce(Milliunits(0)) { checkedSum($0, $1.total) }
        return AssistantToolResult(callID: call.id, name: call.name, payload: .object([
            "periodA": .object(["start": .string(startA.description), "end": .string(endA.description), "total": AssistantFormat.money(totalA, currency: currency)]),
            "periodB": .object(["start": .string(startB.description), "end": .string(endB.description), "total": AssistantFormat.money(totalB, currency: currency)]),
            "change": AssistantFormat.money(checkedSum(totalB, -totalA), currency: currency),
            "rows": .array(rows.prefix(30).map { .object([
                "id": .string($0.key), "name": .string($0.label), "periodA": AssistantFormat.money($0.a, currency: currency),
                "periodB": AssistantFormat.money($0.b, currency: currency), "change": AssistantFormat.money(checkedSum($0.b, -$0.a), currency: currency)
            ]) })
        ]), provenanceLineIDs: Array(rows.prefix(10).flatMap(\.ids).prefix(lineLimit)), truncated: rows.count > 30)
    }

    /// Deterministic recurrence detection: per payee, outflows with ≥ 3
    /// occurrences whose gaps cluster around 7, 14, 30/31, 90, or 365 days
    /// and whose amounts stay within 25 % of the median.
    private func recurringMerchants(_ call: AssistantToolCall) throws -> AssistantToolResult {
        let (start, end) = try period(call.arguments)
        var byPayee: [PayeeID: [CategoryLine]] = [:]
        for line in spendingLines(start...end) where line.role == .spending && line.amountMilliunits < 0 {
            guard let payee = line.payeeID else { continue }
            byPayee[payee, default: []].append(line)
        }
        var rows: [(name: String, cadence: String, typical: Milliunits, latest: Milliunits, count: Int, first: BudgetDate, last: BudgetDate, drift: Milliunits, ids: [String])] = []
        for (payee, lines) in byPayee where lines.count >= 3 {
            let sorted = lines.sorted { $0.date < $1.date }
            var gaps: [Int] = []
            for index in 1..<sorted.count {
                gaps.append(RecurrenceEngine.dayNumber(sorted[index].date) - RecurrenceEngine.dayNumber(sorted[index - 1].date))
            }
            let medianGap = gaps.sorted()[gaps.count / 2]
            let cadence: String
            switch medianGap {
            case 5...9: cadence = "weekly"
            case 12...16: cadence = "every two weeks"
            case 26...35: cadence = "monthly"
            case 80...100: cadence = "quarterly"
            case 350...380: cadence = "yearly"
            default: continue
            }
            let regular = gaps.filter { abs($0 - medianGap) <= max(3, medianGap / 5) }.count
            guard regular * 100 >= gaps.count * 60 else { continue }
            let magnitudes = sorted.map { -$0.amountMilliunits }.sorted()
            let median = magnitudes[magnitudes.count / 2]
            guard magnitudes.allSatisfy({ abs($0 - median) * 4 <= median }) else { continue }
            let latest = -sorted.last!.amountMilliunits
            rows.append((payeesByID[payee]?.displayName ?? "?", cadence, median, latest, sorted.count, sorted.first!.date, sorted.last!.date, latest - (-sorted.first!.amountMilliunits), sorted.map(\.id)))
        }
        rows.sort { ($0.typical, $1.name) > ($1.typical, $0.name) }
        return AssistantToolResult(callID: call.id, name: call.name, payload: .object([
            "rows": .array(rows.map { .object([
                "payee": .string($0.name), "cadence": .string($0.cadence), "typicalAmount": AssistantFormat.money($0.typical, currency: currency),
                "latestAmount": AssistantFormat.money($0.latest, currency: currency), "changeSinceFirst": AssistantFormat.money($0.drift, currency: currency),
                "occurrences": .number(Double($0.count)), "firstSeen": .string($0.first.description), "lastSeen": .string($0.last.description)
            ]) }),
            "semantics": .string("Detected from history by cadence and amount stability; not a list of configured schedules (see upcomingScheduled).")
        ]), provenanceLineIDs: Array(rows.flatMap(\.ids).prefix(lineLimit)))
    }

    private func upcomingScheduled(_ call: AssistantToolCall) throws -> AssistantToolResult {
        let args = call.arguments
        let start = args["start"]?.stringValue.flatMap(BudgetDate.init(string:)) ?? today
        let end = args["end"]?.stringValue.flatMap(BudgetDate.init(string:)) ?? RecurrenceEngine.adding(days: 30, to: today)
        guard let workspace = try? BudgetWorkspace(snapshot: snapshot) else { throw AssistantToolError(.unsupported, "Budget unavailable") }
        let occurrences = workspace.expectedOccurrences(in: min(start, RecurrenceEngine.adding(days: -400, to: today))...max(end, today), asOf: today)
        let upcoming = occurrences.filter { !$0.isOverdue && $0.dueDate >= start && $0.dueDate <= end }
        let overdue = occurrences.filter(\.isOverdue)
        func json(_ o: ExpectedOccurrence) -> JSONValue {
            let schedule = workspace.schedules[o.scheduleID]
            return .object(["schedule": .string(schedule?.name ?? ""), "payee": .string(schedule?.payeeName ?? ""), "dueDate": .string(o.dueDate.description),
                            "account": .string(accountsByID[o.accountID]?.name ?? ""), "amount": AssistantFormat.money(o.amountMilliunits, currency: currency)])
        }
        let balances = snapshot.accounts.filter { !$0.closed }.sorted { $0.name < $1.name }.map { account -> JSONValue in
            let register = projection?.registerBalances[account.id] ?? 0
            let projected = (try? workspace.projectedRegisterBalance(accountID: account.id, through: end, asOf: today, registerBalance: register)) ?? register
            return .object(["account": .string(account.name), "registerNow": AssistantFormat.money(register, currency: account.currency), "projectedAt": .string(end.description), "projected": AssistantFormat.money(projected, currency: account.currency)])
        }
        return result(call, .object([
            "upcoming": .array(upcoming.map(json)), "overdue": .array(overdue.map(json)),
            "expectedNet": AssistantFormat.money(upcoming.reduce(Milliunits(0)) { checkedSum($0, $1.amountMilliunits) }, currency: currency),
            "projectedBalances": .array(balances),
            "semantics": .string("Expected events are not transactions. Projected balances = register balance + unmatched expected amounts; they are estimates, not ledger values.")
        ]))
    }

    /// Fixed rule: an outflow is unusual when its magnitude exceeds the
    /// payee's (or, for a payee with < 3 history rows, the category's)
    /// mean by two standard deviations with at least three prior rows, or
    /// when the payee is first seen and the magnitude is in the top 5 % of
    /// all outflows in the budget.
    private func unusualTransactions(_ call: AssistantToolCall) throws -> AssistantToolResult {
        let (start, end) = try period(call.arguments)
        let outflows = lines.filter { $0.role == .spending && $0.amountMilliunits < 0 }
        let byPayee = Dictionary(grouping: outflows, by: { $0.payeeID })
        let byCategory = Dictionary(grouping: outflows, by: { $0.categoryID })
        let allMagnitudes = outflows.map { Double(-$0.amountMilliunits) }.sorted()
        let top5 = allMagnitudes.isEmpty ? Double.infinity : allMagnitudes[Int(Double(allMagnitudes.count - 1) * 0.95)]
        func stats(_ rows: [CategoryLine], excluding id: String) -> (mean: Double, sd: Double, count: Int)? {
            let values = rows.filter { $0.id != id && $0.date < start }.map { Double(-$0.amountMilliunits) }
            guard values.count >= 3 else { return nil }
            let mean = values.reduce(0, +) / Double(values.count)
            let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
            return (mean, variance.squareRoot(), values.count)
        }
        var rows: [(line: CategoryLine, reason: String)] = []
        for line in outflows where (start...end).contains(line.date) {
            let magnitude = Double(-line.amountMilliunits)
            if let payee = line.payeeID, let s = stats(byPayee[payee] ?? [], excluding: line.id) {
                if magnitude > s.mean + 2 * s.sd && magnitude > s.mean * 1.5 {
                    rows.append((line, "\(AssistantFormat.decimal(Milliunits(magnitude))) vs a typical \(AssistantFormat.decimal(Milliunits(s.mean))) at this payee (\(s.count) prior)"))
                    continue
                }
            } else if let category = line.categoryID, let s = stats(byCategory[category] ?? [], excluding: line.id) {
                if magnitude > s.mean + 2 * s.sd && magnitude > s.mean * 1.5 {
                    rows.append((line, "\(AssistantFormat.decimal(Milliunits(magnitude))) vs a typical \(AssistantFormat.decimal(Milliunits(s.mean))) in \(categoriesByID[category]?.name ?? "this category")"))
                    continue
                }
            } else if magnitude >= top5, let payee = line.payeeID, (byPayee[payee] ?? []).filter({ $0.date < line.date }).isEmpty {
                rows.append((line, "first purchase at this payee and among the largest 5 % of all outflows"))
            }
        }
        rows.sort { $0.line.amountMilliunits < $1.line.amountMilliunits }
        return AssistantToolResult(callID: call.id, name: call.name, payload: .object([
            "rows": .array(rows.prefix(50).map { entry in
                .object(["id": .string(entry.line.transactionID.description), "date": .string(entry.line.date.description),
                         "payee": .string(entry.line.payeeID.flatMap { payeesByID[$0]?.displayName } ?? ""),
                         "category": .string(entry.line.categoryID.flatMap { categoriesByID[$0]?.name } ?? ""),
                         "amount": AssistantFormat.money(entry.line.amountMilliunits, currency: currency), "reason": .string(entry.reason)])
            }),
            "semantics": .string("Rule: more than two standard deviations above the payee's (or category's) prior mean with at least three prior rows, or a first-seen payee in the top 5 % of outflows.")
        ]), provenanceLineIDs: rows.prefix(50).map(\.line.id), truncated: rows.count > 50)
    }

    private func evaluateReport(_ call: AssistantToolCall) throws -> AssistantToolResult {
        let args = call.arguments
        guard let kind = ReportKind(rawValue: args["kind"]?.stringValue ?? ""),
              let start = BudgetMonth(string: args["start"]?.stringValue ?? ""), let end = BudgetMonth(string: args["end"]?.stringValue ?? "") else {
            throw AssistantToolError(.invalidArguments, "kind, start (YYYY-MM), and end (YYYY-MM) are required")
        }
        var filters = ReportFilters()
        filters.categoryIDs = idSet(args["categoryIDs"], CategoryID.self)
        filters.accountIDs = idSet(args["accountIDs"], AccountID.self)
        filters.payeeIDs = idSet(args["payeeIDs"], PayeeID.self)
        let definition = ReportDefinition(
            kind: kind, range: .absolute(from: min(start, end), to: max(start, end)),
            granularity: ReportGranularity(rawValue: args["granularity"]?.stringValue ?? "month") ?? .month,
            filters: filters, comparePreviousPeriod: args["comparePreviousPeriod"]?.boolValue ?? false,
            visualization: args["visualization"]?.stringValue.flatMap(ReportVisualization.init(rawValue:)),
            breakdownByCategory: args["breakdownByCategory"]?.boolValue ?? false
        )
        let evaluated = ReportEngine.evaluate(definition, snapshot: snapshot, projection: projection)
        let rows = evaluated.rows.prefix(50).map { row -> JSONValue in
            var object: [String: JSONValue] = ["label": .string(row.label), "value": AssistantFormat.money(row.valueMilliunits, currency: currency), "count": .number(Double(row.count))]
            if let previous = row.previousValueMilliunits { object["previous"] = AssistantFormat.money(previous, currency: currency) }
            return .object(object)
        }
        let series = evaluated.series.map { s -> JSONValue in
            .object(["label": .string(s.label), "points": .array(s.points.map { .object(["period": .string(evaluated.periods.indices.contains($0.periodIndex) ? evaluated.periods[$0.periodIndex].label : ""), "value": AssistantFormat.money($0.valueMilliunits, currency: currency)]) })])
        }
        return AssistantToolResult(callID: call.id, name: call.name, payload: .object([
            "title": .string(args["title"]?.stringValue ?? evaluated.title), "total": AssistantFormat.money(evaluated.totalMilliunits, currency: currency),
            "rows": .array(rows), "series": .array(series), "semantics": .string(evaluated.semanticsNote)
        ]), provenanceLineIDs: Array(evaluated.rows.flatMap(\.lineIDs).prefix(lineLimit)), truncated: evaluated.rows.count > 50,
           reportDefinition: definition, proposal: .saveReport(name: args["title"]?.stringValue ?? evaluated.title, definition: definition))
    }
}

import Foundation

/// The deterministic path (docs/LOCAL-AI.md A5.3): a small grammar over
/// the most common questions, resolved against the budget's own vocabulary
/// and answered from tool results. Used when no model is configured, when
/// the model is unavailable, or after repeated malformed model output.
public struct IntentPlan: Sendable, Equatable {
    public enum Render: Sendable, Equatable {
        case spendingTotal(subject: String)
        case breakdown(title: String)
        case overTime(subject: String)
        case comparison(subject: String)
        case income
        case balances
        case budget
        case uncategorized
        case upcoming
        case netWorth
        case recurring
        case unusual
        case largest
        case report(title: String)
        case search(subject: String)
    }
    public var calls: [AssistantToolCall]
    public var render: Render
    public var interpretation: String
}

public struct IntentVocabulary: Sendable {
    public var categories: [(id: CategoryID, name: String)]
    public var groups: [(id: CategoryGroupID, name: String)]
    public var payees: [(id: PayeeID, name: String)]
    public var accounts: [(id: AccountID, name: String)]

    public init(snapshot: BudgetWorkspaceSnapshot) {
        categories = snapshot.categories.filter { $0.kind == .spending && $0.systemKind == nil }.map { ($0.id, $0.name) }
        groups = snapshot.categoryGroups.map { ($0.id, $0.name) }
        payees = snapshot.payees.filter { $0.systemKind == nil }.map { ($0.id, $0.displayName) }
        accounts = snapshot.accounts.map { ($0.id, $0.name) }
    }
}

public enum IntentGrammar {
    private static let periodWords = ["today", "yesterday", "this month", "last month", "this year", "last year", "year to date", "ytd", "this quarter", "last quarter", "this week", "last week", "all time", "ever"]

    /// Splits a question into subject and period using a fixed set of
    /// period phrases; the remainder is the subject.
    static func extractPeriod(_ text: String, today: BudgetDate, firstMonth: BudgetMonth) -> (subject: String, period: ResolvedPeriod?) {
        var remainder = text
        var found: ResolvedPeriod?
        let candidates = periodWords + ["last \\d+ (?:months?|weeks?|days?|years?)", "past \\d+ (?:months?|weeks?|days?|years?)", "next \\d+ (?:months?|weeks?|days?)", "since \\w+(?: \\d{4})?", "in (?:january|february|march|april|may|june|july|august|september|october|november|december)(?: \\d{4})?", "q[1-4](?: \\d{4})?", "in \\d{4}", "\\d{4}-\\d{2} to \\d{4}-\\d{2}"]
        for pattern in candidates {
            guard let range = remainder.range(of: "\\b" + pattern + "\\b", options: [.regularExpression, .caseInsensitive]) else { continue }
            var phrase = String(remainder[range])
            if phrase.lowercased().hasPrefix("in ") { phrase = String(phrase.dropFirst(3)) }
            if let resolved = DateExpressionResolver.resolve(phrase, today: today, firstMonth: firstMonth) {
                found = resolved
                remainder.removeSubrange(range)
                break
            }
        }
        return (remainder.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces), found)
    }

    static func match(_ subject: String, in vocabulary: IntentVocabulary) -> (categoryIDs: [CategoryID], payeeIDs: [PayeeID], groupIDs: [CategoryGroupID], accountIDs: [AccountID], label: String) {
        let normalized = BudgetWorkspace.normalizePayeeName(subject)
        var categories: [CategoryID] = []
        var payees: [PayeeID] = []
        var groups: [CategoryGroupID] = []
        var accounts: [AccountID] = []
        var labels: [String] = []
        // Split on "and"/"," so "uber and lyft" matches both.
        let parts = normalized.replacingOccurrences(of: ",", with: " AND ").components(separatedBy: " AND ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for part in parts.isEmpty ? [normalized] : parts {
            let singular = part.hasSuffix("S") ? String(part.dropLast()) : part
            if let category = vocabulary.categories.first(where: { let n = BudgetWorkspace.normalizePayeeName($0.name); return n == part || n == singular || n.hasPrefix(part) || part.hasPrefix(n) }) {
                categories.append(category.id); labels.append(category.name); continue
            }
            if let group = vocabulary.groups.first(where: { let n = BudgetWorkspace.normalizePayeeName($0.name); return n == part || n == singular }) {
                groups.append(group.id); labels.append(group.name); continue
            }
            if let account = vocabulary.accounts.first(where: { BudgetWorkspace.normalizePayeeName($0.name) == part }) {
                accounts.append(account.id); labels.append(account.name); continue
            }
            let matchingPayees = vocabulary.payees.filter { BudgetWorkspace.normalizePayeeName($0.name).contains(part) }
            if !matchingPayees.isEmpty {
                payees.append(contentsOf: matchingPayees.map(\.id))
                labels.append(matchingPayees.count == 1 ? matchingPayees[0].name : "\(matchingPayees.count) payees matching “\(part.capitalized)”")
            }
        }
        return (categories, payees, groups, accounts, labels.joined(separator: " and "))
    }

    public static func plan(question: String, vocabulary: IntentVocabulary, today: BudgetDate, firstMonth: BudgetMonth) -> IntentPlan? {
        let lowered = question.lowercased().trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "?.!"))
        let (subjectRaw, period) = extractPeriod(lowered, today: today, firstMonth: firstMonth)
        let defaultPeriod = period ?? DateExpressionResolver.resolve("this month", today: today, firstMonth: firstMonth)!
        func dates(_ p: ResolvedPeriod) -> [String: JSONValue] { ["start": .string(p.start.description), "end": .string(p.end.description)] }
        var subject = subjectRaw
        for filler in ["how much did i spend", "how much have i spent", "how much do i spend", "what did i spend", "what have i spent", "spending", "spend", "spent", "did i", "have i", "how much", "what is my", "what's my", "what are my", "show me", "show", "graph", "chart", "plot", "list", "my", "the", "on", "at", "for", "in", "with", "through", "via", "a", "an"] {
            subject = subject.replacingOccurrences(of: "\\b" + NSRegularExpression.escapedPattern(for: filler) + "\\b", with: " ", options: .regularExpression)
        }
        while subject.contains("  ") { subject = subject.replacingOccurrences(of: "  ", with: " ") }
        subject = subject.trimmingCharacters(in: .whitespaces)
        let financeIntent = ["spend", "spent", "pay", "paid", "cost", "bought", "purchase", "transaction", "charge", "buy", "money", "expense"].contains { lowered.contains($0) }

        if lowered.contains("uncategorized") || lowered.contains("need a category") || lowered.contains("needs category") || lowered.contains("staged") {
            return IntentPlan(calls: [AssistantToolCall(name: "uncategorized", arguments: .object(["limit": .number(50)]))], render: .uncategorized, interpretation: "transactions needing attention")
        }
        if lowered.contains("balance") && !lowered.contains("projected") {
            return IntentPlan(calls: [AssistantToolCall(name: "accountBalances", arguments: .object([:]))], render: .balances, interpretation: "account balances")
        }
        if lowered.contains("net worth") {
            let p = period ?? DateExpressionResolver.resolve("last 12 months", today: today, firstMonth: firstMonth)!
            return IntentPlan(calls: [AssistantToolCall(name: "netWorthHistory", arguments: .object(dates(p)))], render: .netWorth, interpretation: p.interpretation)
        }
        if lowered.contains("due") || lowered.contains("upcoming") || lowered.contains("expected") || lowered.contains("bills") || lowered.contains("scheduled") || lowered.contains("projected") || lowered.contains("remain") {
            let p = period ?? DateExpressionResolver.resolve("next 30 days", today: today, firstMonth: firstMonth)!
            return IntentPlan(calls: [AssistantToolCall(name: "upcomingScheduled", arguments: .object(dates(p)))], render: .upcoming, interpretation: p.interpretation)
        }
        if lowered.contains("subscription") || lowered.contains("recurring") {
            let p = period ?? DateExpressionResolver.resolve("last 12 months", today: today, firstMonth: firstMonth)!
            return IntentPlan(calls: [AssistantToolCall(name: "recurringMerchants", arguments: .object(dates(p)))], render: .recurring, interpretation: p.interpretation)
        }
        if lowered.contains("unusual") || lowered.contains("anomal") || lowered.contains("weird") || lowered.contains("strange") {
            let p = period ?? DateExpressionResolver.resolve("last 3 months", today: today, firstMonth: firstMonth)!
            return IntentPlan(calls: [AssistantToolCall(name: "unusualTransactions", arguments: .object(dates(p)))], render: .unusual, interpretation: p.interpretation)
        }
        if lowered.contains("largest") || lowered.contains("biggest") || lowered.contains("top purchases") {
            var args = dates(defaultPeriod)
            args["direction"] = .string("outflow"); args["sort"] = .string("amountDesc"); args["limit"] = .number(10)
            return IntentPlan(calls: [AssistantToolCall(name: "searchTransactions", arguments: .object(args))], render: .largest, interpretation: defaultPeriod.interpretation)
        }
        if lowered.contains("budget status") || lowered.contains("over budget") || lowered.contains("ready to assign") || lowered.contains("available") {
            return IntentPlan(calls: [AssistantToolCall(name: "budgetStatus", arguments: .object([:]))], render: .budget, interpretation: "current month budget")
        }
        if lowered.contains("income") || lowered.contains("earn") || lowered.contains("paid me") || lowered.contains("salary") && !lowered.contains("schedule") {
            let p = period ?? DateExpressionResolver.resolve("this year", today: today, firstMonth: firstMonth)!
            return IntentPlan(calls: [AssistantToolCall(name: "income", arguments: .object(dates(p)))], render: .income, interpretation: p.interpretation)
        }
        if lowered.hasPrefix("compare") || lowered.contains(" vs ") || lowered.contains(" versus ") || lowered.contains("compared") {
            // "compare groceries this year with last year" / "compare dining and groceries"
            let (_, secondPeriod) = extractPeriod(lowered.replacingOccurrences(of: period.map { _ in "" } ?? "", with: ""), today: today, firstMonth: firstMonth)
            let periodA = period ?? DateExpressionResolver.resolve("this month", today: today, firstMonth: firstMonth)!
            let periodB: ResolvedPeriod = {
                if let secondPeriod, secondPeriod != periodA { return secondPeriod }
                let previous = ReportEngine.previousRange(periodA.months)
                return DateExpressionResolver.resolve("\(previous.lowerBound.description) to \(previous.upperBound.description)", today: today, firstMonth: firstMonth)!
            }()
            let cleaned = subject.replacingOccurrences(of: "compare", with: "").replacingOccurrences(of: "compared", with: "").replacingOccurrences(of: " vs ", with: " and ").replacingOccurrences(of: " versus ", with: " and ").replacingOccurrences(of: " with ", with: " and ").replacingOccurrences(of: " to ", with: " and ")
            let matched = match(cleaned, in: vocabulary)
            var args: [String: JSONValue] = ["startA": .string(periodB.start.description), "endA": .string(periodB.end.description), "startB": .string(periodA.start.description), "endB": .string(periodA.end.description), "dimension": .string(matched.payeeIDs.isEmpty ? "category" : "payee")]
            if !matched.categoryIDs.isEmpty { args["categoryIDs"] = .array(matched.categoryIDs.map { .string($0.description) }) }
            return IntentPlan(calls: [AssistantToolCall(name: "comparePeriods", arguments: .object(args))], render: .comparison(subject: matched.label.isEmpty ? "spending" : matched.label), interpretation: "\(periodB.interpretation) vs \(periodA.interpretation)")
        }
        let wantsChart = lowered.contains("graph") || lowered.contains("chart") || lowered.contains("plot") || lowered.contains("by month") || lowered.contains("month to month") || lowered.contains("over time") || lowered.contains("trend") || lowered.contains("breakdown") || lowered.contains("by category") || lowered.contains("by payee") || lowered.contains("by merchant") || lowered.contains("by group")
        let matched = match(subject, in: vocabulary)
        if lowered.contains("by category") || lowered.contains("by group") || lowered.contains("categories") && !lowered.contains("by month") {
            let p = period ?? DateExpressionResolver.resolve("this month", today: today, firstMonth: firstMonth)!
            var args = dates(p)
            if lowered.contains("by group") { args["groupBy"] = .string("group") }
            if !matched.accountIDs.isEmpty { args["accountIDs"] = .array(matched.accountIDs.map { .string($0.description) }) }
            return IntentPlan(calls: [AssistantToolCall(name: "spendingByCategory", arguments: .object(args))], render: .breakdown(title: "Spending by \(lowered.contains("by group") ? "group" : "category")"), interpretation: p.interpretation)
        }
        if lowered.contains("by payee") || lowered.contains("by merchant") || lowered.contains("merchants") || lowered.contains("where") {
            let p = period ?? DateExpressionResolver.resolve("this month", today: today, firstMonth: firstMonth)!
            var args = dates(p)
            if !matched.categoryIDs.isEmpty { args["categoryIDs"] = .array(matched.categoryIDs.map { .string($0.description) }) }
            return IntentPlan(calls: [AssistantToolCall(name: "spendingByPayee", arguments: .object(args))], render: .breakdown(title: "Spending by payee"), interpretation: p.interpretation)
        }
        if wantsChart || lowered.contains("each month") || lowered.contains("per month") {
            let p = period ?? DateExpressionResolver.resolve("last 12 months", today: today, firstMonth: firstMonth)!
            var args = dates(p)
            if !matched.categoryIDs.isEmpty { args["categoryIDs"] = .array(matched.categoryIDs.map { .string($0.description) }) }
            if !matched.payeeIDs.isEmpty { args["payeeIDs"] = .array(matched.payeeIDs.map { .string($0.description) }) }
            if !matched.accountIDs.isEmpty { args["accountIDs"] = .array(matched.accountIDs.map { .string($0.description) }) }
            var reportArgs: [String: JSONValue] = ["kind": .string("spendingOverTime"), "start": .string(p.months.lowerBound.description), "end": .string(p.months.upperBound.description), "title": .string(matched.label.isEmpty ? "Spending over time" : "\(matched.label) over time")]
            if !matched.categoryIDs.isEmpty { reportArgs["categoryIDs"] = args["categoryIDs"] }
            if !matched.payeeIDs.isEmpty { reportArgs["payeeIDs"] = args["payeeIDs"] }
            if !matched.accountIDs.isEmpty { reportArgs["accountIDs"] = args["accountIDs"] }
            return IntentPlan(calls: [AssistantToolCall(name: "spendingOverTime", arguments: .object(args)), AssistantToolCall(name: "evaluateReport", arguments: .object(reportArgs))],
                              render: .overTime(subject: matched.label.isEmpty ? "spending" : matched.label), interpretation: p.interpretation)
        }
        if lowered.contains("spend") || lowered.contains("spent") || lowered.contains("cost") || !matched.categoryIDs.isEmpty || !matched.payeeIDs.isEmpty {
            let p = period ?? DateExpressionResolver.resolve("this month", today: today, firstMonth: firstMonth)!
            var args = dates(p)
            if !matched.categoryIDs.isEmpty { args["categoryIDs"] = .array(matched.categoryIDs.map { .string($0.description) }) }
            if !matched.payeeIDs.isEmpty { args["payeeIDs"] = .array(matched.payeeIDs.map { .string($0.description) }) }
            if !matched.accountIDs.isEmpty { args["accountIDs"] = .array(matched.accountIDs.map { .string($0.description) }) }
            if matched.categoryIDs.isEmpty && matched.payeeIDs.isEmpty && matched.accountIDs.isEmpty && !subject.isEmpty && !lowered.contains("total") && !lowered.contains("overall") && !lowered.contains("everything") {
                // Unknown subject: fall back to a text search so the user can see what matched.
                var search = dates(p); search["text"] = .string(subject); search["limit"] = .number(50)
                return IntentPlan(calls: [AssistantToolCall(name: "searchTransactions", arguments: .object(search))], render: .search(subject: subject), interpretation: p.interpretation)
            }
            return IntentPlan(calls: [AssistantToolCall(name: "spendingOverTime", arguments: .object(args))], render: .spendingTotal(subject: matched.label.isEmpty ? "spending" : matched.label), interpretation: p.interpretation)
        }
        if financeIntent, !subject.isEmpty {
            var search = dates(defaultPeriod); search["text"] = .string(subject); search["limit"] = .number(50)
            return IntentPlan(calls: [AssistantToolCall(name: "searchTransactions", arguments: .object(search))], render: .search(subject: subject), interpretation: defaultPeriod.interpretation)
        }
        return nil
    }

    // MARK: - Rendering (numbers come from tools, never computed here)

    public static func render(_ plan: IntentPlan, results: [AssistantToolResult], currency: String) -> String {
        func money(_ value: JSONValue?) -> String {
            guard let amount = value?["amount"]?.stringValue else { return "?" }
            return Self.formatMoney(amount, currency: currency)
        }
        guard let first = results.first else { return "I could not run that query." }
        if let error = first.error { return "I could not answer that: \(error.message)" }
        let data = first.payload
        switch plan.render {
        case .spendingTotal(let subject):
            let rows = data["rows"]?.arrayValue ?? []
            var text = "Net spending on \(subject) for \(plan.interpretation): \(money(data["total"]))."
            if rows.count > 1 { text += " By month: " + rows.map { "\($0["period"]?.stringValue ?? "") \(money($0["netSpending"]))" }.joined(separator: ", ") + "." }
            return text
        case .breakdown(let title):
            let rows = data["rows"]?.arrayValue ?? []
            if rows.isEmpty { return "No spending found for \(plan.interpretation)." }
            return "\(title), \(plan.interpretation), total \(money(data["total"])):\n" + rows.prefix(12).map { "• \($0["name"]?.stringValue ?? $0["payee"]?.stringValue ?? "?"): \(money($0["netSpending"]))" }.joined(separator: "\n")
        case .overTime(let subject):
            let rows = data["rows"]?.arrayValue ?? []
            return "\(subject.capitalized) over \(plan.interpretation), total \(money(data["total"])), average \(money(data["averagePerPeriod"])) per period:\n" + rows.map { "• \($0["period"]?.stringValue ?? ""): \(money($0["netSpending"]))" }.joined(separator: "\n")
        case .comparison(let subject):
            let a = data["periodA"], b = data["periodB"]
            let rows = data["rows"]?.arrayValue ?? []
            var text = "\(subject.capitalized): \(money(a?["total"])) (\(a?["start"]?.stringValue ?? "") to \(a?["end"]?.stringValue ?? "")) vs \(money(b?["total"])) (\(b?["start"]?.stringValue ?? "") to \(b?["end"]?.stringValue ?? "")), change \(money(data["change"]))."
            if !rows.isEmpty { text += "\nBiggest changes:\n" + rows.prefix(6).map { "• \($0["name"]?.stringValue ?? "?"): \(money($0["periodA"])) → \(money($0["periodB"])) (\(money($0["change"])))" }.joined(separator: "\n") }
            return text
        case .income:
            let rows = data["rows"]?.arrayValue ?? []
            return "Income for \(plan.interpretation): \(money(data["total"])).\n" + rows.map { "• \($0["period"]?.stringValue ?? ""): \(money($0["income"]))" }.joined(separator: "\n")
        case .balances:
            let rows = data["accounts"]?.arrayValue ?? []
            return "Account balances:\n" + rows.map { "• \($0["name"]?.stringValue ?? ""): \(money($0["registerBalance"]))" + (($0["needsAttentionCount"]?.intValue ?? 0) > 0 ? " (\($0["needsAttentionCount"]?.intValue ?? 0) need attention)" : "") }.joined(separator: "\n")
        case .budget:
            let categories = data["categories"]?.arrayValue ?? []
            let over = categories.filter { ($0["available"]?["milliunits"]?.doubleValue ?? 0) < 0 }
            var text = "\(data["month"]?.stringValue ?? "This month"): Ready to Assign \(money(data["readyToAssign"])), assigned \(money(data["totalAssigned"]))."
            if !over.isEmpty { text += "\nOverspent: " + over.map { "\($0["name"]?.stringValue ?? "") \(money($0["available"]))" }.joined(separator: ", ") + "." } else { text += " No category is overspent." }
            return text
        case .uncategorized:
            let rows = data["rows"]?.arrayValue ?? []
            if rows.isEmpty { return "Everything is categorized and nothing is staged." }
            return "\(data["count"]?.intValue ?? rows.count) transaction(s) need attention:\n" + rows.prefix(15).map { "• \($0["date"]?.stringValue ?? "") \($0["payee"]?.stringValue ?? "") \(money($0["amount"])) — \($0["status"]?.stringValue ?? "")" }.joined(separator: "\n")
        case .upcoming:
            let upcoming = data["upcoming"]?.arrayValue ?? []
            let overdue = data["overdue"]?.arrayValue ?? []
            var text = upcoming.isEmpty ? "Nothing is expected in \(plan.interpretation)." : "Expected in \(plan.interpretation) (net \(money(data["expectedNet"]))):\n" + upcoming.map { "• \($0["dueDate"]?.stringValue ?? "") \($0["schedule"]?.stringValue ?? "") \(money($0["amount"]))" }.joined(separator: "\n")
            if !overdue.isEmpty { text += "\nOverdue, no matching transaction yet: " + overdue.map { "\($0["schedule"]?.stringValue ?? "") (\($0["dueDate"]?.stringValue ?? ""))" }.joined(separator: ", ") }
            if let balances = data["projectedBalances"]?.arrayValue, !balances.isEmpty {
                text += "\nProjected balances (estimates): " + balances.map { "\($0["account"]?.stringValue ?? "") \(money($0["projected"]))" }.joined(separator: ", ")
            }
            return text
        case .netWorth:
            let rows = data["rows"]?.arrayValue ?? []
            guard let last = rows.last else { return "No net worth data." }
            let firstRow = rows.first
            return "Net worth at \(last["period"]?.stringValue ?? ""): \(money(last["netWorth"]))" + (rows.count > 1 ? " (from \(money(firstRow?["netWorth"])) at \(firstRow?["period"]?.stringValue ?? ""))." : ".")
        case .recurring:
            let rows = data["rows"]?.arrayValue ?? []
            if rows.isEmpty { return "No recurring charges were detected in \(plan.interpretation) (needs at least three regular occurrences)." }
            return "Recurring charges detected in \(plan.interpretation):\n" + rows.map { "• \($0["payee"]?.stringValue ?? ""): \(money($0["typicalAmount"])) \($0["cadence"]?.stringValue ?? ""), last \($0["lastSeen"]?.stringValue ?? "")" + (($0["changeSinceFirst"]?["milliunits"]?.doubleValue ?? 0) != 0 ? ", changed \(money($0["changeSinceFirst"])) since first" : "") }.joined(separator: "\n")
        case .unusual:
            let rows = data["rows"]?.arrayValue ?? []
            if rows.isEmpty { return "Nothing looks unusual in \(plan.interpretation) by the fixed rule (two standard deviations above the payee's or category's prior mean)." }
            return "Unusual in \(plan.interpretation):\n" + rows.prefix(10).map { "• \($0["date"]?.stringValue ?? "") \($0["payee"]?.stringValue ?? "") \(money($0["amount"])) — \($0["reason"]?.stringValue ?? "")" }.joined(separator: "\n")
        case .largest:
            let rows = data["rows"]?.arrayValue ?? []
            if rows.isEmpty { return "No outflows in \(plan.interpretation)." }
            return "Largest purchases in \(plan.interpretation):\n" + rows.map { "• \($0["date"]?.stringValue ?? "") \($0["payee"]?.stringValue ?? "") \(money($0["amount"])) (\($0["category"]?.stringValue ?? "no category"))" }.joined(separator: "\n")
        case .report(let title):
            return "\(title): \(money(data["total"]))."
        case .search(let subject):
            let rows = data["rows"]?.arrayValue ?? []
            if rows.isEmpty { return "No transactions match “\(subject)” in \(plan.interpretation)." }
            return "\(data["matchCount"]?.intValue ?? rows.count) transaction(s) matching “\(subject)” in \(plan.interpretation), total \(money(data["total"])):\n" + rows.prefix(15).map { "• \($0["date"]?.stringValue ?? "") \($0["payee"]?.stringValue ?? "") \(money($0["amount"]))" }.joined(separator: "\n")
        }
    }

    static func formatMoney(_ decimal: String, currency: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        formatter.generatesDecimalNumbers = true
        if let value = Decimal(string: decimal, locale: Locale(identifier: "en_US_POSIX")) {
            return formatter.string(from: NSDecimalNumber(decimal: value)) ?? decimal
        }
        return decimal
    }
}

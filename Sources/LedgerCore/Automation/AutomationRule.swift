import Foundation

// MARK: - Rule model (docs/DESIGN.md D4)

public enum RuleMatchMode: String, Sendable, Codable, CaseIterable {
    /// Every condition must hold (AND).
    case all
    /// At least one condition must hold (OR).
    case any
}

public enum RuleTextOperator: String, Sendable, Codable, CaseIterable {
    case contains
    case equals
    case startsWith
    case endsWith
    /// Glob with `*` (any run) and `?` (one character), matched whole.
    case wildcard
}

public enum RuleAmountOperator: Sendable, Codable, Equatable, Hashable {
    case equals(Milliunits)
    case lessThan(Milliunits)
    case greaterThan(Milliunits)
    case between(Milliunits, Milliunits)
}

public enum RuleDirection: String, Sendable, Codable, CaseIterable {
    case outflow
    case inflow
}

public enum RuleSource: String, Sendable, Codable, CaseIterable {
    case imported   // SimpleFIN or file
    case manual
    case simplefin
    case file
}

public enum RuleDateCondition: Sendable, Codable, Equatable, Hashable {
    /// Day of month within `from...to` (1…31, clamped by the calendar).
    case dayOfMonth(from: Int, to: Int)
    /// Weekday set, 1 = Sunday … 7 = Saturday (Gregorian, budget calendar).
    case weekdays([Int])
    /// Inclusive budget-date range.
    case range(from: BudgetDate, to: BudgetDate)
}

/// One predicate. Text conditions compare the normalized (NFKC, uppercase,
/// whitespace-collapsed) form of both sides, so matching is case- and
/// width-insensitive but still deterministic.
public enum RuleCondition: Sendable, Codable, Equatable, Hashable {
    /// The provider/file text as imported (`importedDescription`); falls
    /// back to the payee display name for rows without one.
    case importedDescription(RuleTextOperator, String)
    case payee(RuleTextOperator, String)
    case memo(RuleTextOperator, String)
    case account(AccountID)
    /// Compared against the amount magnitude; use `direction` for sign.
    case amount(RuleAmountOperator)
    case direction(RuleDirection)
    case date(RuleDateCondition)
    case source(RuleSource)
    case category(CategoryID?)
}

public enum RuleMemoMode: String, Sendable, Codable, CaseIterable {
    case replace
    case append
    case prepend
}

/// A split produced by a rule: either fixed component amounts (must sum to
/// the row) or percentages in basis points (must sum to 10_000), rounded
/// with the largest-remainder method so the sum is exact.
public struct RuleSplitSpec: Sendable, Codable, Equatable, Hashable {
    public enum Share: Sendable, Codable, Equatable, Hashable {
        case fixed(Milliunits)         // magnitude
        case basisPoints(Int)          // 1 = 0.01 %
    }
    public var categoryID: CategoryID
    public var share: Share
    public var memo: String?

    public init(categoryID: CategoryID, share: Share, memo: String? = nil) {
        self.categoryID = categoryID
        self.share = share
        self.memo = memo
    }
}

public enum RuleAction: Sendable, Codable, Equatable, Hashable {
    case setPayee(String)
    case setCategory(CategoryID)
    case setMemo(RuleMemoMode, String)
    case setFlag(FlagColor?)
    case setApproved(Bool)
    case split([RuleSplitSpec])
}

public struct AutomationRule: Sendable, Codable, Equatable, Identifiable, Hashable {
    public var id: AutomationRuleID
    public var budgetID: BudgetID
    public var name: String
    public var enabled: Bool
    /// Evaluation order; ties break on `id` so evaluation is total and stable.
    public var sortOrder: Int
    public var matchMode: RuleMatchMode
    public var conditions: [RuleCondition]
    public var actions: [RuleAction]
    /// When true, a match ends the pass for that row.
    public var stopAfterMatch: Bool
    public var createdAtEpoch: Int64
    public var updatedAtEpoch: Int64

    public init(
        id: AutomationRuleID = AutomationRuleID(),
        budgetID: BudgetID,
        name: String,
        enabled: Bool = true,
        sortOrder: Int,
        matchMode: RuleMatchMode = .all,
        conditions: [RuleCondition],
        actions: [RuleAction],
        stopAfterMatch: Bool = false,
        createdAtEpoch: Int64 = 0,
        updatedAtEpoch: Int64 = 0
    ) {
        self.id = id
        self.budgetID = budgetID
        self.name = name
        self.enabled = enabled
        self.sortOrder = sortOrder
        self.matchMode = matchMode
        self.conditions = conditions
        self.actions = actions
        self.stopAfterMatch = stopAfterMatch
        self.createdAtEpoch = createdAtEpoch
        self.updatedAtEpoch = updatedAtEpoch
    }
}

// MARK: - Evaluation

/// The facts a rule may read. Built from a `TransactionRow` and the
/// workspace; the engine never sees the workspace itself.
public struct RuleSubject: Sendable, Equatable {
    public var importedDescription: String?
    public var payeeDisplayName: String?
    public var memo: String?
    public var accountID: AccountID
    public var amountMilliunits: Milliunits
    public var date: BudgetDate
    public var sourceKind: SourceKind
    public var categoryID: CategoryID?
    public var isSplit: Bool

    public init(
        importedDescription: String?,
        payeeDisplayName: String?,
        memo: String?,
        accountID: AccountID,
        amountMilliunits: Milliunits,
        date: BudgetDate,
        sourceKind: SourceKind,
        categoryID: CategoryID?,
        isSplit: Bool
    ) {
        self.importedDescription = importedDescription
        self.payeeDisplayName = payeeDisplayName
        self.memo = memo
        self.accountID = accountID
        self.amountMilliunits = amountMilliunits
        self.date = date
        self.sourceKind = sourceKind
        self.categoryID = categoryID
        self.isSplit = isSplit
    }
}

/// What the engine may consult to validate actions without touching state.
public struct RuleContext: Sendable {
    public var categories: [CategoryID: CategoryRow]
    public var accounts: [AccountID: AccountRow]
    public var budgetCurrency: String
    public var rtaCategoryID: CategoryID
    public var uncategorizedID: CategoryID

    public init(
        categories: [CategoryID: CategoryRow],
        accounts: [AccountID: AccountRow],
        budgetCurrency: String,
        rtaCategoryID: CategoryID,
        uncategorizedID: CategoryID
    ) {
        self.categories = categories
        self.accounts = accounts
        self.budgetCurrency = budgetCurrency
        self.rtaCategoryID = rtaCategoryID
        self.uncategorizedID = uncategorizedID
    }
}

/// The concrete, already-validated changes a pass proposes for one row.
public struct RuleProposal: Sendable, Equatable {
    public var payeeName: String?
    public var categoryID: CategoryID?
    public var memo: String??          // .some(nil) clears
    public var flagColor: FlagColor??  // .some(nil) clears
    public var approved: Bool?
    public var splits: [SplitComponent]?
    public var appliedRuleIDs: [AutomationRuleID] = []
    public var skipped: [RuleSkip] = []

    public init() {}

    public var isEmpty: Bool {
        payeeName == nil && categoryID == nil && memo == nil && flagColor == nil
            && approved == nil && splits == nil
    }
}

/// An action that matched but could not be applied, with the reason.
public struct RuleSkip: Sendable, Equatable, Hashable {
    public enum Reason: String, Sendable, Codable {
        case categoryNotAllowed
        case splitNotAllowed
        case splitDoesNotSum
        case rowAlreadySplit
        case emptyPayee
    }
    public var ruleID: AutomationRuleID
    public var reason: Reason

    public init(ruleID: AutomationRuleID, reason: Reason) {
        self.ruleID = ruleID
        self.reason = reason
    }
}

public enum RuleEngine {

    /// Deterministic single forward pass (D4.3): rules ordered by
    /// `(sortOrder, id)`, each matching rule's actions applied in order to a
    /// working copy of the subject so later rules observe earlier changes.
    public static func evaluate(
        rules: [AutomationRule],
        subject: RuleSubject,
        context: RuleContext
    ) -> RuleProposal {
        var proposal = RuleProposal()
        var working = subject
        let ordered = rules
            .filter { $0.enabled }
            .sorted { ($0.sortOrder, $0.id) < ($1.sortOrder, $1.id) }
        for rule in ordered {
            guard matches(rule, subject: working) else { continue }
            var applied = false
            for action in rule.actions {
                switch apply(action, rule: rule, subject: &working, proposal: &proposal, context: context) {
                case .applied: applied = true
                case .skipped(let reason): proposal.skipped.append(RuleSkip(ruleID: rule.id, reason: reason))
                }
            }
            if applied { proposal.appliedRuleIDs.append(rule.id) }
            if rule.stopAfterMatch { break }
        }
        return proposal
    }

    public static func matches(_ rule: AutomationRule, subject: RuleSubject) -> Bool {
        guard !rule.conditions.isEmpty else { return false } // a rule with no conditions never fires
        switch rule.matchMode {
        case .all: return rule.conditions.allSatisfy { holds($0, subject: subject) }
        case .any: return rule.conditions.contains { holds($0, subject: subject) }
        }
    }

    public static func holds(_ condition: RuleCondition, subject: RuleSubject) -> Bool {
        switch condition {
        case let .importedDescription(op, value):
            let text = subject.importedDescription ?? subject.payeeDisplayName ?? ""
            return textMatches(op, haystack: text, needle: value)
        case let .payee(op, value):
            return textMatches(op, haystack: subject.payeeDisplayName ?? "", needle: value)
        case let .memo(op, value):
            return textMatches(op, haystack: subject.memo ?? "", needle: value)
        case let .account(id):
            return subject.accountID == id
        case let .amount(op):
            let magnitude = subject.amountMilliunits.magnitude
            guard magnitude <= UInt64(Int64.max) else { return false }
            let m = Int64(magnitude)
            switch op {
            case .equals(let v): return m == v
            case .lessThan(let v): return m < v
            case .greaterThan(let v): return m > v
            case .between(let a, let b): return m >= min(a, b) && m <= max(a, b)
            }
        case let .direction(direction):
            switch direction {
            case .outflow: return subject.amountMilliunits < 0
            case .inflow: return subject.amountMilliunits > 0
            }
        case let .date(dateCondition):
            switch dateCondition {
            case let .dayOfMonth(from, to):
                return subject.date.day >= min(from, to) && subject.date.day <= max(from, to)
            case let .weekdays(days):
                return days.contains(weekday(of: subject.date))
            case let .range(from, to):
                return subject.date >= min(from, to) && subject.date <= max(from, to)
            }
        case let .source(source):
            switch source {
            case .imported: return subject.sourceKind == .simplefin || subject.sourceKind == .file
            case .manual: return subject.sourceKind == .manual
            case .simplefin: return subject.sourceKind == .simplefin
            case .file: return subject.sourceKind == .file
            }
        case let .category(id):
            return subject.categoryID == id
        }
    }

    static func textMatches(_ op: RuleTextOperator, haystack: String, needle: String) -> Bool {
        let h = BudgetWorkspace.normalizePayeeName(haystack)
        let n = BudgetWorkspace.normalizePayeeName(needle)
        guard !n.isEmpty else { return false }
        switch op {
        case .contains: return h.contains(n)
        case .equals: return h == n
        case .startsWith: return h.hasPrefix(n)
        case .endsWith: return h.hasSuffix(n)
        case .wildcard: return glob(pattern: Array(n), text: Array(h))
        }
    }

    /// Iterative glob matcher (`*` any run, `?` one character); linear in the
    /// text for each `*` backtrack point, no recursion, no regex.
    static func glob(pattern: [Character], text: [Character]) -> Bool {
        var p = 0, t = 0
        var starP = -1, starT = -1
        while t < text.count {
            if p < pattern.count, pattern[p] == "*" {
                starP = p; starT = t; p += 1
            } else if p < pattern.count, pattern[p] == "?" || pattern[p] == text[t] {
                p += 1; t += 1
            } else if starP >= 0 {
                p = starP + 1; starT += 1; t = starT
            } else {
                return false
            }
        }
        while p < pattern.count, pattern[p] == "*" { p += 1 }
        return p == pattern.count
    }

    /// 1 = Sunday … 7 = Saturday, proleptic Gregorian.
    static func weekday(of date: BudgetDate) -> Int {
        let days = BudgetWorkspace.civilDayNumber(date) // 1970-01-01 (Thursday) = 0
        let index = ((days % 7) + 7) % 7 // 0 = Thursday
        return ((index + 4) % 7) + 1     // Thursday → 5
    }

    enum ActionResult { case applied; case skipped(RuleSkip.Reason) }

    static func apply(
        _ action: RuleAction,
        rule: AutomationRule,
        subject: inout RuleSubject,
        proposal: inout RuleProposal,
        context: RuleContext
    ) -> ActionResult {
        switch action {
        case .setPayee(let name):
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return .skipped(.emptyPayee) }
            proposal.payeeName = trimmed
            subject.payeeDisplayName = trimmed
            return .applied
        case .setCategory(let id):
            guard categoryAllowed(id, subject: subject, context: context) else {
                return .skipped(.categoryNotAllowed)
            }
            proposal.categoryID = id
            proposal.splits = nil
            subject.categoryID = id
            subject.isSplit = false
            return .applied
        case let .setMemo(mode, text):
            let current = subject.memo ?? ""
            let next: String
            switch mode {
            case .replace: next = text
            case .append: next = current.isEmpty ? text : current + " " + text
            case .prepend: next = current.isEmpty ? text : text + " " + current
            }
            proposal.memo = .some(next.isEmpty ? nil : next)
            subject.memo = next.isEmpty ? nil : next
            return .applied
        case .setFlag(let color):
            proposal.flagColor = .some(color)
            return .applied
        case .setApproved(let approved):
            proposal.approved = approved
            return .applied
        case .split(let specs):
            guard subject.amountMilliunits < 0, subject.sourceKind != .system,
                  let account = context.accounts[subject.accountID],
                  budgetEligible(account, budgetCurrency: context.budgetCurrency) else {
                return .skipped(.splitNotAllowed)
            }
            guard !subject.isSplit else { return .skipped(.rowAlreadySplit) }
            for spec in specs {
                guard let category = context.categories[spec.categoryID], category.kind == .spending else {
                    return .skipped(.categoryNotAllowed)
                }
            }
            guard let components = resolveSplit(specs, totalMagnitude: -subject.amountMilliunits) else {
                return .skipped(.splitDoesNotSum)
            }
            proposal.splits = components
            proposal.categoryID = nil
            subject.isSplit = true
            subject.categoryID = nil
            return .applied
        }
    }

    static func categoryAllowed(_ id: CategoryID, subject: RuleSubject, context: RuleContext) -> Bool {
        guard let category = context.categories[id], !category.hidden, category.kind != .ccPayment,
              let account = context.accounts[subject.accountID],
              budgetEligible(account, budgetCurrency: context.budgetCurrency) else { return false }
        if subject.amountMilliunits > 0 {
            // Positive rows may only point at RTA (§2.2.1); cards never receive
            // a positive normal row.
            return account.type != .creditCard && id == context.rtaCategoryID
        }
        return category.kind == .spending && id != context.uncategorizedID
    }

    /// Resolves split shares into signed components whose sum equals
    /// `-totalMagnitude` exactly. Fixed shares must sum to the total;
    /// basis-point shares must sum to 10 000 and are rounded with the
    /// largest-remainder method (deterministic, exact by construction).
    /// Mixed fixed/percent specs apply percentages to the remainder after
    /// fixed shares.
    public static func resolveSplit(_ specs: [RuleSplitSpec], totalMagnitude: Milliunits) -> [SplitComponent]? {
        guard specs.count >= 2, totalMagnitude > 0 else { return nil }
        var fixedTotal: Milliunits = 0
        var basisTotal = 0
        for spec in specs {
            switch spec.share {
            case .fixed(let m):
                guard m > 0 else { return nil }
                let (sum, overflow) = fixedTotal.addingReportingOverflow(m)
                if overflow { return nil }
                fixedTotal = sum
            case .basisPoints(let bp):
                guard bp > 0 else { return nil }
                basisTotal += bp
            }
        }
        guard fixedTotal <= totalMagnitude else { return nil }
        let remainder = totalMagnitude - fixedTotal
        if basisTotal == 0 {
            guard remainder == 0 else { return nil }
        } else {
            guard basisTotal == 10_000, remainder > 0 else { return nil }
        }
        // Largest remainder over the basis-point shares.
        var magnitudes = [Milliunits](repeating: 0, count: specs.count)
        var fractional: [(index: Int, remainderPart: Int64)] = []
        var allocated: Milliunits = 0
        for (index, spec) in specs.enumerated() {
            switch spec.share {
            case .fixed(let m):
                magnitudes[index] = m
            case .basisPoints(let bp):
                let (product, overflow) = remainder.multipliedReportingOverflow(by: Int64(bp))
                if overflow { return nil }
                magnitudes[index] = product / 10_000
                fractional.append((index, product % 10_000))
                allocated += magnitudes[index]
            }
        }
        var leftover = remainder - allocated
        for entry in fractional.sorted(by: { ($0.remainderPart, -Int64($0.index)) > ($1.remainderPart, -Int64($1.index)) }) where leftover > 0 {
            magnitudes[entry.index] += 1
            leftover -= 1
        }
        guard leftover == 0, magnitudes.allSatisfy({ $0 > 0 }) else { return nil }
        return specs.enumerated().map { index, spec in
            SplitComponent(categoryID: spec.categoryID, amountMilliunits: -magnitudes[index], memo: spec.memo)
        }
    }
}

import Foundation

/// A change the assistant drafted. It is data until the user clicks Apply;
/// `apply` routes through the same workspace mutations the UI uses, so the
/// model can never bypass validation (docs/LOCAL-AI.md A3/A4).
public enum ProposedAction: Sendable, Equatable, Codable {
    case categorize(transactionIDs: [TransactionID], categoryID: CategoryID)
    case renamePayee(transactionIDs: [TransactionID], name: String)
    case createRule(name: String, conditions: [RuleCondition], actions: [RuleAction])
    case split(transactionID: TransactionID, components: [SplitComponent])
    case createSchedule(Schedule)
    case moveMoney(source: MoveMoneyEndpointCodable, destination: MoveMoneyEndpointCodable, amountMilliunits: Milliunits, month: BudgetMonth)
    case saveReport(name: String, definition: ReportDefinition)

    public var title: String {
        switch self {
        case .categorize(let ids, _): return "Categorize \(ids.count) transaction(s)"
        case .renamePayee(let ids, let name): return "Rename payee on \(ids.count) transaction(s) to “\(name)”"
        case .createRule(let name, _, _): return "Create rule “\(name)”"
        case .split: return "Split a transaction"
        case .createSchedule(let schedule): return "Create schedule “\(schedule.name)”"
        case .moveMoney(_, _, let amount, _): return "Move \(MoneyParser.decimalString(fromMilliunits: amount))"
        case .saveReport(let name, _): return "Save report “\(name)”"
        }
    }

    /// Modify-level actions require confirmation; drafts are already inert.
    public var isModification: Bool {
        if case .saveReport = self { return false }
        return true
    }
}

/// Codable stand-in for `MoveMoneyEndpoint`.
public enum MoveMoneyEndpointCodable: Sendable, Equatable, Codable {
    case rta
    case category(CategoryID)

    public var endpoint: MoveMoneyEndpoint {
        switch self {
        case .rta: return .rta
        case .category(let id): return .category(id)
        }
    }
}

/// What the user sees before applying: before/after lines and any
/// validation failure, computed by dry-running the mutation on a copy.
public struct ProposalPreview: Sendable, Equatable {
    public var title: String
    public var lines: [String]
    public var affectedCount: Int
    public var error: String?
    public var isApplicable: Bool { error == nil }
}

extension BudgetWorkspace {

    /// Dry-run: applies the proposal to a copy and reports what changed.
    public func previewProposal(_ action: ProposedAction) -> ProposalPreview {
        var copy = self
        var lines: [String] = []
        do {
            switch action {
            case let .categorize(ids, categoryID):
                let name = categories[categoryID]?.name ?? "?"
                for id in ids {
                    guard let row = transactions[id] else { throw MutationError.transactionNotFound }
                    let before = row.categoryID.flatMap { categories[$0]?.name } ?? (row.isSplit ? "split" : "none")
                    lines.append("\(row.date.description) \(payees[row.payeeID ?? PayeeID()]?.displayName ?? "") \(MoneyParser.decimalString(fromMilliunits: row.amountMilliunits)): \(before) → \(name)")
                    try copy.categorize(transactionID: id, categoryID: categoryID, nowEpoch: 0)
                }
            case let .renamePayee(ids, name):
                for id in ids {
                    guard let row = transactions[id] else { throw MutationError.transactionNotFound }
                    lines.append("\(row.date.description): \(payees[row.payeeID ?? PayeeID()]?.displayName ?? "") → \(name)")
                }
                try copy.setPayeeName(for: ids, to: name, nowEpoch: 0)
            case let .createRule(name, conditions, actions):
                _ = try copy.addRule(name: name, conditions: conditions, actions: actions, nowEpoch: 0)
                let preview = copy.previewRules(scope: RuleApplicationScope())
                lines.append("Rule “\(name)” with \(conditions.count) condition(s) and \(actions.count) action(s).")
                lines.append("\(preview.count) existing transaction(s) would change if applied retroactively (not done automatically).")
            case let .split(id, components):
                guard let row = transactions[id] else { throw MutationError.transactionNotFound }
                lines.append("\(row.date.description) \(MoneyParser.decimalString(fromMilliunits: row.amountMilliunits)) →")
                for component in components {
                    lines.append("  \(categories[component.categoryID]?.name ?? "?") \(MoneyParser.decimalString(fromMilliunits: component.amountMilliunits))")
                }
                try copy.setSplits(transactionID: id, components: components, nowEpoch: 0)
            case .createSchedule(let schedule):
                _ = try copy.addSchedule(schedule, nowEpoch: 0)
                lines.append("\(schedule.recurrence.summary), \(MoneyParser.decimalString(fromMilliunits: schedule.amountMilliunits)) on \(accounts[schedule.accountID]?.name ?? "?") starting \(schedule.startDate.description)")
            case let .moveMoney(source, destination, amount, month):
                let before = try copy.projection(through: month).month(month)
                try copy.moveMoney(source: source.endpoint, destination: destination.endpoint, amount: amount, month: month, nowEpoch: 0)
                let after = try copy.projection(through: month).month(month)
                func describe(_ endpoint: MoveMoneyEndpointCodable, _ snap: MonthSnapshot?) -> String {
                    switch endpoint {
                    case .rta: return "Ready to Assign \(MoneyParser.decimalString(fromMilliunits: snap?.rtaEnd ?? 0))"
                    case .category(let id):
                        let available = snap?.categories[id]?.available ?? snap?.payments[id]?.available ?? 0
                        return "\(categories[id]?.name ?? "?") \(MoneyParser.decimalString(fromMilliunits: available))"
                    }
                }
                lines.append("Before: \(describe(source, before)) · \(describe(destination, before))")
                lines.append("After: \(describe(source, after)) · \(describe(destination, after))")
            case let .saveReport(name, definition):
                _ = try copy.saveReport(name: name, definition: definition, nowEpoch: 0)
                lines.append("\(definition.kind.title), \(definition.granularity.title.lowercased())ly, \(definition.visualization.title.lowercased()) chart")
            }
            return ProposalPreview(title: action.title, lines: lines, affectedCount: affectedCount(action), error: nil)
        } catch {
            return ProposalPreview(title: action.title, lines: lines, affectedCount: affectedCount(action), error: "\(error)")
        }
    }

    private func affectedCount(_ action: ProposedAction) -> Int {
        switch action {
        case .categorize(let ids, _), .renamePayee(let ids, _): return ids.count
        default: return 1
        }
    }

    /// Executes a proposal through the ordinary mutations. Called only by
    /// the app after the user confirms.
    public mutating func applyProposal(_ action: ProposedAction, nowEpoch: Int64) throws {
        switch action {
        case let .categorize(ids, categoryID):
            var copy = self
            for id in ids { try copy.categorize(transactionID: id, categoryID: categoryID, nowEpoch: nowEpoch) }
            self = copy
        case let .renamePayee(ids, name):
            try setPayeeName(for: ids, to: name, nowEpoch: nowEpoch)
        case let .createRule(name, conditions, actions):
            _ = try addRule(name: name, conditions: conditions, actions: actions, nowEpoch: nowEpoch)
        case let .split(id, components):
            try setSplits(transactionID: id, components: components, nowEpoch: nowEpoch)
        case .createSchedule(let schedule):
            _ = try addSchedule(schedule, nowEpoch: nowEpoch)
        case let .moveMoney(source, destination, amount, month):
            try moveMoney(source: source.endpoint, destination: destination.endpoint, amount: amount, month: month, nowEpoch: nowEpoch)
        case let .saveReport(name, definition):
            _ = try saveReport(name: name, definition: definition, nowEpoch: nowEpoch)
        }
    }

    /// Changes the user-facing payee of rows (imported descriptions are
    /// untouched). Guarded like other edits.
    public mutating func setPayeeName(for ids: [TransactionID], to name: String, nowEpoch: Int64) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MutationError.nameEmpty }
        var copy = self
        let payeeID = copy.findOrCreateUserPayee(named: trimmed)
        for id in ids {
            guard var row = copy.transactions[id], row.postingState != .voided else { throw MutationError.transactionNotFound }
            guard row.sourceKind != .system, row.transferPairID == nil else { throw MutationError.transactionImmutable }
            guard row.cleared != .reconciled else { throw MutationError.reconciledTransaction }
            guard !copy.isMonthClosed(row.date.budgetMonth) else { throw MutationError.closedMonth }
            row.payeeID = payeeID
            row.userEditedAtEpoch = nowEpoch
            copy.setTransaction(row)
        }
        try copy.bumpRevision()
        self = copy
    }
}

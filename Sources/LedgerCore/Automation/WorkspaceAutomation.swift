import Foundation

/// Which rows a retroactive rule pass considers.
public struct RuleApplicationScope: Sendable, Equatable {
    public var accountID: AccountID?
    public var dateRange: ClosedRange<BudgetDate>?
    public var ruleIDs: Set<AutomationRuleID>?
    /// Include rows the user explicitly categorized/edited (default false).
    public var overwriteUserEdits: Bool
    /// Include rows whose category is already set (not `needsCategory`).
    public var includeCategorized: Bool

    public init(
        accountID: AccountID? = nil,
        dateRange: ClosedRange<BudgetDate>? = nil,
        ruleIDs: Set<AutomationRuleID>? = nil,
        overwriteUserEdits: Bool = false,
        includeCategorized: Bool = true
    ) {
        self.accountID = accountID
        self.dateRange = dateRange
        self.ruleIDs = ruleIDs
        self.overwriteUserEdits = overwriteUserEdits
        self.includeCategorized = includeCategorized
    }
}

/// One row's proposed change from a retroactive pass, for preview.
public struct RulePreviewItem: Sendable, Equatable, Identifiable {
    public var transactionID: TransactionID
    public var proposal: RuleProposal
    public var id: TransactionID { transactionID }
}

public struct RuleApplicationSummary: Sendable, Equatable {
    public var consideredRows: Int
    public var changedRows: Int
    public var skippedActions: Int
}

extension BudgetWorkspace {

    // MARK: - Rule CRUD (D4.1)

    func validateRule(_ rule: AutomationRule) throws {
        let name = rule.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !rule.conditions.isEmpty, !rule.actions.isEmpty, rule.budgetID == budget.id else {
            throw MutationError.ruleInvalid
        }
        for condition in rule.conditions {
            switch condition {
            case .account(let id):
                guard accounts[id] != nil else { throw MutationError.ruleInvalid }
            case .category(let id?):
                guard categories[id] != nil else { throw MutationError.ruleInvalid }
            case let .importedDescription(_, value), let .payee(_, value), let .memo(_, value):
                guard !BudgetWorkspace.normalizePayeeName(value).isEmpty else { throw MutationError.ruleInvalid }
            case let .date(.dayOfMonth(from, to)):
                guard (1...31).contains(from), (1...31).contains(to) else { throw MutationError.ruleInvalid }
            case let .date(.weekdays(days)):
                guard !days.isEmpty, days.allSatisfy({ (1...7).contains($0) }) else { throw MutationError.ruleInvalid }
            case let .amount(op):
                switch op {
                case .equals(let v), .lessThan(let v), .greaterThan(let v):
                    guard v >= 0 else { throw MutationError.ruleInvalid }
                case let .between(a, b):
                    guard a >= 0, b >= 0 else { throw MutationError.ruleInvalid }
                }
            default: break
            }
        }
        for action in rule.actions {
            switch action {
            case .setCategory(let id):
                guard let category = categories[id], category.kind != .ccPayment, id != uncategorizedID else {
                    throw MutationError.ruleInvalid
                }
            case .split(let specs):
                guard specs.count >= 2 else { throw MutationError.ruleInvalid }
                for spec in specs {
                    guard let category = categories[spec.categoryID], category.kind == .spending else {
                        throw MutationError.ruleInvalid
                    }
                }
            case .setPayee(let name):
                guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw MutationError.ruleInvalid
                }
            default: break
            }
        }
    }

    @discardableResult
    public mutating func addRule(
        name: String,
        matchMode: RuleMatchMode = .all,
        conditions: [RuleCondition],
        actions: [RuleAction],
        stopAfterMatch: Bool = false,
        enabled: Bool = true,
        nowEpoch: Int64
    ) throws -> AutomationRuleID {
        let rule = AutomationRule(
            budgetID: budget.id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            enabled: enabled,
            sortOrder: (automationRules.values.map(\.sortOrder).max() ?? -1) + 1,
            matchMode: matchMode,
            conditions: conditions,
            actions: actions,
            stopAfterMatch: stopAfterMatch,
            createdAtEpoch: nowEpoch,
            updatedAtEpoch: nowEpoch
        )
        try validateRule(rule)
        var copy = self
        copy.setAutomationRule(rule)
        copy.recordAudit(entityType: "rule", entityID: rule.id.description, eventKind: "ruleCreated", nowEpoch: nowEpoch)
        try copy.bumpRevision()
        self = copy
        return rule.id
    }

    /// Replaces a rule's editable fields; identity, order, and creation time
    /// are kept.
    public mutating func updateRule(_ updated: AutomationRule, nowEpoch: Int64) throws {
        guard let existing = automationRules[updated.id] else { throw MutationError.entityNotFound }
        var rule = updated
        rule.budgetID = existing.budgetID
        rule.sortOrder = existing.sortOrder
        rule.createdAtEpoch = existing.createdAtEpoch
        rule.updatedAtEpoch = nowEpoch
        rule.name = rule.name.trimmingCharacters(in: .whitespacesAndNewlines)
        try validateRule(rule)
        var copy = self
        copy.setAutomationRule(rule)
        copy.recordAudit(entityType: "rule", entityID: rule.id.description, eventKind: "ruleUpdated", nowEpoch: nowEpoch)
        try copy.bumpRevision()
        self = copy
    }

    public mutating func setRuleEnabled(_ id: AutomationRuleID, enabled: Bool, nowEpoch: Int64) throws {
        guard var rule = automationRules[id] else { throw MutationError.entityNotFound }
        guard rule.enabled != enabled else { return }
        rule.enabled = enabled
        rule.updatedAtEpoch = nowEpoch
        var copy = self
        copy.setAutomationRule(rule)
        try copy.bumpRevision()
        self = copy
    }

    /// Rules are configuration, not ledger; deleting one is permitted and
    /// audited. Past applications remain in the audit trail.
    public mutating func deleteRule(_ id: AutomationRuleID, nowEpoch: Int64) throws {
        guard automationRules[id] != nil else { throw MutationError.entityNotFound }
        var copy = self
        copy.removeAutomationRule(id)
        copy.recordAudit(entityType: "rule", entityID: id.description, eventKind: "ruleDeleted", nowEpoch: nowEpoch)
        try copy.bumpRevision()
        self = copy
    }

    /// Reorders rules to the given id sequence (missing ids keep their
    /// relative order after the listed ones).
    public mutating func reorderRules(_ orderedIDs: [AutomationRuleID], nowEpoch: Int64) throws {
        var copy = self
        var next = 0
        var seen = Set<AutomationRuleID>()
        for id in orderedIDs {
            guard var rule = copy.automationRules[id], seen.insert(id).inserted else { throw MutationError.entityNotFound }
            rule.sortOrder = next
            next += 1
            copy.setAutomationRule(rule)
        }
        for rule in copy.automationRules.values.sorted(by: { ($0.sortOrder, $0.id) < ($1.sortOrder, $1.id) })
        where !seen.contains(rule.id) {
            var moved = rule
            moved.sortOrder = next
            next += 1
            copy.setAutomationRule(moved)
        }
        try copy.bumpRevision()
        self = copy
    }

    // MARK: - Evaluation helpers

    var ruleContext: RuleContext {
        RuleContext(
            categories: categories,
            accounts: accounts,
            budgetCurrency: budget.currency,
            rtaCategoryID: rtaCategoryID,
            uncategorizedID: uncategorizedID
        )
    }

    func ruleSubject(for row: TransactionRow) -> RuleSubject {
        RuleSubject(
            importedDescription: row.importedDescription,
            payeeDisplayName: row.payeeID.flatMap { payees[$0]?.displayName },
            memo: row.memo,
            accountID: row.accountID,
            amountMilliunits: row.amountMilliunits,
            date: row.date,
            sourceKind: row.sourceKind,
            categoryID: row.categoryID,
            isSplit: row.splits != nil
        )
    }

    /// Rows a rule pass may touch at all (D4.3): live, unreconciled, not a
    /// transfer leg, not staged, not system, not in a closed month.
    func ruleEligible(_ row: TransactionRow) -> Bool {
        row.postingState != .voided && row.postingState != .staged
            && row.cleared != .reconciled && !reconciliationMembership.contains(row.id)
            && row.transferPairID == nil && row.sourceKind != .system
            && row.kind == .normal
            && !isMonthClosed(row.date.budgetMonth)
    }

    /// Evaluates the enabled rules against one row and returns the proposal
    /// (pure; no state change).
    public func evaluateRules(for transactionID: TransactionID, ruleIDs: Set<AutomationRuleID>? = nil) -> RuleProposal? {
        guard let row = transactions[transactionID], ruleEligible(row) else { return nil }
        let rules = automationRules.values.filter { ruleIDs?.contains($0.id) ?? true }
        let proposal = RuleEngine.evaluate(rules: Array(rules), subject: ruleSubject(for: row), context: ruleContext)
        return proposal.isEmpty && proposal.skipped.isEmpty ? nil : proposal
    }

    /// Applies a proposal to a row in place (no replay; the caller replays).
    /// Category/split proposals were validated by the engine against the
    /// same matrix `validateCategoryChoice` enforces; re-check anyway so a
    /// stale rule can never write an invalid row.
    mutating func applyRuleProposal(_ proposal: RuleProposal, to row: inout TransactionRow, nowEpoch: Int64) throws -> Bool {
        var changed = false
        if let name = proposal.payeeName {
            let payeeID = findOrCreateUserPayee(named: name)
            if row.payeeID != payeeID { row.payeeID = payeeID; changed = true }
        }
        if let components = proposal.splits, let account = accounts[row.accountID] {
            try validateSplitComponents(components, account: account, amount: row.amountMilliunits)
            if row.splits != components {
                row.splits = components
                row.categoryID = nil
                row.postingState = components.contains { $0.categoryID == uncategorizedID } ? .needsCategory : .posted
                changed = true
            }
        } else if let categoryID = proposal.categoryID, let account = accounts[row.accountID] {
            try validateCategoryChoice(
                account: account, kind: row.kind, amount: row.amountMilliunits,
                categoryID: categoryID, refundOf: row.refundOfTransactionID
            )
            if row.categoryID != categoryID || row.splits != nil {
                row.splits = nil
                row.categoryID = categoryID
                if row.postingState == .needsCategory { row.postingState = .posted }
                changed = true
            }
        }
        if let memo = proposal.memo, row.memo != memo { row.memo = memo; changed = true }
        if let flag = proposal.flagColor, row.flagColor != flag { row.flagColor = flag; changed = true }
        if let approved = proposal.approved, row.approved != approved { row.approved = approved; changed = true }
        if changed {
            recordAudit(
                entityType: "transaction", entityID: row.id.description, eventKind: "ruleApplied",
                metadata: [
                    "rules": proposal.appliedRuleIDs.map(\.description).joined(separator: ","),
                    "ruleNames": proposal.appliedRuleIDs.compactMap { automationRules[$0]?.name }.joined(separator: " → ")
                ],
                nowEpoch: nowEpoch
            )
        }
        return changed
    }

    /// Automatic pass at import materialization (D4.3): returns the row with
    /// rule outcomes applied. Category defaults (payee learning, sign default)
    /// fill anything the rules left unset.
    mutating func applyImportRules(to row: inout TransactionRow, nowEpoch: Int64) throws {
        guard !automationRules.isEmpty, ruleEligible(row) else { return }
        let proposal = RuleEngine.evaluate(
            rules: Array(automationRules.values), subject: ruleSubject(for: row), context: ruleContext
        )
        guard !proposal.isEmpty else { return }
        _ = try applyRuleProposal(proposal, to: &row, nowEpoch: nowEpoch)
    }

    // MARK: - Retroactive application (D4.3)

    private func rowsInScope(_ scope: RuleApplicationScope) -> [TransactionRow] {
        transactions.values
            .filter { row in
                guard ruleEligible(row) else { return false }
                if let accountID = scope.accountID, row.accountID != accountID { return false }
                if let range = scope.dateRange, !range.contains(row.date) { return false }
                if !scope.overwriteUserEdits, row.userEditedAtEpoch != nil { return false }
                if !scope.includeCategorized, row.postingState != .needsCategory { return false }
                return true
            }
            .sorted { ($0.date, $0.sourceOrderKey, $0.id) < ($1.date, $1.sourceOrderKey, $1.id) }
    }

    public func previewRules(scope: RuleApplicationScope) -> [RulePreviewItem] {
        let rules = Array(automationRules.values.filter { scope.ruleIDs?.contains($0.id) ?? true })
        guard !rules.isEmpty else { return [] }
        let context = ruleContext
        return rowsInScope(scope).compactMap { row in
            let proposal = RuleEngine.evaluate(rules: rules, subject: ruleSubject(for: row), context: context)
            guard !proposal.isEmpty else { return nil }
            // Drop no-op proposals so the preview lists only real changes.
            var candidate = row
            var scratch = self
            let changed = (try? scratch.applyRuleProposal(proposal, to: &candidate, nowEpoch: 0)) ?? false
            return changed ? RulePreviewItem(transactionID: row.id, proposal: proposal) : nil
        }
    }

    @discardableResult
    public mutating func applyRules(scope: RuleApplicationScope, nowEpoch: Int64) throws -> RuleApplicationSummary {
        let rules = Array(automationRules.values.filter { scope.ruleIDs?.contains($0.id) ?? true })
        let rows = rowsInScope(scope)
        guard !rules.isEmpty, !rows.isEmpty else {
            return RuleApplicationSummary(consideredRows: rows.count, changedRows: 0, skippedActions: 0)
        }
        var copy = self
        var changedRows = 0
        var skipped = 0
        let context = ruleContext
        for row in rows {
            let proposal = RuleEngine.evaluate(rules: rules, subject: copy.ruleSubject(for: row), context: context)
            skipped += proposal.skipped.count
            guard !proposal.isEmpty, var updated = copy.transactions[row.id] else { continue }
            if try copy.applyRuleProposal(proposal, to: &updated, nowEpoch: nowEpoch) {
                updated.userEditedAtEpoch = nowEpoch
                copy.setTransaction(updated)
                // Dependent refunds follow a changed origin category (§3.5.3).
                if updated.categoryID != row.categoryID || updated.splits != row.splits {
                    for (_, var dependent) in copy.transactions
                    where dependent.refundOfTransactionID == updated.id && dependent.postingState != .voided {
                        if updated.splits != nil { continue } // replay stages unaddressed refunds
                        dependent.refundOfComponentIndex = nil
                        if dependent.postingState == .staged {
                            var meta = dependent.stageMetadata ?? StageMetadata()
                            meta.proposedCategoryID = updated.categoryID
                            dependent.stageMetadata = meta
                        } else {
                            dependent.categoryID = updated.categoryID
                        }
                        copy.setTransaction(dependent)
                    }
                }
                changedRows += 1
            }
        }
        guard changedRows > 0 else {
            return RuleApplicationSummary(consideredRows: rows.count, changedRows: 0, skippedActions: skipped)
        }
        try copy.runReplayAndApplyDecisions()
        copy.recordAudit(
            entityType: "rule", entityID: "batch", eventKind: "rulesAppliedRetroactively",
            metadata: ["changedRows": String(changedRows), "consideredRows": String(rows.count)],
            nowEpoch: nowEpoch
        )
        try copy.bumpRevision()
        self = copy
        return RuleApplicationSummary(consideredRows: rows.count, changedRows: changedRows, skippedActions: skipped)
    }

    /// Latest rule application recorded for a row, for "why did this change?".
    public func lastRuleApplication(for transactionID: TransactionID) -> AuditEventRow? {
        auditEvents.last { $0.entityType == "transaction" && $0.entityID == transactionID.description && $0.eventKind == "ruleApplied" }
    }
}

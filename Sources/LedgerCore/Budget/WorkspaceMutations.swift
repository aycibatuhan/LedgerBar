import Foundation

/// Result of `closeAccountVoidingHistory`: how many rows were soft-voided
/// (imported, identity retained) versus physically removed (manual/system).
public struct AccountCloseSummary: Sendable, Equatable {
    public let voidedImportedRows: Int
    public let removedLocalRows: Int
}

public enum MoveMoneyEndpoint: Sendable, Equatable {
    /// RTA is a sentinel endpoint, never an allocation row.
    case rta
    case category(CategoryID)
}

/// Result of a §3.9 reconciliation completion.
public struct ReconciliationOutcome: Sendable, Equatable {
    public var clearedBalanceMilliunits: Milliunits
    public var differenceMilliunits: Milliunits
    public var adjustmentTransactionID: TransactionID?
    public var newlyReconciledCount: Int

    public init(
        clearedBalanceMilliunits: Milliunits,
        differenceMilliunits: Milliunits,
        adjustmentTransactionID: TransactionID?,
        newlyReconciledCount: Int
    ) {
        self.clearedBalanceMilliunits = clearedBalanceMilliunits
        self.differenceMilliunits = differenceMilliunits
        self.adjustmentTransactionID = adjustmentTransactionID
        self.newlyReconciledCount = newlyReconciledCount
    }
}

extension BudgetWorkspace {

    // MARK: - Accounts (§2.2, §4.4 opening rules)

    /// Adds an account with its opening-balance transaction. Opening rules:
    /// on-budget cash-like → signed inflow to RTA (a negative opening is an
    /// overdraft that reduces RTA, which §3.3 already permits to be negative);
    /// card negative → pre-existing debt, no category; card positive →
    /// rejected (`positiveCardSnapshot` is a link pause in sync, a hard
    /// rejection for local creation); off-budget → register-only either sign.
    @discardableResult
    public mutating func addAccount(
        name: String,
        type: AccountType,
        onBudget: Bool,
        currency: String? = nil,
        openingBalance: Milliunits = 0,
        openingDate: BudgetDate,
        nowEpoch: Int64
    ) throws -> AccountID {
        guard !(type == .other && onBudget) else { throw MutationError.categoryNotAllowed }
        let accountCurrency = currency ?? budget.currency
        let eligible = onBudget && accountCurrency == budget.currency
        if eligible, type == .creditCard, openingBalance > 0 {
            throw MutationError.positiveCardOpeningBalance
        }
        guard openingDate.budgetMonth >= budget.firstMonth else { throw MutationError.dateBeforeFirstMonth }
        guard openingDate.budgetMonth <= currentMonth else { throw MutationError.futureDatedTransaction }
        guard !isMonthClosed(openingDate.budgetMonth) else { throw MutationError.closedMonth }

        var copy = self
        let account = AccountRow(
            budgetID: budget.id, name: name, type: type, onBudget: onBudget,
            currency: accountCurrency, createdAtEpoch: nowEpoch
        )
        copy.setAccount(account)

        if type == .creditCard {
            try copy.ensurePaymentCategory(forCard: account)
        }

        if openingBalance != 0 {
            let seq = try copy.allocateSourceSequence()
            let categoryID: CategoryID? = (eligible && type.isCashLike) ? rtaCategoryID : nil
            let row = TransactionRow(
                budgetID: budget.id,
                accountID: account.id,
                payeeID: systemPayeeID(.openingBalance),
                sourceKind: .system,
                date: openingDate,
                effectiveAtEpoch: try calendar.noonEpoch(of: openingDate),
                sourceOrderKey: .system(sequence: seq, systemKind: "openingBalance"),
                amountMilliunits: openingBalance,
                cleared: .cleared,
                approved: true,
                postingState: .posted,
                categoryID: categoryID,
                kind: .openingBalance
            )
            copy.setTransaction(row)
        }
        try copy.runReplayAndApplyDecisions()
        try copy.bumpRevision()
        self = copy
        return account.id
    }

    /// Renames an account. Names are trimmed, non-empty, and unique
    /// (case-insensitive) among open accounts; closed accounts keep their
    /// historical name out of the uniqueness check. A credit card's payment
    /// category name is derived from the card, so it is renamed atomically.
    public mutating func renameAccount(_ id: AccountID, to name: String, nowEpoch: Int64) throws {
        guard var account = accounts[id] else { throw MutationError.accountNotFound }
        guard !account.closed else { throw MutationError.accountClosed }
        let trimmed = try validatedEntityName(name)
        let duplicate = accounts.values.contains {
            $0.id != id && !$0.closed
                && $0.name.compare(trimmed, options: .caseInsensitive) == .orderedSame
        }
        guard !duplicate else { throw MutationError.duplicateName }
        guard account.name != trimmed else { return }

        var copy = self
        account.name = trimmed
        copy.setAccount(account)
        if account.type == .creditCard,
           let paymentID = copy.paymentCategoryID(forCard: id),
           var payment = copy.categories[paymentID] {
            payment.name = "Payment: \(trimmed)"
            copy.setCategory(payment)
        }
        copy.recordAudit(
            entityType: "account",
            entityID: id.description,
            eventKind: "accountRenamed",
            nowEpoch: nowEpoch
        )
        try copy.bumpRevision()
        self = copy
    }

    /// Explicit destructive close for a duplicate or mistaken account: every
    /// non-voided row on the account is soft-voided (imported rows keep their
    /// import identity, so a later sync cannot resurrect them) or removed
    /// (manual and system rows, which have no remote identity), then the
    /// account is closed. Register and projection effects of the rows vanish
    /// with them; the audit trail records each row and the close. Rows in a
    /// closed month, reconciled rows, transfer-pair legs (the counterparty
    /// belongs to another account), and rows with live refund dependents on
    /// other accounts block the operation so nothing outside this account is
    /// changed implicitly.
    @discardableResult
    public mutating func closeAccountVoidingHistory(
        accountID: AccountID,
        nowEpoch: Int64
    ) throws -> AccountCloseSummary {
        guard let account = accounts[accountID] else { throw MutationError.accountNotFound }
        guard !account.closed else { throw MutationError.accountClosed }
        let rows = transactions.values
            .filter { $0.accountID == accountID && $0.postingState != .voided }
            .sorted { $0.id.description < $1.id.description }
        let ownIDs = Set(rows.map(\.id))
        for row in rows {
            guard !isMonthClosed(row.date.budgetMonth) else { throw MutationError.closedMonth }
            guard row.cleared != .reconciled, !reconciliationMembership.contains(row.id) else {
                throw MutationError.reconciledTransaction
            }
            guard row.transferPairID == nil else { throw MutationError.accountHasTransferPairs }
            let foreignDependents = transactions.values.contains {
                $0.refundOfTransactionID == row.id && $0.postingState != .voided && !ownIDs.contains($0.id)
            }
            guard !foreignDependents else { throw MutationError.transactionHasDependents }
        }

        var copy = self
        var voided = 0
        var removed = 0
        for row in rows {
            if row.sourceKind == .simplefin || row.sourceKind == .file {
                var voidedRow = row
                voidedRow.postingState = .voided
                voidedRow.stageReason = nil
                copy.setTransaction(voidedRow)
                copy.recordAudit(entityType: "transaction", entityID: row.id.description, eventKind: "softVoid", nowEpoch: nowEpoch)
                voided += 1
            } else {
                copy.removeTransaction(row.id)
                copy.recordAudit(entityType: "transaction", entityID: row.id.description, eventKind: "delete", nowEpoch: nowEpoch)
                removed += 1
            }
        }
        var closed = account
        closed.closed = true
        copy.setAccount(closed)
        // Review items for this account can no longer be decided once its
        // rows are voided and it is closed; settle them here so none strand.
        copy.settleOpenReviewItems(forClosedAccount: accountID, nowEpoch: nowEpoch)
        try copy.runReplayAndApplyDecisions()
        copy.recordAudit(
            entityType: "account",
            entityID: accountID.description,
            eventKind: "accountClosedVoidingHistory",
            metadata: ["voidedImportedRows": "\(voided)", "removedLocalRows": "\(removed)"],
            nowEpoch: nowEpoch
        )
        try copy.bumpRevision()
        self = copy
        return AccountCloseSummary(voidedImportedRows: voided, removedLocalRows: removed)
    }

    /// Closes an account only when its register is settled and no workflow
    /// rows still require a user decision. The account row and its history are
    /// retained; closed accounts simply stop participating in projection.
    public mutating func closeAccount(accountID: AccountID, nowEpoch: Int64) throws {
        guard let account = accounts[accountID] else { throw MutationError.accountNotFound }
        guard !account.closed else { throw MutationError.accountClosed }

        var registerBalance: Milliunits = 0
        var hasPendingWorkflow = false
        for row in transactions.values where row.accountID == accountID && row.postingState != .voided {
            let sum = registerBalance.addingReportingOverflow(row.amountMilliunits)
            guard !sum.overflow else { throw MutationError.arithmeticOverflow }
            registerBalance = sum.partialValue
            hasPendingWorkflow = hasPendingWorkflow
                || row.postingState == .staged
                || row.postingState == .needsCategory
        }
        guard registerBalance == 0, !hasPendingWorkflow else {
            throw MutationError.accountHasActivity
        }

        var copy = self
        var closed = account
        closed.closed = true
        copy.setAccount(closed)
        copy.settleOpenReviewItems(forClosedAccount: accountID, nowEpoch: nowEpoch)
        try copy.runReplayAndApplyDecisions()
        copy.recordAudit(
            entityType: "account",
            entityID: accountID.description,
            eventKind: "accountClosed",
            nowEpoch: nowEpoch
        )
        try copy.bumpRevision()
        self = copy
    }

    mutating func ensurePaymentCategory(forCard account: AccountRow) throws {
        guard paymentCategoryID(forCard: account.id) == nil else { return }
        let groupID: CategoryGroupID
        if let existing = creditCardPaymentsGroupID {
            groupID = existing
        } else {
            let group = CategoryGroupRow(
                budgetID: budget.id, name: "Credit Card Payments",
                sortOrder: categoryGroups.values.map(\.sortOrder).max().map { $0 + 1 } ?? 0
            )
            setCategoryGroup(group)
            setCreditCardPaymentsGroupID(group.id)
            groupID = group.id
        }
        let payment = CategoryRow(
            budgetID: budget.id, groupID: groupID, name: "Payment: \(account.name)",
            sortOrder: categories.values.filter { $0.groupID == groupID }.count,
            kind: .ccPayment, linkedAccountID: account.id
        )
        setCategory(payment)
    }

    // MARK: - Category management

    /// Trimmed, non-empty user-entered name for categories and groups.
    private func validatedEntityName(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MutationError.nameEmpty }
        return trimmed
    }

    /// Uniqueness is case-insensitive against visible rows only: hide is an
    /// archive, and an archived name must stay reusable (unhide re-checks).
    private func hasVisibleGroupNamed(_ name: String, excluding excluded: CategoryGroupID? = nil) -> Bool {
        categoryGroups.values.contains {
            $0.id != excluded && !$0.hidden
                && $0.name.compare(name, options: .caseInsensitive) == .orderedSame
        }
    }

    private func hasVisibleCategoryNamed(
        _ name: String, inGroup groupID: CategoryGroupID, excluding excluded: CategoryID? = nil
    ) -> Bool {
        categories.values.contains {
            $0.id != excluded && !$0.hidden && $0.groupID == groupID
                && $0.name.compare(name, options: .caseInsensitive) == .orderedSame
        }
    }

    @discardableResult
    public mutating func addCategoryGroup(name: String) throws -> CategoryGroupID {
        let trimmed = try validatedEntityName(name)
        guard !hasVisibleGroupNamed(trimmed) else { throw MutationError.duplicateName }
        var copy = self
        let group = CategoryGroupRow(
            budgetID: budget.id, name: trimmed,
            sortOrder: categoryGroups.values.map(\.sortOrder).max().map { $0 + 1 } ?? 0
        )
        copy.setCategoryGroup(group)
        try copy.bumpRevision()
        self = copy
        return group.id
    }

    @discardableResult
    public mutating func addCategory(groupID: CategoryGroupID, name: String) throws -> CategoryID {
        guard categoryGroups[groupID] != nil else { throw MutationError.entityNotFound }
        guard groupID != creditCardPaymentsGroupID else { throw MutationError.categoryNotAllowed }
        let trimmed = try validatedEntityName(name)
        guard !hasVisibleCategoryNamed(trimmed, inGroup: groupID) else {
            throw MutationError.duplicateName
        }
        var copy = self
        let category = CategoryRow(
            budgetID: budget.id, groupID: groupID, name: trimmed,
            sortOrder: categories.values.filter { $0.groupID == groupID }.count,
            kind: .spending // user-created categories are spending-only in v1
        )
        copy.setCategory(category)
        try copy.bumpRevision()
        self = copy
        return category.id
    }

    /// Renames a user spending category. System categories are immutable, and
    /// a card payment category's name is derived from its card account.
    public mutating func renameCategory(_ id: CategoryID, to name: String) throws {
        guard var category = categories[id] else { throw MutationError.entityNotFound }
        guard category.systemKind == nil, category.kind != .ccPayment else {
            throw MutationError.systemEntityImmutable
        }
        let trimmed = try validatedEntityName(name)
        guard !hasVisibleCategoryNamed(trimmed, inGroup: category.groupID, excluding: id) else {
            throw MutationError.duplicateName
        }
        var copy = self
        category.name = trimmed
        copy.setCategory(category)
        try copy.bumpRevision()
        self = copy
    }

    /// Renames a user category group; the Credit Card Payments group is
    /// system-managed.
    public mutating func renameCategoryGroup(_ id: CategoryGroupID, to name: String) throws {
        guard var group = categoryGroups[id] else { throw MutationError.entityNotFound }
        guard id != creditCardPaymentsGroupID else { throw MutationError.systemEntityImmutable }
        let trimmed = try validatedEntityName(name)
        guard !hasVisibleGroupNamed(trimmed, excluding: id) else { throw MutationError.duplicateName }
        var copy = self
        group.name = trimmed
        copy.setCategoryGroup(group)
        try copy.bumpRevision()
        self = copy
    }

    /// Hide/archive (physical deletion is never used). A category with
    /// positive available must be emptied via moveMoney first.
    public mutating func hideCategory(_ id: CategoryID) throws {
        guard var category = categories[id] else { throw MutationError.entityNotFound }
        guard category.systemKind == nil else { throw MutationError.systemEntityImmutable }
        let result = try projection(through: currentMonth)
        let available = result.month(currentMonth)?.categories[id]?.available
            ?? result.month(currentMonth)?.payments[id]?.available ?? 0
        guard available <= 0 else { throw MutationError.categoryHasAvailable }
        var copy = self
        category.hidden = true
        copy.setCategory(category)
        try copy.bumpRevision()
        self = copy
    }

    /// Un-archives a hidden category. Because hide keeps the name reusable,
    /// unhide is refused while a visible sibling now holds the same name.
    /// Unhiding an already-visible category is a no-op.
    public mutating func unhideCategory(_ id: CategoryID) throws {
        guard var category = categories[id] else { throw MutationError.entityNotFound }
        guard category.systemKind == nil else { throw MutationError.systemEntityImmutable }
        guard category.hidden else { return }
        guard !hasVisibleCategoryNamed(category.name, inGroup: category.groupID, excluding: id) else {
            throw MutationError.duplicateName
        }
        var copy = self
        category.hidden = false
        copy.setCategory(category)
        try copy.bumpRevision()
        self = copy
    }

    // MARK: - Allocation primitives (§3.3)

    /// Sets a single category's assignment for the current month to a
    /// non-negative value. May over-assign (RTAEnd goes negative, shown red).
    public mutating func setBudgeted(categoryID: CategoryID, month: BudgetMonth, value: Milliunits) throws {
        guard value >= 0 else { throw MutationError.negativeSetBudgeted }
        guard month == currentMonth, !isMonthClosed(month) else { throw MutationError.allocationMonthNotCurrent }
        guard let category = categories[categoryID] else { throw MutationError.entityNotFound }
        guard categoryID != rtaCategoryID, categoryID != uncategorizedID else {
            throw MutationError.allocationTargetNotAllowed
        }
        guard category.kind == .spending || category.kind == .ccPayment else {
            throw MutationError.allocationTargetNotAllowed
        }
        var copy = self
        copy.setAllocation(AllocationRow(
            budgetID: budget.id, categoryID: categoryID, month: month, budgetedMilliunits: value
        ))
        try copy.runReplayAndApplyDecisions()
        try copy.bumpRevision()
        self = copy
    }

    /// Atomic move between two envelopes or between RTA and one envelope.
    /// A negative stored allocation row is legal only as the audited result of
    /// the category→category or category→RTA forms.
    public mutating func moveMoney(
        source: MoveMoneyEndpoint,
        destination: MoveMoneyEndpoint,
        amount: Milliunits,
        month: BudgetMonth,
        nowEpoch: Int64
    ) throws {
        guard amount > 0 else { throw MutationError.moveMoneyAmountNotPositive }
        guard month == currentMonth, !isMonthClosed(month) else { throw MutationError.allocationMonthNotCurrent }

        func validCategory(_ id: CategoryID) throws -> CategoryRow {
            guard let c = categories[id] else { throw MutationError.entityNotFound }
            guard id != rtaCategoryID else { throw MutationError.moveMoneyCategoryNotEligible }
            guard id != uncategorizedID else { throw MutationError.moveMoneyCategoryNotEligible }
            guard c.kind == .spending || c.kind == .ccPayment else {
                throw MutationError.moveMoneyCategoryNotEligible
            }
            return c
        }

        let result = try projection(through: month)
        guard let snapshot = result.month(month) else { throw MutationError.entityNotFound }

        func currentAvailable(_ id: CategoryID) -> Milliunits {
            snapshot.categories[id]?.available ?? snapshot.payments[id]?.available ?? 0
        }
        func currentBudgeted(_ id: CategoryID) -> Milliunits {
            allocations[AllocationKey(categoryID: id, month: month)]?.budgetedMilliunits ?? 0
        }

        var copy = self
        switch (source, destination) {
        case (.rta, .rta):
            throw MutationError.moveMoneySameCategory

        case let (.category(src), .category(dst)):
            guard src != dst else { throw MutationError.moveMoneySameCategory }
            _ = try validCategory(src)
            _ = try validCategory(dst)
            let sourceAvailable = max(0, currentAvailable(src))
            guard amount <= sourceAvailable else { throw MutationError.moveMoneySourceUnavailable }
            copy.setAllocation(AllocationRow(
                budgetID: budget.id, categoryID: src, month: month,
                budgetedMilliunits: try subChecked(currentBudgeted(src), amount)
            ))
            copy.setAllocation(AllocationRow(
                budgetID: budget.id, categoryID: dst, month: month,
                budgetedMilliunits: try addChecked(currentBudgeted(dst), amount)
            ))
            copy.recordAudit(
                entityType: "allocation", entityID: dst.description, eventKind: "moveMoney",
                metadata: ["source": src.description, "destination": dst.description, "amount": String(amount)],
                nowEpoch: nowEpoch
            )

        case let (.rta, .category(dst)):
            _ = try validCategory(dst)
            guard amount <= snapshot.rtaEnd else { throw MutationError.moveMoneyRTAUnavailable }
            copy.setAllocation(AllocationRow(
                budgetID: budget.id, categoryID: dst, month: month,
                budgetedMilliunits: try addChecked(currentBudgeted(dst), amount)
            ))
            copy.recordAudit(
                entityType: "allocation", entityID: dst.description, eventKind: "moveMoney",
                metadata: ["source": "RTA", "destination": dst.description, "amount": String(amount)],
                nowEpoch: nowEpoch
            )

        case let (.category(src), .rta):
            _ = try validCategory(src)
            let sourceAvailable = max(0, currentAvailable(src))
            guard amount <= sourceAvailable else { throw MutationError.moveMoneySourceUnavailable }
            copy.setAllocation(AllocationRow(
                budgetID: budget.id, categoryID: src, month: month,
                budgetedMilliunits: try subChecked(currentBudgeted(src), amount)
            ))
            copy.recordAudit(
                entityType: "allocation", entityID: src.description, eventKind: "moveMoney",
                metadata: ["source": src.description, "destination": "RTA", "amount": String(amount)],
                nowEpoch: nowEpoch
            )
        }
        try copy.runReplayAndApplyDecisions()
        try copy.bumpRevision()
        self = copy
    }

    // MARK: - Payees

    mutating func findOrCreateUserPayee(named raw: String) -> PayeeID {
        let normalized = BudgetWorkspace.normalizePayeeName(raw)
        if let existing = payees.values.first(where: { $0.namespace == .user && $0.name == normalized }) {
            return existing.id
        }
        let payee = PayeeRow(
            budgetID: budget.id, namespace: .user, name: normalized, displayName: raw
        )
        setPayee(payee)
        return payee.id
    }

    /// Payee learning (§4.3): only for explicit categorization of a normal
    /// transaction to a visible, non-system, sign-eligible category; system
    /// payees are excluded.
    mutating func updatePayeeLearning(payeeID: PayeeID?, categoryID: CategoryID, amount: Milliunits) {
        guard let payeeID, var payee = payees[payeeID], payee.systemKind == nil else { return }
        guard let category = categories[categoryID], !category.hidden, category.systemKind == nil else { return }
        let signEligible = amount > 0 ? category.kind == .inflow : category.kind == .spending
        guard signEligible, category.kind != .ccPayment else { return }
        payee.lastUsedCategoryID = categoryID
        setPayee(payee)
    }

    // MARK: - Manual transactions

    /// Category/sign matrix pre-validation shared by insert and edit paths.
    func validateCategoryChoice(
        account: AccountRow,
        kind: TransactionKind,
        amount: Milliunits,
        categoryID: CategoryID?,
        refundOf: TransactionID?,
        refundOfComponentIndex: Int? = nil
    ) throws {
        let eligible = budgetEligible(account, budgetCurrency: budget.currency)
        if !eligible {
            guard categoryID == nil else { throw MutationError.categoryNotAllowed }
            return
        }
        switch kind {
        case .normal:
            if account.type == .creditCard {
                if amount > 0 { throw MutationError.categoryNotAllowed } // must be refund/payment/adjustment
                guard let id = categoryID, let c = categories[id], c.kind == .spending, id != uncategorizedID else {
                    throw MutationError.categoryRequired
                }
            } else if amount > 0 {
                guard categoryID == rtaCategoryID else { throw MutationError.categoryNotAllowed }
            } else {
                guard let id = categoryID, let c = categories[id], c.kind == .spending, id != uncategorizedID else {
                    throw MutationError.categoryRequired
                }
            }
        case .refund:
            guard amount > 0 else { throw MutationError.refundNotPositive }
            guard let id = categoryID, let c = categories[id], c.kind == .spending, id != uncategorizedID else {
                throw MutationError.categoryRequired
            }
            if account.type == .creditCard {
                guard let originID = refundOf, let origin = transactions[originID],
                      origin.postingState != .voided,
                      origin.accountID == account.id,
                      origin.amountMilliunits < 0,
                      origin.kind == .normal
                else { throw MutationError.refundOriginInvalid }
                // A split origin is refunded per component (D3.3).
                if let components = origin.splits {
                    guard let index = refundOfComponentIndex, components.indices.contains(index),
                          components[index].categoryID == id
                    else { throw MutationError.refundOriginInvalid }
                } else {
                    guard refundOfComponentIndex == nil else { throw MutationError.refundOriginInvalid }
                }
            }
        case .openingBalance, .adjustment:
            throw MutationError.categoryNotAllowed // system-created only
        }
    }

    @discardableResult
    public mutating func addManualTransaction(
        accountID: AccountID,
        date: BudgetDate,
        payeeName: String,
        categoryID: CategoryID?,
        amountMilliunits: Milliunits,
        memo: String? = nil,
        kind: TransactionKind = .normal,
        refundOf: TransactionID? = nil,
        refundOfComponentIndex: Int? = nil,
        splits: [SplitComponent]? = nil,
        nowEpoch: Int64
    ) throws -> TransactionID {
        guard let account = accounts[accountID] else { throw MutationError.accountNotFound }
        guard !account.closed else { throw MutationError.accountClosed }
        guard date.budgetMonth >= budget.firstMonth else { throw MutationError.dateBeforeFirstMonth }
        guard date.budgetMonth <= currentMonth else { throw MutationError.futureDatedTransaction }
        guard !isMonthClosed(date.budgetMonth) else { throw MutationError.closedMonth }
        if let splits {
            guard categoryID == nil, kind == .normal, refundOf == nil else { throw MutationError.splitNotAllowed }
            try validateSplitComponents(splits, account: account, amount: amountMilliunits)
        } else {
            try validateCategoryChoice(
                account: account, kind: kind, amount: amountMilliunits,
                categoryID: categoryID, refundOf: refundOf, refundOfComponentIndex: refundOfComponentIndex
            )
        }

        var copy = self
        let payeeID = copy.findOrCreateUserPayee(named: payeeName)
        let seq = try copy.allocateSourceSequence()
        let row = TransactionRow(
            budgetID: budget.id,
            accountID: accountID,
            payeeID: payeeID,
            sourceKind: .manual,
            date: date,
            effectiveAtEpoch: try calendar.noonEpoch(of: date),
            sourceOrderKey: .manual(sequence: seq),
            memo: memo,
            amountMilliunits: amountMilliunits,
            cleared: .uncleared,
            approved: true,
            postingState: .posted,
            categoryID: categoryID,
            refundOfTransactionID: refundOf,
            kind: kind,
            splits: splits,
            refundOfComponentIndex: refundOfComponentIndex
        )
        copy.setTransaction(row)
        let result = try copy.runReplayAndApplyDecisions()

        // A manual row that the deterministic pass would stage is rejected
        // before insertion — except the explicitly-persisted staged cash
        // reimbursement into a creditDebt category (§3.5.3).
        if let decision = result.postingDecisions[row.id], decision.postingState == .staged {
            switch decision.stageReason {
            case .cashInflowWithCreditDebt:
                break // persisted staged by design
            case .cardBalanceWouldBecomePositive:
                throw MutationError.cardBalanceWouldBecomePositive
            case .overRefund:
                throw MutationError.refundExceedsRemainingLot
            case .crossMonthRefund, .missingRefundOrigin:
                throw MutationError.refundOriginInvalid
            default:
                throw MutationError.categoryNotAllowed
            }
        }
        if kind == .normal, let categoryID {
            copy.updatePayeeLearning(payeeID: payeeID, categoryID: categoryID, amount: amountMilliunits)
        }
        if let today = calendar.budgetDate(fromEpoch: nowEpoch) {
            copy.matchSchedules(asOf: max(today, date), nowEpoch: nowEpoch)
        }
        try copy.bumpRevision()
        self = copy
        return row.id
    }

    // MARK: - Split transactions (D3)

    /// Split invariants: at least two components, every component nonzero with
    /// the parent's sign, an exact checked sum, and only spending categories
    /// (`Uncategorized` allowed — the row then stays `needsCategory`). Only a
    /// normal outflow on a budget-eligible account can be split.
    func validateSplitComponents(_ components: [SplitComponent], account: AccountRow, amount: Milliunits) throws {
        guard budgetEligible(account, budgetCurrency: budget.currency), amount < 0 else {
            throw MutationError.splitNotAllowed
        }
        guard components.count >= 2 else { throw MutationError.splitInvalid }
        var sum: Milliunits = 0
        for component in components {
            guard component.amountMilliunits < 0 else { throw MutationError.splitInvalid }
            guard let category = categories[component.categoryID], category.kind == .spending else {
                throw MutationError.categoryNotAllowed
            }
            sum = try addChecked(sum, component.amountMilliunits)
        }
        guard sum == amount else { throw MutationError.splitInvalid }
    }

    /// Replaces the row's category with component allocations (or replaces an
    /// existing split). Bank identity, amount, date, and payee are untouched.
    /// Linked refunds addressed to a component that still exists keep their
    /// materialized category in sync; refunds without a component address are
    /// re-staged by replay as `missingRefundOrigin` (§3.8 origin-edit rule).
    public mutating func setSplits(
        transactionID: TransactionID,
        components: [SplitComponent],
        nowEpoch: Int64
    ) throws {
        guard var row = transactions[transactionID], row.postingState != .voided else {
            throw MutationError.transactionNotFound
        }
        guard row.cleared != .reconciled, !reconciliationMembership.contains(transactionID) else {
            throw MutationError.reconciledTransaction
        }
        guard !isMonthClosed(row.date.budgetMonth) else { throw MutationError.closedMonth }
        guard row.postingState == .posted || row.postingState == .needsCategory else {
            throw MutationError.resolutionNotEligible
        }
        guard row.kind == .normal, row.transferPairID == nil, row.sourceKind != .system else {
            throw MutationError.splitNotAllowed
        }
        guard let account = accounts[row.accountID] else { throw MutationError.accountNotFound }
        try validateSplitComponents(components, account: account, amount: row.amountMilliunits)

        var copy = self
        row.splits = components
        row.categoryID = nil
        row.userEditedAtEpoch = nowEpoch
        row.postingState = components.contains { $0.categoryID == uncategorizedID } ? .needsCategory : .posted
        copy.setTransaction(row)
        for (_, var dependent) in copy.transactions
        where dependent.refundOfTransactionID == transactionID && dependent.postingState != .voided {
            guard let index = dependent.refundOfComponentIndex, components.indices.contains(index) else {
                continue // replay stages it (missingRefundOrigin)
            }
            if dependent.postingState == .staged {
                var meta = dependent.stageMetadata ?? StageMetadata()
                meta.proposedCategoryID = components[index].categoryID
                dependent.stageMetadata = meta
            } else {
                dependent.categoryID = components[index].categoryID
            }
            copy.setTransaction(dependent)
        }
        try copy.runReplayAndApplyDecisions()
        copy.recordAudit(
            entityType: "transaction", entityID: transactionID.description, eventKind: "split",
            metadata: ["components": String(components.count)], nowEpoch: nowEpoch
        )
        try copy.bumpRevision()
        self = copy
    }

    // MARK: - SimpleFIN import materialization (§4.3 steps 1–6, headless core)

    /// Composite-identity keys already imported (dedup). The persistence layer
    /// enforces this with a unique constraint; the workspace mirrors it.
    public func importedTransactionID(connectionKey: String, remoteAccountID: String, remoteTransactionID: String) -> TransactionID? {
        let key = SourceOrderKey.remote(
            connectionKey: connectionKey, accountID: remoteAccountID, transactionID: remoteTransactionID
        )
        return transactions.values.first { $0.sourceOrderKey == key }?.id
    }

    /// §4.3 steps 1/5/6 classification for an unclosed-month imported row:
    /// ineligible accounts stay register-only, positive card rows defer to the
    /// replay card guard, then exact-payee auto-categorization, then the sign
    /// default. The replay pass converts an `Uncategorized` result into
    /// `needsCategory` and stages guarded card rows.
    func importedRowCategory(account: AccountRow, payeeID: PayeeID, amountMilliunits: Milliunits) -> CategoryID? {
        guard budgetEligible(account, budgetCurrency: budget.currency) else { return nil }
        if account.type == .creditCard && amountMilliunits > 0 { return nil }
        if let learned = payees[payeeID]?.lastUsedCategoryID,
           let c = categories[learned], !c.hidden, c.kind != .ccPayment,
           c.systemKind == nil,
           (amountMilliunits > 0 ? c.kind == .inflow : c.kind == .spending) {
            return learned
        }
        return amountMilliunits > 0 ? rtaCategoryID : uncategorizedID
    }

    /// Shared materialization for every import source (docs/DESIGN.md D6.3):
    /// payee resolution, the closed-month append-only exception, exact-payee
    /// auto-categorization, the sign default, and the automation-rule pass.
    /// The caller has already validated the account and the date bounds and
    /// remains responsible for the source's identity record, replay, and
    /// revision. The row is inserted into `self` and returned.
    mutating func materializeImportedRow(
        accountID: AccountID,
        sourceKind: SourceKind,
        sourceOrderKey: SourceOrderKey,
        date: BudgetDate,
        effectiveAtEpoch: Int64,
        payeeName: String?,
        amountMilliunits: Milliunits,
        memo: String?,
        nowEpoch: Int64
    ) throws -> TransactionRow {
        guard let account = accounts[accountID] else { throw MutationError.accountNotFound }
        let payeeID = payeeName.map { findOrCreateUserPayee(named: $0) } ?? systemPayeeID(.unknown)
        let eligible = budgetEligible(account, budgetCurrency: budget.currency)

        var categoryID: CategoryID?
        var posting: PostingState = .posted
        var stageReason: StageReason?
        var stageMetadata: StageMetadata?

        if isMonthClosed(date.budgetMonth) {
            // Append-only closed-month exception: staged, never auto-resolved
            // while closed. Preserve the deterministic normal-path proposal in
            // sanitized metadata so reopening can restore the workflow without
            // inventing a category or silently posting the row.
            posting = .staged
            stageReason = .closedMonthImport
            if eligible {
                let learned = payees[payeeID]?.lastUsedCategoryID
                let proposed: CategoryID?
                if account.type == .creditCard && amountMilliunits > 0 {
                    proposed = nil // card inflows remain explicitly staged
                } else if let learned,
                          let learnedCategory = categories[learned],
                          !learnedCategory.hidden,
                          learnedCategory.kind != .ccPayment,
                          learnedCategory.systemKind == nil,
                          (amountMilliunits > 0 ? learnedCategory.kind == .inflow : learnedCategory.kind == .spending) {
                    proposed = learned
                } else if amountMilliunits > 0 {
                    proposed = rtaCategoryID
                } else {
                    proposed = uncategorizedID
                }
                stageMetadata = StageMetadata(proposedCategoryID: proposed)
            }
        } else {
            categoryID = importedRowCategory(account: account, payeeID: payeeID, amountMilliunits: amountMilliunits)
        }

        var row = TransactionRow(
            budgetID: budget.id,
            accountID: accountID,
            payeeID: payeeID,
            sourceKind: sourceKind,
            date: date,
            effectiveAtEpoch: effectiveAtEpoch,
            sourceOrderKey: sourceOrderKey,
            memo: memo,
            amountMilliunits: amountMilliunits,
            cleared: .uncleared,
            approved: false,
            postingState: posting,
            stageReason: stageReason,
            stageMetadata: stageMetadata,
            categoryID: categoryID,
            kind: .normal,
            importedDescription: payeeName
        )
        // Automation rules run once, at materialization: a rule category
        // replaces the default chosen above; a rule payee rename keeps the raw
        // `importedDescription` (D4.2/D4.3). Closed-month rows stay staged.
        if posting != .staged {
            try applyImportRules(to: &row, nowEpoch: nowEpoch)
        }
        setTransaction(row)
        return row
    }

    /// Materializes one normalized, sign-corrected posted remote row plus its
    /// `SimpleFINImport` record in the same mutation (§2.1: `source_kind ==
    /// .simplefin` iff an import record exists). Classification follows the
    /// ordered decision list: closed-month append, card guard (via replay),
    /// payee auto-categorization, then sign default. Returns the existing
    /// row's ID unchanged for a duplicate identity. The raw remote metadata
    /// parameters default from the normalized values when a caller has no raw
    /// payload (tests); the sync engine always passes the real raw values.
    @discardableResult
    public mutating func importPostedTransaction(
        accountID: AccountID,
        connectionKey: String,
        remoteAccountID: String,
        remoteTransactionID: String,
        postedEpoch: Int64,
        payeeName: String?,
        amountMilliunits: Milliunits,
        memo: String? = nil,
        remoteAmountDecimalString: String? = nil,
        remoteTransactedEpoch: Int64? = nil,
        remotePayloadHash: String? = nil,
        nowEpoch: Int64
    ) throws -> TransactionID {
        if let existing = importedTransactionID(
            connectionKey: connectionKey, remoteAccountID: remoteAccountID, remoteTransactionID: remoteTransactionID
        ) {
            return existing
        }
        guard let account = accounts[accountID] else { throw MutationError.accountNotFound }
        guard let date = calendar.budgetDate(fromEpoch: postedEpoch) else {
            throw MutationError.futureDatedTransaction
        }
        // Future posted date is a protocol anomaly: the sync layer pauses the
        // link; the workspace refuses the row.
        guard date.budgetMonth <= currentMonth else { throw MutationError.futureDatedTransaction }
        guard date.budgetMonth >= budget.firstMonth else { throw MutationError.dateBeforeFirstMonth }

        var copy = self
        let key = SourceOrderKey.remote(
            connectionKey: connectionKey, accountID: remoteAccountID, transactionID: remoteTransactionID
        )
        let row = try copy.materializeImportedRow(
            accountID: accountID,
            sourceKind: .simplefin,
            sourceOrderKey: key,
            date: date,
            effectiveAtEpoch: postedEpoch,
            payeeName: payeeName,
            amountMilliunits: amountMilliunits,
            memo: memo,
            nowEpoch: nowEpoch
        )

        // The import record commits with the row: last-seen raw metadata plus
        // the canonical payload hash used for §4.3 change detection.
        let rawAmount = remoteAmountDecimalString ?? MoneyParser.decimalString(fromMilliunits: amountMilliunits)
        let payloadHash: String
        if let remotePayloadHash {
            payloadHash = remotePayloadHash
        } else {
            payloadHash = try SimpleFINPayloadHash.canonicalHash(
                remoteTransactionID: remoteTransactionID,
                transaction: SimpleFINRemoteTransaction(
                    id: remoteTransactionID, amount: rawAmount, postedEpoch: postedEpoch,
                    transactedAtEpoch: remoteTransactedEpoch, description: memo,
                    payee: payeeName, pending: false
                )
            )
        }
        copy.setSimpleFINImport(SimpleFINImportRecord(
            budgetID: budget.id,
            transactionID: row.id,
            connectionKey: connectionKey,
            remoteAccountID: remoteAccountID,
            remoteTransactionID: remoteTransactionID,
            remoteAmountDecimalString: rawAmount,
            remotePostedEpoch: postedEpoch,
            remoteTransactedEpoch: remoteTransactedEpoch,
            remotePayloadHash: payloadHash,
            lastSeenEpoch: nowEpoch
        ))
        try copy.runReplayAndApplyDecisions()
        if let today = calendar.budgetDate(fromEpoch: nowEpoch) {
            copy.matchSchedules(asOf: max(today, date), nowEpoch: nowEpoch)
        }
        try copy.bumpRevision()
        self = copy
        return row.id
    }

    /// Finds pre-existing manual rows that have the same normalized account,
    /// budget date, and amount as an imported row. v1 never merges these rows;
    /// it records one explicit duplicate candidate per manual/import pair so
    /// the user can keep both, soft-void the import, or delete the manual row
    /// subject to the normal dependency/reconciliation guards (§4.3).
    @discardableResult
    mutating func recordManualPotentialDuplicateConflicts(
        for importedTransactionID: TransactionID,
        nowEpoch: Int64
    ) -> [SyncConflictID] {
        guard let imported = transactions[importedTransactionID],
              imported.sourceKind == .simplefin,
              imported.postingState != .voided,
              let importRecord = simpleFINImports[importedTransactionID],
              let importedAccount = accounts[imported.accountID],
              importedAccount.budgetID == budget.id else {
            return []
        }

        let candidates = transactions.values
            .filter { manual in
                manual.id != imported.id
                    && manual.budgetID == budget.id
                    && (manual.sourceKind == .manual || manual.sourceKind == .file)
                    && manual.postingState != .voided
                    && manual.accountID == imported.accountID
                    && manual.date == imported.date
                    && manual.amountMilliunits == imported.amountMilliunits
            }
            .sorted { $0.id < $1.id }

        var conflictIDs: [SyncConflictID] = []
        for manual in candidates {
            let oldMetadata = SyncConflictMetadata(
                amountDecimalString: MoneyParser.decimalString(fromMilliunits: manual.amountMilliunits),
                date: manual.date.description,
                payeeDisplay: manual.payeeID.flatMap { payees[$0]?.displayName },
                descriptionText: manual.memo,
                note: "Existing manual transaction candidate."
            )
            let newMetadata = SyncConflictMetadata(
                amountDecimalString: importRecord.remoteAmountDecimalString,
                postedEpoch: importRecord.remotePostedEpoch,
                transactedEpoch: importRecord.remoteTransactedEpoch,
                date: imported.date.description,
                payeeDisplay: imported.payeeID.flatMap { payees[$0]?.displayName },
                descriptionText: imported.memo,
                payloadHash: importRecord.remotePayloadHash,
                note: "New imported transaction candidate."
            )
            if let conflictID = recordSyncConflictIfNew(
                transactionID: manual.id,
                simpleFINImportID: importRecord.id,
                eventKind: .manualPotentialDuplicate,
                oldMetadata: oldMetadata,
                newMetadata: newMetadata,
                nowEpoch: nowEpoch
            ) {
                conflictIDs.append(conflictID)
            }
        }
        return conflictIDs
    }

    /// §4.3 changed-remote-row silent update: applies new remote values to a
    /// row that is untouched (`needsCategory`, never user-edited, unapproved,
    /// uncleared, unlinked, not a reconciliation member) in an unclosed month,
    /// re-running the import classification and replay exactly as if the row
    /// had been imported with the new values. Any other row must go through a
    /// `SyncConflict` instead; this mutation re-verifies eligibility and
    /// throws rather than trusting the caller.
    public mutating func updateImportedTransactionInPlace(
        transactionID: TransactionID,
        newAmountMilliunits: Milliunits,
        newPostedEpoch: Int64,
        newPayeeName: String?,
        newMemo: String?,
        nowEpoch: Int64
    ) throws {
        guard var row = transactions[transactionID], row.sourceKind == .simplefin else {
            throw MutationError.transactionNotFound
        }
        guard row.postingState == .needsCategory,
              row.userEditedAtEpoch == nil,
              row.approved == false,
              row.cleared == .uncleared,
              row.transferPairID == nil,
              row.refundOfTransactionID == nil,
              !reconciliationMembership.contains(row.id) else {
            throw MutationError.transactionImmutable
        }
        guard let account = accounts[row.accountID] else { throw MutationError.accountNotFound }
        guard let newDate = calendar.budgetDate(fromEpoch: newPostedEpoch) else {
            throw MutationError.futureDatedTransaction
        }
        guard newDate.budgetMonth <= currentMonth else { throw MutationError.futureDatedTransaction }
        guard newDate.budgetMonth >= budget.firstMonth else { throw MutationError.dateBeforeFirstMonth }
        guard !isMonthClosed(row.date.budgetMonth), !isMonthClosed(newDate.budgetMonth) else {
            throw MutationError.closedMonth
        }

        var copy = self
        let payeeID = newPayeeName.map { copy.findOrCreateUserPayee(named: $0) }
            ?? copy.systemPayeeID(.unknown)
        row.payeeID = payeeID
        row.date = newDate
        row.effectiveAtEpoch = newPostedEpoch
        row.memo = newMemo
        row.amountMilliunits = newAmountMilliunits
        row.categoryID = copy.importedRowCategory(account: account, payeeID: payeeID, amountMilliunits: newAmountMilliunits)
        row.importedDescription = newPayeeName
        row.splits = nil
        row.postingState = .posted
        row.stageReason = nil
        row.stageMetadata = nil
        try copy.applyImportRules(to: &row, nowEpoch: nowEpoch)
        copy.setTransaction(row)
        try copy.runReplayAndApplyDecisions()
        try copy.bumpRevision()
        self = copy
    }

    // MARK: - SimpleFIN sync records (§4.3 conflicts, §4.4 discrepancies)

    /// Records a successful sighting of one imported identity. Presence clears
    /// a prior disappearance acknowledgement and dismisses open remote
    /// observations that the newly seen payload has made stale.
    mutating func updateSimpleFINImportLastSeen(
        transactionID: TransactionID,
        lastSeenEpoch: Int64,
        observedPayloadHash: String
    ) {
        guard var record = simpleFINImports[transactionID] else { return }
        record.lastSeenEpoch = lastSeenEpoch
        record.remoteDisappearanceAcknowledged = false
        setSimpleFINImport(record)

        for id in syncConflicts.keys.sorted() {
            guard var conflict = syncConflicts[id],
                  conflict.status == .open,
                  conflict.simpleFINImportID == record.id else {
                continue
            }
            let isStale: Bool
            switch conflict.eventKind {
            case .remoteDisappeared:
                isStale = true
            case .remoteChanged:
                isStale = conflict.newMetadata.payloadHash != observedPayloadHash
            case .manualPotentialDuplicate:
                isStale = false
            }
            guard isStale else { continue }
            conflict.status = .dismissed
            conflict.resolvedAtEpoch = lastSeenEpoch
            setSyncConflict(conflict)
        }
    }

    /// A silent in-place import update has accepted the current provider row,
    /// so every older open remote observation for that import is obsolete,
    /// including an observation for the same payload hash. Exact sightings do
    /// not use this path because a matching open conflict can still require an
    /// explicit user choice for a protected local row.
    mutating func dismissOpenSimpleFINRemoteObservations(
        simpleFINImportID: SimpleFINImportID,
        nowEpoch: Int64
    ) {
        for id in syncConflicts.keys.sorted() {
            guard var conflict = syncConflicts[id],
                  conflict.status == .open,
                  conflict.simpleFINImportID == simpleFINImportID,
                  conflict.eventKind != .manualPotentialDuplicate else {
                continue
            }
            conflict.status = .dismissed
            conflict.resolvedAtEpoch = nowEpoch
            setSyncConflict(conflict)
        }
    }

    /// Creates an open `SyncConflict` unless an equivalent open conflict
    /// already exists: at most one open `remoteChanged` per transaction per
    /// new payload hash, and at most one open `remoteDisappeared` per
    /// transaction, so repeated identical responses never spam rows (§4.3).
    @discardableResult
    mutating func recordSyncConflictIfNew(
        transactionID: TransactionID?,
        simpleFINImportID: SimpleFINImportID?,
        eventKind: SyncConflictKind,
        oldMetadata: SyncConflictMetadata,
        newMetadata: SyncConflictMetadata,
        nowEpoch: Int64
    ) -> SyncConflictID? {
        let duplicate = syncConflicts.values.contains { existing in
            guard existing.eventKind == eventKind,
                  existing.transactionID == transactionID,
                  existing.simpleFINImportID == simpleFINImportID else {
                return false
            }
            if eventKind == .manualPotentialDuplicate {
                return true // an explicit terminal choice acknowledges this exact pair
            }
            return existing.status == .open
                && (eventKind != .remoteChanged
                    || existing.newMetadata.payloadHash == newMetadata.payloadHash)
        }
        guard !duplicate else { return nil }

        if eventKind != .manualPotentialDuplicate, let simpleFINImportID {
            // A later provider observation replaces, but never erases, the
            // prior open observation for this imported identity.
            for id in syncConflicts.keys.sorted() {
                guard var existing = syncConflicts[id],
                      existing.status == .open,
                      existing.eventKind != .manualPotentialDuplicate,
                      existing.simpleFINImportID == simpleFINImportID else {
                    continue
                }
                existing.status = .dismissed
                existing.resolvedAtEpoch = nowEpoch
                setSyncConflict(existing)
            }
        }
        let row = SyncConflictRow(
            budgetID: budget.id,
            transactionID: transactionID,
            simpleFINImportID: simpleFINImportID,
            eventKind: eventKind,
            oldMetadata: oldMetadata,
            newMetadata: newMetadata,
            createdAtEpoch: nowEpoch
        )
        setSyncConflict(row)
        return row.id
    }

    /// Creates or refreshes the single open `SnapshotDiscrepancy` for the
    /// account/link identity (§4.4). The sync engine never resolves one on its
    /// own — "the sync engine never guesses" — and an observation from another
    /// link must never retarget or suppress the existing row.
    @discardableResult
    mutating func upsertOpenSnapshotDiscrepancy(
        accountID: AccountID,
        simpleFINLinkIdentity: String? = nil,
        observedEpoch: Int64,
        remoteBalanceMilliunits: Milliunits,
        localRegisterMilliunits: Milliunits,
        nowEpoch: Int64
    ) throws -> SnapshotDiscrepancyID? {
        let difference = remoteBalanceMilliunits.subtractingReportingOverflow(localRegisterMilliunits)
        guard !difference.overflow else { throw MutationError.arithmeticOverflow }
        let existing = snapshotDiscrepancies.values
            .sorted { $0.id < $1.id }
            .first {
                $0.accountID == accountID
                    && $0.status == .open
                    && $0.simpleFINLinkIdentity == simpleFINLinkIdentity
            }
        if var open = existing {
            // An intervening open observation starts a new episode. Refresh it
            // even when the latest tuple happens to match an older terminal
            // observation; suppressing here would leave a stale open row.
            open.observedEpoch = observedEpoch
            open.remoteBalanceMilliunits = remoteBalanceMilliunits
            open.localRegisterMilliunits = localRegisterMilliunits
            open.differenceMilliunits = difference.partialValue
            if let simpleFINLinkIdentity {
                open.simpleFINLinkIdentity = simpleFINLinkIdentity
            }
            setSnapshotDiscrepancy(open)
            return open.id
        }
        let exactTerminalObservation = snapshotDiscrepancies.values.contains {
            $0.accountID == accountID
                && $0.status == .resolved
                && $0.simpleFINLinkIdentity == simpleFINLinkIdentity
                && $0.observedEpoch == observedEpoch
                && $0.remoteBalanceMilliunits == remoteBalanceMilliunits
                && $0.localRegisterMilliunits == localRegisterMilliunits
                && $0.differenceMilliunits == difference.partialValue
        }
        guard !exactTerminalObservation else { return nil }
        let row = SnapshotDiscrepancyRow(
            budgetID: budget.id,
            accountID: accountID,
            simpleFINLinkIdentity: simpleFINLinkIdentity,
            observedEpoch: observedEpoch,
            remoteBalanceMilliunits: remoteBalanceMilliunits,
            localRegisterMilliunits: localRegisterMilliunits,
            differenceMilliunits: difference.partialValue,
            createdAtEpoch: nowEpoch
        )
        setSnapshotDiscrepancy(row)
        return row.id
    }

    /// §4.4 as-of register balance with the §3.2 pair-pulled logical cutoff:
    /// sums non-voided `posted`/`needsCategory`/`staged` rows whose effective
    /// timestamp (`effective_at_epoch` for imported rows, budget-timezone
    /// date-noon otherwise) is `<= epoch`. A leg of a `complete` transfer pair
    /// is included whenever the pair's earlier leg timestamp is `<= epoch`, so
    /// no cutoff can expose half of a paired event.
    public func registerBalanceAsOf(accountID: AccountID, epoch: Int64) throws -> Milliunits {
        guard accounts[accountID] != nil else { throw MutationError.accountNotFound }
        func effectiveTimestamp(_ row: TransactionRow) throws -> Int64 {
            if let effective = row.effectiveAtEpoch { return effective }
            return try calendar.noonEpoch(of: row.date)
        }
        var total: Milliunits = 0
        for row in transactions.values.sorted(by: { $0.id < $1.id }) {
            guard row.accountID == accountID, row.postingState != .voided else { continue }
            let cutoffTimestamp: Int64
            if let pairID = row.transferPairID, transferPairs[pairID]?.status == .complete {
                let legTimestamps = try transactions.values
                    .filter { $0.transferPairID == pairID && $0.postingState != .voided }
                    .map(effectiveTimestamp)
                guard let earliest = legTimestamps.min() else { continue }
                cutoffTimestamp = earliest
            } else {
                cutoffTimestamp = try effectiveTimestamp(row)
            }
            guard cutoffTimestamp <= epoch else { continue }
            let sum = total.addingReportingOverflow(row.amountMilliunits)
            guard !sum.overflow else { throw MutationError.arithmeticOverflow }
            total = sum.partialValue
        }
        return total
    }

    // MARK: - Categorize / workflow flags

    public mutating func categorize(transactionID: TransactionID, categoryID newCategoryID: CategoryID, nowEpoch: Int64) throws {
        guard var row = transactions[transactionID] else { throw MutationError.transactionNotFound }
        guard row.postingState != .voided else { throw MutationError.transactionNotFound }
        guard !reconciliationMembership.contains(transactionID) || row.cleared != .reconciled else {
            throw MutationError.reconciledTransaction
        }
        guard row.cleared != .reconciled else { throw MutationError.reconciledTransaction }
        guard !isMonthClosed(row.date.budgetMonth) else { throw MutationError.closedMonth }
        guard row.postingState == .posted || row.postingState == .needsCategory else {
            throw MutationError.resolutionNotEligible // staged rows use explicit resolutions
        }
        guard row.transferPairID == nil else { throw MutationError.transferLegsInvalid }
        // A linked refund's category is a materialized copy of its origin.
        if row.kind == .refund, row.refundOfTransactionID != nil {
            throw MutationError.categoryNotAllowed
        }
        guard let account = accounts[row.accountID] else { throw MutationError.accountNotFound }
        try validateCategoryChoice(
            account: account, kind: row.kind, amount: row.amountMilliunits,
            categoryID: newCategoryID, refundOf: row.refundOfTransactionID,
            refundOfComponentIndex: row.refundOfComponentIndex
        )

        var copy = self
        let wasSplit = row.splits != nil
        row.splits = nil // categorizing a split row replaces the split (D3)
        row.categoryID = newCategoryID
        row.userEditedAtEpoch = nowEpoch
        if row.postingState == .needsCategory { row.postingState = .posted }
        copy.setTransaction(row)

        // Origin recategorization atomically updates every dependent linked
        // refund's materialized copy before replay (§3.5.3).
        for (_, var dependent) in copy.transactions
        where dependent.refundOfTransactionID == transactionID && dependent.postingState != .voided {
            if wasSplit { dependent.refundOfComponentIndex = nil }
            if dependent.postingState == .staged {
                var meta = dependent.stageMetadata ?? StageMetadata()
                meta.proposedCategoryID = newCategoryID
                dependent.stageMetadata = meta
            } else {
                dependent.categoryID = newCategoryID
            }
            copy.setTransaction(dependent)
        }

        try copy.runReplayAndApplyDecisions()
        if row.kind == .normal {
            copy.updatePayeeLearning(payeeID: row.payeeID, categoryID: newCategoryID, amount: row.amountMilliunits)
        }
        try copy.bumpRevision()
        self = copy
    }

    /// Approval is a workflow flag, not an accounting filter.
    public mutating func setApproved(transactionID: TransactionID, approved: Bool, nowEpoch: Int64) throws {
        guard var row = transactions[transactionID] else { throw MutationError.transactionNotFound }
        guard row.postingState != .voided else { throw MutationError.transactionNotFound }
        guard !isMonthClosed(row.date.budgetMonth) else { throw MutationError.closedMonth }
        var copy = self
        row.approved = approved
        row.userEditedAtEpoch = nowEpoch
        copy.setTransaction(row)
        copy.recordAudit(entityType: "transaction", entityID: transactionID.description, eventKind: "approvalChanged", nowEpoch: nowEpoch)
        try copy.bumpRevision()
        self = copy
    }

    /// `uncleared ↔ cleared` toggles only; `reconciled` is set by
    /// reconciliation.
    public mutating func setCleared(transactionID: TransactionID, cleared: ClearedState, nowEpoch: Int64) throws {
        guard var row = transactions[transactionID] else { throw MutationError.transactionNotFound }
        guard row.postingState != .voided else { throw MutationError.transactionNotFound }
        guard cleared != .reconciled, row.cleared != .reconciled else {
            throw MutationError.reconciledTransaction
        }
        var copy = self
        row.cleared = cleared
        row.userEditedAtEpoch = nowEpoch
        copy.setTransaction(row)
        try copy.bumpRevision()
        self = copy
    }

    // MARK: - Edits (§3.8 dependency rules)

    public mutating func updateMemo(transactionID: TransactionID, memo: String?, nowEpoch: Int64) throws {
        guard var row = transactions[transactionID] else { throw MutationError.transactionNotFound }
        guard row.postingState != .voided else { throw MutationError.transactionNotFound }
        var copy = self
        row.memo = memo
        row.userEditedAtEpoch = nowEpoch
        copy.setTransaction(row)
        try copy.bumpRevision()
        self = copy
    }

    /// Amount edits: manual rows only (imported amounts are remote-owned).
    /// Paired legs mirror atomically. The edited row must not become staged;
    /// dependent refunds may re-stage (with a UI warning).
    public mutating func updateAmount(transactionID: TransactionID, amountMilliunits: Milliunits, nowEpoch: Int64) throws {
        guard var row = transactions[transactionID] else { throw MutationError.transactionNotFound }
        guard row.postingState != .voided else { throw MutationError.transactionNotFound }
        guard row.sourceKind == .manual else { throw MutationError.transactionImmutable }
        guard row.cleared != .reconciled else { throw MutationError.reconciledTransaction }
        guard !isMonthClosed(row.date.budgetMonth) else { throw MutationError.closedMonth }
        guard row.splits == nil else { throw MutationError.transactionIsSplit }

        var copy = self
        if let pairID = row.transferPairID {
            guard let pair = transferPairs[pairID], pair.status == .complete else {
                throw MutationError.transferPairNotFound
            }
            let legs = transactions.values.filter { $0.transferPairID == pairID && $0.postingState != .voided }
            guard legs.count == 2 else { throw MutationError.transferLegsInvalid }
            guard amountMilliunits != 0 else { throw MutationError.transferLegsInvalid }
            for var leg in legs {
                guard leg.sourceKind == .manual, leg.cleared != .reconciled else {
                    throw MutationError.transactionImmutable
                }
                let sameSide = leg.id == transactionID
                let magnitude = try absChecked(amountMilliunits)
                let signedForLeg: Milliunits
                if sameSide {
                    signedForLeg = amountMilliunits
                } else {
                    signedForLeg = amountMilliunits > 0 ? try negChecked(magnitude) : magnitude
                }
                leg.amountMilliunits = signedForLeg
                leg.userEditedAtEpoch = nowEpoch
                copy.setTransaction(leg)
            }
        } else {
            if row.kind == .refund, amountMilliunits <= 0 { throw MutationError.refundNotPositive }
            if row.kind == .normal, let account = accounts[row.accountID] {
                // Re-validate the sign/category matrix under the new amount.
                try validateCategoryChoice(
                    account: account, kind: row.kind, amount: amountMilliunits,
                    categoryID: row.categoryID, refundOf: row.refundOfTransactionID
                )
            }
            row.amountMilliunits = amountMilliunits
            row.userEditedAtEpoch = nowEpoch
            copy.setTransaction(row)
        }

        let result = try copy.runReplayAndApplyDecisions()
        if let decision = result.postingDecisions[transactionID], decision.postingState == .staged,
           decision.stageReason != .cashInflowWithCreditDebt {
            throw MutationError.cardBalanceWouldBecomePositive
        }
        try copy.bumpRevision()
        self = copy
    }

    /// Date edits are explicit replay mutations (§3.2). Manual rows recompute
    /// `effective_at_epoch` to local noon; imported rows keep the remote
    /// `source_order_key` but take the new date's noon epoch. Paired legs move
    /// together.
    public mutating func updateDate(transactionID: TransactionID, date newDate: BudgetDate, nowEpoch: Int64) throws {
        guard let row = transactions[transactionID] else { throw MutationError.transactionNotFound }
        guard row.postingState != .voided else { throw MutationError.transactionNotFound }
        guard row.cleared != .reconciled else { throw MutationError.reconciledTransaction }
        guard row.sourceKind != .system else { throw MutationError.transactionImmutable }
        guard newDate.budgetMonth >= budget.firstMonth else { throw MutationError.dateBeforeFirstMonth }
        guard newDate.budgetMonth <= currentMonth else { throw MutationError.futureDatedTransaction }
        guard !isMonthClosed(row.date.budgetMonth), !isMonthClosed(newDate.budgetMonth) else {
            throw MutationError.closedMonth
        }

        var copy = self
        let noon = try calendar.noonEpoch(of: newDate)
        if let pairID = row.transferPairID {
            guard let pair = transferPairs[pairID], pair.status == .complete else {
                throw MutationError.transferPairNotFound
            }
            for var leg in transactions.values where leg.transferPairID == pairID && leg.postingState != .voided {
                guard leg.cleared != .reconciled else { throw MutationError.reconciledTransaction }
                leg.date = newDate
                leg.effectiveAtEpoch = noon
                leg.userEditedAtEpoch = nowEpoch
                copy.setTransaction(leg)
            }
        } else {
            var updated = row
            updated.date = newDate
            updated.effectiveAtEpoch = noon
            updated.userEditedAtEpoch = nowEpoch
            copy.setTransaction(updated)
        }

        let result = try copy.runReplayAndApplyDecisions()
        if row.sourceKind == .manual,
           let decision = result.postingDecisions[transactionID], decision.postingState == .staged,
           decision.stageReason != .cashInflowWithCreditDebt {
            throw MutationError.cardBalanceWouldBecomePositive
        }
        try copy.bumpRevision()
        self = copy
    }

    // MARK: - Delete / void (§3.8)

    /// Imported rows are soft-voided (import tombstone retained); manual rows
    /// may be physically deleted only without import identity, reconciliation
    /// membership, or dependent refunds. Pair legs delegate to the pair rules.
    public mutating func deleteTransaction(_ transactionID: TransactionID, nowEpoch: Int64) throws {
        guard let row = transactions[transactionID] else { throw MutationError.transactionNotFound }
        guard row.postingState != .voided else { throw MutationError.transactionNotFound }
        guard !isMonthClosed(row.date.budgetMonth) else { throw MutationError.closedMonth }
        if let pairID = row.transferPairID {
            try deleteTransferPair(pairID, nowEpoch: nowEpoch)
            return
        }
        guard row.cleared != .reconciled, !reconciliationMembership.contains(transactionID) else {
            throw MutationError.reconciledTransaction
        }
        guard row.sourceKind != .system else { throw MutationError.systemEntityImmutable }

        var copy = self
        if row.sourceKind == .simplefin || row.sourceKind == .file {
            var voided = row
            voided.postingState = .voided
            voided.stageReason = nil
            copy.setTransaction(voided)
            copy.recordAudit(entityType: "transaction", entityID: transactionID.description, eventKind: "softVoid", nowEpoch: nowEpoch)
        } else {
            let hasDependents = transactions.values.contains {
                $0.refundOfTransactionID == transactionID && $0.postingState != .voided && $0.id != transactionID
            }
            guard !hasDependents else { throw MutationError.transactionHasDependents }
            copy.removeTransaction(transactionID)
            copy.recordAudit(entityType: "transaction", entityID: transactionID.description, eventKind: "delete", nowEpoch: nowEpoch)
        }
        try copy.runReplayAndApplyDecisions()
        try copy.bumpRevision()
        self = copy
    }

    // MARK: - Reconciliation adjustments (§3.9 steps 4–5)

    /// Creates the deterministic reconciliation adjustment row. Cash-like
    /// account: payee `Reconciliation Balance Adjustment`, category RTA,
    /// signed amount included in RTA activity. Credit card: payee `Card Debt
    /// Adjustment`, no category, budget-neutral, and permitted only while
    /// `projectionBalance + difference <= 0`.
    @discardableResult
    public mutating func addReconciliationAdjustment(
        accountID: AccountID,
        date: BudgetDate,
        amountMilliunits: Milliunits,
        nowEpoch: Int64
    ) throws -> TransactionID {
        var copy = self
        let rowID = try copy.insertSystemAdjustmentTransaction(
            accountID: accountID,
            date: date,
            effectiveAtEpoch: try calendar.noonEpoch(of: date),
            amountMilliunits: amountMilliunits
        )
        let result = try copy.runReplayAndApplyDecisions()
        if accounts[accountID]?.type == .creditCard,
           result.postingDecisions[rowID]?.postingState != .posted {
            // §3.9 step 5: completion requires candidateProjection <= 0.
            throw MutationError.cardBalanceWouldBecomePositive
        }
        copy.recordAudit(
            entityType: "transaction", entityID: rowID.description,
            eventKind: "reconciliationAdjustment", nowEpoch: nowEpoch
        )
        try copy.bumpRevision()
        self = copy
        return rowID
    }

    /// Shared row-construction primitive for reconciliation and §4.4 snapshot
    /// discrepancy adjustments. The caller controls the exact effective epoch
    /// and remains responsible for replay, the card guard, audit, revision,
    /// and final commit.
    @discardableResult
    mutating func insertSystemAdjustmentTransaction(
        accountID: AccountID,
        date: BudgetDate,
        effectiveAtEpoch: Int64,
        amountMilliunits: Milliunits
    ) throws -> TransactionID {
        guard let account = accounts[accountID] else { throw MutationError.accountNotFound }
        guard budgetEligible(account, budgetCurrency: budget.currency) else {
            throw MutationError.reconciliationInvalid
        }
        guard amountMilliunits != 0 else { throw MutationError.reconciliationInvalid }
        guard date.budgetMonth >= budget.firstMonth else { throw MutationError.dateBeforeFirstMonth }
        guard date.budgetMonth <= currentMonth else { throw MutationError.futureDatedTransaction }
        guard !isMonthClosed(date.budgetMonth) else { throw MutationError.closedMonth }
        guard calendar.budgetDate(fromEpoch: effectiveAtEpoch) == date else {
            throw IntegrityError(code: .invalidCalendar)
        }

        let seq = try allocateSourceSequence()
        let isCard = account.type == .creditCard
        let row = TransactionRow(
            budgetID: budget.id,
            accountID: accountID,
            payeeID: systemPayeeID(isCard ? .cardDebtAdjustment : .reconciliationAdjustment),
            sourceKind: .system,
            date: date,
            effectiveAtEpoch: effectiveAtEpoch,
            sourceOrderKey: .system(sequence: seq, systemKind: "reconciliationAdjustment"),
            amountMilliunits: amountMilliunits,
            cleared: .cleared,
            approved: true,
            postingState: .posted,
            categoryID: isCard ? nil : rtaCategoryID,
            kind: .adjustment
        )
        setTransaction(row)
        return row.id
    }

    /// Cleared register balance per §3.9 step 1: all non-voided rows for the
    /// account with `date <= D` and `cleared in {cleared, reconciled}`. Staged
    /// and needsCategory rows are included because they are posted register
    /// items.
    public func clearedBalance(accountID: AccountID, asOf statementDate: BudgetDate) throws -> Milliunits {
        var total: Milliunits = 0
        for row in transactions.values
        where row.accountID == accountID
            && row.postingState != .voided
            && row.date <= statementDate
            && (row.cleared == .cleared || row.cleared == .reconciled) {
            total = try addChecked(total, row.amountMilliunits)
        }
        return total
    }

    /// §3.9 completion: computes `difference = statementBalance -
    /// clearedBalance`, creates one adjustment when nonzero (cash → signed RTA
    /// activity; card → budget-neutral Card Debt Adjustment guarded by
    /// `candidateProjection <= 0`), and marks the included `cleared` rows
    /// `reconciled`. Rows dated in a closed month keep their cleared state and
    /// membership untouched (§2.1 blocks membership changes there); they still
    /// count toward the cleared balance. A positive credit-card statement
    /// balance is an unsupported positive card asset and cannot complete in v1.
    ///
    /// TODO(v1 §3.9 step 7): reconciliation undo with per-row accounting
    /// fingerprints is not implemented yet; the workspace records membership
    /// only.
    @discardableResult
    public mutating func completeReconciliation(
        accountID: AccountID,
        statementDate: BudgetDate,
        statementBalanceMilliunits: Milliunits,
        nowEpoch: Int64
    ) throws -> ReconciliationOutcome {
        guard let account = accounts[accountID] else { throw MutationError.accountNotFound }
        guard budgetEligible(account, budgetCurrency: budget.currency) else {
            throw MutationError.reconciliationInvalid
        }
        if account.type == .creditCard, statementBalanceMilliunits > 0 {
            throw MutationError.reconciliationInvalid
        }
        guard statementDate.budgetMonth >= budget.firstMonth else { throw MutationError.dateBeforeFirstMonth }
        guard statementDate.budgetMonth <= currentMonth else { throw MutationError.futureDatedTransaction }

        var copy = self
        let cleared = try clearedBalance(accountID: accountID, asOf: statementDate)
        let difference = try subChecked(statementBalanceMilliunits, cleared)

        var adjustmentID: TransactionID?
        if difference != 0 {
            // Rejected (card would cross zero / closed month) before any state
            // is written; `copy` is discarded on throw.
            adjustmentID = try copy.addReconciliationAdjustment(
                accountID: accountID,
                date: statementDate,
                amountMilliunits: difference,
                nowEpoch: nowEpoch
            )
        }

        let reconciliationID = ReconciliationID()
        var members: [ReconciliationTransactionRow] = []
        var newlyReconciled = 0
        for row in copy.transactions.values.sorted(by: { $0.id < $1.id })
        where row.accountID == accountID
            && row.postingState != .voided
            && row.date <= statementDate
            && (row.cleared == .cleared || row.cleared == .reconciled) {
            if row.cleared == .cleared && !copy.isMonthClosed(row.date.budgetMonth) {
                var updated = row
                updated.cleared = .reconciled
                copy.setTransaction(updated)
                copy.insertReconciliationMembership(row.id)
                newlyReconciled += 1
                members.append(ReconciliationTransactionRow(
                    reconciliationID: reconciliationID,
                    transactionID: row.id,
                    fingerprintAtReconciliation: updated.accountingFingerprint,
                    wasNewlyMarkedReconciled: true
                ))
            } else if row.cleared == .reconciled {
                // Already-reconciled rows retain their earlier membership; the
                // join records them as included but not newly marked (§3.9.6).
                members.append(ReconciliationTransactionRow(
                    reconciliationID: reconciliationID,
                    transactionID: row.id,
                    fingerprintAtReconciliation: row.accountingFingerprint,
                    wasNewlyMarkedReconciled: false
                ))
            }
        }

        let adjustmentFingerprint = adjustmentID.flatMap { copy.transactions[$0]?.accountingFingerprint }
        copy.setReconciliation(ReconciliationRow(
            id: reconciliationID,
            budgetID: budget.id,
            accountID: accountID,
            statementDate: statementDate,
            statementBalanceMilliunits: statementBalanceMilliunits,
            clearedBalanceMilliunits: cleared,
            adjustmentTransactionID: adjustmentID,
            adjustmentFingerprintAtCreation: adjustmentFingerprint,
            status: .completed,
            createdAtEpoch: nowEpoch,
            completedAtEpoch: nowEpoch
        ))
        copy.setReconciliationTransactions(reconciliationID, members)

        copy.recordAudit(
            entityType: "reconciliation",
            entityID: reconciliationID.description,
            eventKind: "reconciliationCompleted",
            metadata: [
                "account": accountID.description,
                "statementDate": statementDate.description,
                "newlyReconciled": String(newlyReconciled)
            ],
            nowEpoch: nowEpoch
        )
        try copy.bumpRevision()
        self = copy
        return ReconciliationOutcome(
            clearedBalanceMilliunits: cleared,
            differenceMilliunits: difference,
            adjustmentTransactionID: adjustmentID,
            newlyReconciledCount: newlyReconciled
        )
    }

    /// The most recent completed reconciliation for an account, if any — the
    /// only one eligible for undo (§3.9 step 7).
    public func latestCompletedReconciliation(accountID: AccountID) -> ReconciliationRow? {
        reconciliations.values
            .filter { $0.accountID == accountID && $0.status == .completed }
            .max { ($0.completedAtEpoch ?? 0, $0.id) < ($1.completedAtEpoch ?? 0, $1.id) }
    }

    /// §3.9 step 7: undo the most recent completed reconciliation for the
    /// account. Allowed only when every newly-marked row's current
    /// fingerprint equals the stored fingerprint and the generated
    /// adjustment, if any, is unchanged. Removes reconciled state only from
    /// `wasNewlyMarkedReconciled` rows, deletes the unchanged generated
    /// adjustment, marks the reconciliation undone, and leaves earlier
    /// history intact.
    public mutating func undoLastReconciliation(accountID: AccountID, nowEpoch: Int64) throws {
        guard let reconciliation = latestCompletedReconciliation(accountID: accountID) else {
            throw MutationError.reconciliationInvalid
        }
        guard !isMonthClosed(reconciliation.statementDate.budgetMonth) else {
            throw MutationError.closedMonth
        }
        let members = reconciliationTransactions[reconciliation.id] ?? []

        // Verify every fingerprint before touching any state.
        for member in members where member.wasNewlyMarkedReconciled {
            guard let row = transactions[member.transactionID],
                  row.accountingFingerprint == member.fingerprintAtReconciliation else {
                throw MutationError.reconciliationUndoBlocked
            }
        }
        var adjustmentRow: TransactionRow?
        if let adjustmentID = reconciliation.adjustmentTransactionID {
            guard let row = transactions[adjustmentID],
                  row.accountingFingerprint == reconciliation.adjustmentFingerprintAtCreation else {
                throw MutationError.reconciliationUndoBlocked
            }
            adjustmentRow = row
        }

        var copy = self
        for member in members where member.wasNewlyMarkedReconciled {
            guard member.transactionID != reconciliation.adjustmentTransactionID else { continue }
            guard var row = copy.transactions[member.transactionID] else {
                throw MutationError.reconciliationUndoBlocked
            }
            row.cleared = .cleared
            copy.setTransaction(row)
            copy.removeReconciliationMembership(member.transactionID)
        }
        if let adjustmentRow {
            copy.removeTransaction(adjustmentRow.id)
            copy.removeReconciliationMembership(adjustmentRow.id)
        }
        var undone = reconciliation
        undone.status = .undone
        copy.setReconciliation(undone)
        try copy.runReplayAndApplyDecisions()
        copy.recordAudit(
            entityType: "reconciliation",
            entityID: reconciliation.id.description,
            eventKind: "reconciliationUndone",
            metadata: ["account": accountID.description],
            nowEpoch: nowEpoch
        )
        try copy.bumpRevision()
        self = copy
    }

    /// §5.4 explicit un-reconcile of one row (required before editing a
    /// reconciled transaction). The row returns to `cleared`; membership is
    /// removed so a later reconciliation can include it again. The historical
    /// reconciliation record itself is untouched (its fingerprints will no
    /// longer match, so its undo becomes blocked — deliberately).
    public mutating func unreconcileTransaction(_ transactionID: TransactionID, nowEpoch: Int64) throws {
        guard var row = transactions[transactionID] else { throw MutationError.transactionNotFound }
        guard row.cleared == .reconciled else { throw MutationError.reconciliationInvalid }
        guard !isMonthClosed(row.date.budgetMonth) else { throw MutationError.closedMonth }
        var copy = self
        row.cleared = .cleared
        copy.setTransaction(row)
        copy.removeReconciliationMembership(transactionID)
        copy.recordAudit(
            entityType: "transaction",
            entityID: transactionID.description,
            eventKind: "unreconciled",
            nowEpoch: nowEpoch
        )
        try copy.bumpRevision()
        self = copy
    }

    /// §4.4 attestation bookkeeping: marks an account's opening as derived or
    /// user-attested-incomplete.
    public mutating func markAccountHistoryIncomplete(_ accountID: AccountID) throws {
        guard var account = accounts[accountID] else { throw MutationError.accountNotFound }
        guard !account.historyIncomplete else { return }
        account.historyIncomplete = true
        var copy = self
        copy.setAccount(account)
        try copy.bumpRevision()
        self = copy
    }

    // MARK: - Budget identity (D8)

    public mutating func renameBudget(to name: String) throws {
        let trimmed = try validatedEntityName(name)
        guard budget.name != trimmed else { return }
        var copy = self
        copy.setBudgetName(trimmed)
        try copy.bumpRevision()
        self = copy
    }

    public mutating func setBudgetArchived(_ archived: Bool, nowEpoch: Int64) throws {
        guard budget.archived != archived else { return }
        var copy = self
        copy.setBudgetArchivedFlag(archived)
        copy.recordAudit(entityType: "budget", entityID: budget.id.description, eventKind: archived ? "budgetArchived" : "budgetUnarchived", nowEpoch: nowEpoch)
        try copy.bumpRevision()
        self = copy
    }

    // MARK: - Month lifecycle

    /// The injected budget clock advances the observed month monotonically; a
    /// backwards system clock never decreases it.
    public mutating func advanceObservedMonth(to month: BudgetMonth) throws {
        guard month > currentMonth else { return }
        var copy = self
        copy.advanceBudgetMonth(month)
        try copy.runReplayAndApplyDecisions()
        try copy.bumpRevision()
        self = copy
    }

    public mutating func closeMonth(_ month: BudgetMonth, nowEpoch: Int64) throws {
        guard month < currentMonth else { throw MutationError.monthNotClosed }
        guard month >= budget.firstMonth else { throw MutationError.dateBeforeFirstMonth }
        guard !isMonthClosed(month) else { throw MutationError.monthAlreadyClosed }
        var copy = self
        copy.setClosedMonth(ClosedMonthRow(budgetID: budget.id, month: month, status: .closed, closedAtEpoch: nowEpoch))
        copy.recordAudit(entityType: "month", entityID: month.description, eventKind: "close", nowEpoch: nowEpoch)
        try copy.bumpRevision()
        self = copy
    }

    /// Reopening is atomic and audited; it triggers a full recomputation via
    /// the standard replay pass.
    public mutating func reopenMonth(_ month: BudgetMonth, nowEpoch: Int64) throws {
        guard isMonthClosed(month) else { throw MutationError.monthNotClosed }
        var copy = self
        copy.setClosedMonth(ClosedMonthRow(
            budgetID: budget.id, month: month, status: .reopened,
            closedAtEpoch: closedMonths[month]?.closedAtEpoch ?? nowEpoch,
            reopenedAtEpoch: nowEpoch
        ))
        try copy.runReplayAndApplyDecisions()
        copy.recordAudit(entityType: "month", entityID: month.description, eventKind: "reopen", nowEpoch: nowEpoch)
        try copy.bumpRevision()
        self = copy
    }
}

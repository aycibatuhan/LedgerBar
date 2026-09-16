import Foundation

extension BudgetWorkspace {

    // MARK: - Transfer pair validation (§3.8)

    /// Days-from-civil (proleptic Gregorian), for the fixed ±7-day pairing
    /// window. Pure integer arithmetic; no Calendar involvement.
    static func civilDayNumber(_ d: BudgetDate) -> Int {
        let y = d.month <= 2 ? d.year - 1 : d.year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (d.month + 9) % 12
        let doy = (153 * mp + 2) / 5 + (d.day - 1)
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }

    /// v1 combination matrix: source card → rejected; destination card only
    /// from an eligible cash-like source; both accounts must carry the budget
    /// currency (mismatched-currency accounts cannot join pairs).
    func validatePairAccounts(source: AccountRow, destination: AccountRow) throws {
        guard source.id != destination.id else { throw MutationError.transferLegsInvalid }
        guard source.currency == budget.currency, destination.currency == budget.currency else {
            throw MutationError.currencyMismatch
        }
        let sourceEligible = budgetEligible(source, budgetCurrency: budget.currency)
        let destEligible = budgetEligible(destination, budgetCurrency: budget.currency)
        if source.type == .creditCard {
            throw MutationError.unsupportedTransferPair // card→cash / card→card / card→off
        }
        if destination.type == .creditCard {
            guard destEligible, sourceEligible, source.type.isCashLike else {
                throw MutationError.unsupportedTransferPair // off-budget→card
            }
        }
    }

    // MARK: - Manual pair creation (§3.6 case 1, §3.8)

    /// Creates a new two-leg transfer pair. A manual pair that would cross the
    /// card guard is rejected atomically with no inserted rows.
    @discardableResult
    public mutating func createManualTransferPair(
        sourceAccountID: AccountID,
        destinationAccountID: AccountID,
        amount: Milliunits,
        date: BudgetDate,
        onLegCategoryID: CategoryID? = nil,
        nowEpoch: Int64
    ) throws -> TransferPairID {
        guard amount > 0 else { throw MutationError.transferLegsInvalid }
        guard let source = accounts[sourceAccountID], let destination = accounts[destinationAccountID] else {
            throw MutationError.accountNotFound
        }
        guard !source.closed, !destination.closed else { throw MutationError.accountClosed }
        try validatePairAccounts(source: source, destination: destination)
        guard date.budgetMonth >= budget.firstMonth else { throw MutationError.dateBeforeFirstMonth }
        guard date.budgetMonth <= currentMonth else { throw MutationError.futureDatedTransaction }
        guard !isMonthClosed(date.budgetMonth) else { throw MutationError.closedMonth }

        let sourceEligible = budgetEligible(source, budgetCurrency: budget.currency)
        let destEligible = budgetEligible(destination, budgetCurrency: budget.currency)

        // Category on the on-budget leg of an on↔off pair; nil elsewhere.
        var sourceCategory: CategoryID?
        var destCategory: CategoryID?
        switch (sourceEligible, destEligible) {
        case (true, false):
            guard let c = onLegCategoryID, let cat = categories[c], cat.kind == .spending, c != uncategorizedID else {
                throw MutationError.categoryRequired
            }
            sourceCategory = c
        case (false, true):
            guard onLegCategoryID == nil || onLegCategoryID == rtaCategoryID else {
                throw MutationError.categoryNotAllowed
            }
            destCategory = rtaCategoryID
        default:
            guard onLegCategoryID == nil else { throw MutationError.categoryNotAllowed }
        }

        var copy = self
        let pair = TransferPairRow(budgetID: budget.id, status: .complete, createdAtEpoch: nowEpoch)
        copy.setTransferPair(pair)
        let noon = try calendar.noonEpoch(of: date)
        let transferPayee = systemPayeeID(.transfer)

        func makeLeg(account: AccountID, amount: Milliunits, category: CategoryID?) throws -> TransactionRow {
            let seq = try copy.allocateSourceSequence()
            return TransactionRow(
                budgetID: budget.id,
                accountID: account,
                payeeID: transferPayee,
                sourceKind: .manual,
                date: date,
                effectiveAtEpoch: noon,
                sourceOrderKey: .manual(sequence: seq),
                amountMilliunits: amount,
                cleared: .uncleared,
                approved: true,
                postingState: .posted,
                categoryID: category,
                transferPairID: pair.id,
                kind: .normal
            )
        }
        let sourceLeg = try makeLeg(account: sourceAccountID, amount: try negChecked(amount), category: sourceCategory)
        let destLeg = try makeLeg(account: destinationAccountID, amount: amount, category: destCategory)
        copy.setTransaction(sourceLeg)
        copy.setTransaction(destLeg)

        // Newly created legs have no valid standalone classification: unpairing
        // them later leaves them staged for explicit categorization.
        copy.setLegSnapshots(pair.id, [sourceLeg, destLeg].map { leg in
            TransferPairLegSnapshotRow(
                transferPairID: pair.id, transactionID: leg.id,
                payeeID: leg.payeeID, categoryID: nil, kind: .normal,
                postingState: .staged, stageReason: .transferPairUnpairNeedsCategorization,
                stageMetadata: nil, approved: leg.approved, cleared: leg.cleared,
                memo: leg.memo, capturedAtEpoch: nowEpoch, requiresUnpairResolution: true
            )
        })

        let result = try copy.runReplayAndApplyDecisions()
        for leg in [sourceLeg, destLeg] {
            if let d = result.postingDecisions[leg.id], d.postingState == .staged {
                throw MutationError.cardBalanceWouldBecomePositive
            }
        }
        copy.recordAudit(entityType: "transferPair", entityID: pair.id.description, eventKind: "create", nowEpoch: nowEpoch)
        try copy.bumpRevision()
        self = copy
        return pair.id
    }

    // MARK: - Pair two existing rows (§3.6 case 2, §4.3 resolution (d))

    /// Explicit "Pair transfer": equal/opposite amounts, compatible accounts,
    /// same currency, ±7 calendar days, same budget month. Reclassifies both
    /// existing rows — no insertion, register balance unchanged. Staged
    /// outcomes (card guard) are permitted for existing rows.
    @discardableResult
    public mutating func pairExistingTransactions(
        _ firstID: TransactionID,
        _ secondID: TransactionID,
        nowEpoch: Int64
    ) throws -> TransferPairID {
        guard let a = transactions[firstID], let b = transactions[secondID], firstID != secondID else {
            throw MutationError.transactionNotFound
        }
        for row in [a, b] {
            guard row.postingState != .voided else { throw MutationError.transactionNotFound }
            guard row.transferPairID == nil else { throw MutationError.transferLegsInvalid }
            guard row.splits == nil else { throw MutationError.splitNotAllowed }
            guard row.cleared != .reconciled else { throw MutationError.reconciledTransaction }
            guard row.sourceKind != .system else { throw MutationError.systemEntityImmutable }
            guard !isMonthClosed(row.date.budgetMonth) else { throw MutationError.closedMonth }
        }
        guard a.amountMilliunits != 0, a.amountMilliunits == (try negChecked(b.amountMilliunits)) else {
            throw MutationError.transferLegsInvalid
        }
        let source = a.amountMilliunits < 0 ? a : b
        let dest = a.amountMilliunits < 0 ? b : a
        guard let sourceAccount = accounts[source.accountID], let destAccount = accounts[dest.accountID] else {
            throw MutationError.accountNotFound
        }
        try validatePairAccounts(source: sourceAccount, destination: destAccount)
        guard a.date.budgetMonth == b.date.budgetMonth else { throw MutationError.transferLegsInvalid }
        guard abs(Self.civilDayNumber(a.date) - Self.civilDayNumber(b.date)) <= 7 else {
            throw MutationError.transferLegsInvalid
        }

        let sourceEligible = budgetEligible(sourceAccount, budgetCurrency: budget.currency)
        let destEligible = budgetEligible(destAccount, budgetCurrency: budget.currency)

        var copy = self
        let pair = TransferPairRow(budgetID: budget.id, status: .complete, createdAtEpoch: nowEpoch)
        copy.setTransferPair(pair)

        // Capture immutable standalone snapshots before reclassification.
        copy.setLegSnapshots(pair.id, [a, b].map { leg in
            var meta = leg.stageMetadata ?? StageMetadata()
            if meta.refundOfTransactionID == nil { meta.refundOfTransactionID = leg.refundOfTransactionID }
            if meta.proposedCategoryID == nil { meta.proposedCategoryID = leg.categoryID }
            return TransferPairLegSnapshotRow(
                transferPairID: pair.id, transactionID: leg.id,
                payeeID: leg.payeeID, categoryID: leg.categoryID, kind: leg.kind,
                postingState: leg.postingState, stageReason: leg.stageReason,
                stageMetadata: meta, approved: leg.approved, cleared: leg.cleared,
                memo: leg.memo, capturedAtEpoch: nowEpoch, requiresUnpairResolution: false
            )
        })

        let transferPayee = systemPayeeID(.transfer)
        for original in [a, b] {
            var leg = original
            leg.payeeID = transferPayee
            leg.kind = .normal
            leg.refundOfTransactionID = nil
            leg.stageMetadata = nil
            leg.stageReason = nil
            leg.transferPairID = pair.id
            leg.userEditedAtEpoch = nowEpoch
            // On-budget leg of an on↔off pair keeps its required category.
            let isOnLegOfOnOff =
                (sourceEligible != destEligible)
                && ((leg.id == source.id && sourceEligible) || (leg.id == dest.id && destEligible))
            if isOnLegOfOnOff {
                if leg.id == dest.id {
                    leg.categoryID = rtaCategoryID
                } else if leg.categoryID == nil || leg.categoryID == uncategorizedID {
                    throw MutationError.categoryRequired
                }
            } else {
                leg.categoryID = nil
            }
            copy.setTransaction(leg)
        }

        try copy.runReplayAndApplyDecisions()
        copy.recordAudit(entityType: "transferPair", entityID: pair.id.description, eventKind: "pairExisting", nowEpoch: nowEpoch)
        try copy.bumpRevision()
        self = copy
        return pair.id
    }

    // MARK: - Unpair (§3.8)

    /// Restores each leg's immutable pre-pair snapshot in the same mutation. A
    /// leg created inside pairing (no standalone snapshot) remains staged with
    /// `transferPairUnpairNeedsCategorization`; no sign-based RTA default is
    /// ever applied.
    public mutating func unpairTransferPair(_ pairID: TransferPairID, nowEpoch: Int64) throws {
        guard var pair = transferPairs[pairID], pair.status == .complete else {
            throw MutationError.transferPairNotFound
        }
        let snapshots = legSnapshots[pairID] ?? []
        let legs = transactions.values.filter { $0.transferPairID == pairID && $0.postingState != .voided }
        guard legs.count == 2 else { throw MutationError.transferLegsInvalid }
        for leg in legs where isMonthClosed(leg.date.budgetMonth) {
            throw MutationError.closedMonth
        }

        var copy = self
        for leg in legs {
            guard let snapshot = snapshots.first(where: { $0.transactionID == leg.id }) else {
                throw MutationError.transferLegsInvalid
            }
            var restored = leg
            restored.transferPairID = nil
            restored.payeeID = snapshot.payeeID
            restored.kind = snapshot.kind
            restored.approved = snapshot.approved
            restored.cleared = snapshot.cleared
            restored.memo = snapshot.memo
            restored.userEditedAtEpoch = nowEpoch
            if snapshot.requiresUnpairResolution {
                restored.categoryID = nil
                restored.stageMetadata = nil
                restored.postingState = .staged
                restored.stageReason = .transferPairUnpairNeedsCategorization
                restored.refundOfTransactionID = nil
            } else {
                restored.categoryID = snapshot.categoryID
                restored.stageMetadata = snapshot.stageMetadata
                restored.postingState = snapshot.postingState
                restored.stageReason = snapshot.stageReason
                restored.refundOfTransactionID = snapshot.stageMetadata?.refundOfTransactionID
            }
            copy.setTransaction(restored)
        }
        pair.status = .unpaired
        copy.setTransferPair(pair)
        try copy.runReplayAndApplyDecisions()
        copy.recordAudit(entityType: "transferPair", entityID: pairID.description, eventKind: "unpair", nowEpoch: nowEpoch)
        try copy.bumpRevision()
        self = copy
    }

    /// Resolves a leg that was created from a blank manual transfer pair and
    /// therefore has no standalone snapshot to restore after unpairing. The
    /// caller must make the standalone classification explicit; this method
    /// never applies the normal sign default on its own (§3.8).
    public mutating func resolveUnpairedTransferLeg(
        _ transactionID: TransactionID,
        categoryID requestedCategoryID: CategoryID? = nil,
        nowEpoch: Int64
    ) throws {
        guard var row = transactions[transactionID] else { throw MutationError.stagedRowNotFound }
        guard row.postingState == .staged,
              row.stageReason == .transferPairUnpairNeedsCategorization,
              row.transferPairID == nil else {
            throw MutationError.resolutionNotEligible
        }
        guard row.cleared != .reconciled,
              !reconciliationMembership.contains(transactionID) else {
            throw MutationError.reconciledTransaction
        }
        guard !isMonthClosed(row.date.budgetMonth) else { throw MutationError.closedMonth }
        guard let account = accounts[row.accountID], !account.closed else {
            throw MutationError.accountNotFound
        }

        let eligible = budgetEligible(account, budgetCurrency: budget.currency)
        let resolvedCategoryID: CategoryID?
        if !eligible {
            guard requestedCategoryID == nil else { throw MutationError.categoryNotAllowed }
            resolvedCategoryID = nil
        } else if row.amountMilliunits > 0 {
            // A positive standalone normal on-budget leg is an inflow. It may
            // be confirmed with nil from the UI, but it always resolves to RTA.
            guard requestedCategoryID == nil || requestedCategoryID == rtaCategoryID else {
                throw MutationError.categoryNotAllowed
            }
            resolvedCategoryID = rtaCategoryID
        } else {
            guard let requestedCategoryID else { throw MutationError.categoryRequired }
            resolvedCategoryID = requestedCategoryID
        }
        try validateCategoryChoice(
            account: account,
            kind: .normal,
            amount: row.amountMilliunits,
            categoryID: resolvedCategoryID,
            refundOf: nil
        )

        var copy = self
        row.kind = .normal
        row.categoryID = resolvedCategoryID
        row.refundOfTransactionID = nil
        row.stageReason = nil
        row.stageMetadata = nil
        row.postingState = .posted
        row.userEditedAtEpoch = nowEpoch
        copy.setTransaction(row)
        let result = try copy.runReplayAndApplyDecisions()
        guard result.postingDecisions[transactionID]?.postingState == .posted else {
            throw MutationError.resolutionGuardFailed
        }
        if let resolvedCategoryID {
            copy.updatePayeeLearning(
                payeeID: row.payeeID,
                categoryID: resolvedCategoryID,
                amount: row.amountMilliunits
            )
        }
        copy.recordAudit(
            entityType: "transaction",
            entityID: transactionID.description,
            eventKind: "resolveUnpairedTransferLeg",
            metadata: ["category": resolvedCategoryID?.description ?? "offBudget"],
            nowEpoch: nowEpoch
        )
        try copy.bumpRevision()
        self = copy
    }

    // MARK: - Delete pair (§3.8)

    /// Import identity or reconciliation membership on either leg → atomic
    /// soft-void of both legs (tombstones retained). Pure manual unreconciled
    /// pairs may be physically deleted.
    public mutating func deleteTransferPair(_ pairID: TransferPairID, nowEpoch: Int64) throws {
        guard var pair = transferPairs[pairID], pair.status != .voided else {
            throw MutationError.transferPairNotFound
        }
        let legs = transactions.values.filter { $0.transferPairID == pairID && $0.postingState != .voided }
        guard !legs.isEmpty else { throw MutationError.transferLegsInvalid }
        for leg in legs where isMonthClosed(leg.date.budgetMonth) {
            throw MutationError.closedMonth
        }
        let requiresSoftVoid = legs.contains {
            $0.sourceKind == .simplefin || $0.sourceKind == .file
                || reconciliationMembership.contains($0.id) || $0.cleared == .reconciled
        }

        var copy = self
        if requiresSoftVoid {
            for var leg in legs {
                leg.postingState = .voided
                leg.stageReason = nil
                copy.setTransaction(leg)
            }
            pair.status = .voided
            copy.setTransferPair(pair)
            copy.recordAudit(entityType: "transferPair", entityID: pairID.description, eventKind: "voidPair", nowEpoch: nowEpoch)
        } else {
            for leg in legs {
                copy.removeTransaction(leg.id)
            }
            copy.removeTransferPair(pairID)
            copy.removeLegSnapshots(pairID)
            copy.recordAudit(entityType: "transferPair", entityID: pairID.description, eventKind: "deletePair", nowEpoch: nowEpoch)
        }
        try copy.runReplayAndApplyDecisions()
        try copy.bumpRevision()
        self = copy
    }

    // MARK: - Staged-row resolutions (§3.5.3, §4.3)

    /// Budget-neutral `Card Debt Adjustment` resolution for eligible staged
    /// card rows. Register balance is unchanged; the projection gains the row
    /// once; rejected while `projectionBalanceAsIfResolved` would cross zero.
    public mutating func resolveStagedAsCardDebtAdjustment(_ transactionID: TransactionID, nowEpoch: Int64) throws {
        guard var row = transactions[transactionID] else { throw MutationError.stagedRowNotFound }
        guard row.postingState == .staged else { throw MutationError.stagedRowNotFound }
        guard !isMonthClosed(row.date.budgetMonth) else { throw MutationError.closedMonth }
        guard let account = accounts[row.accountID], account.type == .creditCard,
              budgetEligible(account, budgetCurrency: budget.currency)
        else { throw MutationError.resolutionNotEligible }
        switch row.stageReason {
        case .unlinkedCardInflow, .missingRefundOrigin, .overRefund, .cardBalanceWouldBecomePositive:
            break
        default:
            // crossMonthRefund uses the §3.5.3 recovery path; cash rows are
            // never card adjustments.
            throw MutationError.resolutionNotEligible
        }

        var copy = self
        row.kind = .adjustment
        row.payeeID = systemPayeeID(.cardDebtAdjustment)
        row.categoryID = nil
        row.refundOfTransactionID = nil
        row.stageMetadata = nil
        row.userEditedAtEpoch = nowEpoch
        copy.setTransaction(row)
        let result = try copy.runReplayAndApplyDecisions()
        guard result.postingDecisions[transactionID]?.postingState == .posted else {
            throw MutationError.resolutionGuardFailed
        }
        copy.recordAudit(
            entityType: "transaction", entityID: transactionID.description,
            eventKind: "resolveCardDebtAdjustment", nowEpoch: nowEpoch
        )
        try copy.bumpRevision()
        self = copy
    }

    /// Explicit cross-month refund-recovery (§3.5.3): payee `Card Debt
    /// Adjustment`, kind stays `refund`, materialized category RTA. Replay
    /// emits +r RTA activity plus the offsetting synthetic −r event to the
    /// refunding card's payment category at the same replay position.
    public mutating func resolveCrossMonthRefund(_ transactionID: TransactionID, nowEpoch: Int64) throws {
        guard var row = transactions[transactionID] else { throw MutationError.stagedRowNotFound }
        guard row.postingState == .staged, row.stageReason == .crossMonthRefund else {
            throw MutationError.resolutionNotEligible
        }
        guard !isMonthClosed(row.date.budgetMonth) else { throw MutationError.closedMonth }
        guard let account = accounts[row.accountID], account.type == .creditCard,
              budgetEligible(account, budgetCurrency: budget.currency)
        else { throw MutationError.resolutionNotEligible }

        var copy = self
        row.kind = .refund
        row.payeeID = systemPayeeID(.cardDebtAdjustment)
        row.categoryID = rtaCategoryID
        // Retain the origin link and prior proposed category for audit.
        row.userEditedAtEpoch = nowEpoch
        copy.setTransaction(row)
        let result = try copy.runReplayAndApplyDecisions()
        guard result.postingDecisions[transactionID]?.postingState == .posted else {
            throw MutationError.resolutionGuardFailed
        }
        copy.recordAudit(
            entityType: "transaction", entityID: transactionID.description,
            eventKind: "resolveCrossMonthRefund", nowEpoch: nowEpoch
        )
        try copy.bumpRevision()
        self = copy
    }

    /// Resolution (a) for `cashInflowWithCreditDebt`: categorize the staged
    /// cash inflow to RTA, creating RTA income without touching the category's
    /// creditDebt bucket.
    public mutating func resolveCashInflowToRTA(_ transactionID: TransactionID, nowEpoch: Int64) throws {
        guard var row = transactions[transactionID] else { throw MutationError.stagedRowNotFound }
        guard row.postingState == .staged, row.stageReason == .cashInflowWithCreditDebt else {
            throw MutationError.resolutionNotEligible
        }
        guard !isMonthClosed(row.date.budgetMonth) else { throw MutationError.closedMonth }

        var copy = self
        row.kind = .normal
        row.categoryID = rtaCategoryID
        row.refundOfTransactionID = nil
        row.stageMetadata = nil
        row.userEditedAtEpoch = nowEpoch
        copy.setTransaction(row)
        let result = try copy.runReplayAndApplyDecisions()
        guard result.postingDecisions[transactionID]?.postingState == .posted else {
            throw MutationError.resolutionGuardFailed
        }
        copy.recordAudit(
            entityType: "transaction", entityID: transactionID.description,
            eventKind: "resolveCashInflowToRTA", nowEpoch: nowEpoch
        )
        try copy.bumpRevision()
        self = copy
    }

    /// Explicit user classification of a posted positive cash-account row as a
    /// cash reimbursement (§3.5.3). If the target category currently carries
    /// `creditDebt`, the row is persisted `staged` with
    /// `cashInflowWithCreditDebt` — that is a designed outcome, not an error.
    public mutating func classifyAsCashReimbursement(
        _ transactionID: TransactionID,
        categoryID: CategoryID,
        originID: TransactionID? = nil,
        nowEpoch: Int64
    ) throws {
        guard var row = transactions[transactionID] else { throw MutationError.transactionNotFound }
        guard row.postingState == .posted || row.postingState == .needsCategory else {
            throw MutationError.resolutionNotEligible
        }
        guard row.cleared != .reconciled else { throw MutationError.reconciledTransaction }
        guard !isMonthClosed(row.date.budgetMonth) else { throw MutationError.closedMonth }
        guard let account = accounts[row.accountID], account.type.isCashLike,
              budgetEligible(account, budgetCurrency: budget.currency)
        else { throw MutationError.resolutionNotEligible }
        guard row.amountMilliunits > 0, row.kind == .normal else { throw MutationError.refundNotPositive }
        guard let category = categories[categoryID], category.kind == .spending, categoryID != uncategorizedID else {
            throw MutationError.categoryRequired
        }
        if let originID {
            guard let origin = transactions[originID], origin.postingState != .voided,
                  origin.accountID == row.accountID
            else { throw MutationError.refundOriginInvalid }
        }

        var copy = self
        row.kind = .refund
        row.categoryID = categoryID
        row.refundOfTransactionID = originID
        row.userEditedAtEpoch = nowEpoch
        copy.setTransaction(row)
        try copy.runReplayAndApplyDecisions()
        copy.recordAudit(
            entityType: "transaction", entityID: transactionID.description,
            eventKind: "classifyCashReimbursement", nowEpoch: nowEpoch
        )
        try copy.bumpRevision()
        self = copy
    }

    /// Resolution (a) of §4.3: link a staged card inflow to a same-month
    /// origin purchase. Replay validates the remaining-lot rule; an invalid
    /// link stays staged with its recomputed reason.
    public mutating func linkRefundOrigin(
        _ transactionID: TransactionID,
        originID: TransactionID,
        componentIndex: Int? = nil,
        nowEpoch: Int64
    ) throws {
        guard var row = transactions[transactionID] else { throw MutationError.stagedRowNotFound }
        guard row.postingState == .staged else { throw MutationError.stagedRowNotFound }
        guard !isMonthClosed(row.date.budgetMonth) else { throw MutationError.closedMonth }
        guard let origin = transactions[originID], origin.postingState != .voided,
              origin.accountID == row.accountID,
              origin.amountMilliunits < 0,
              origin.kind == .normal
        else { throw MutationError.refundOriginInvalid }
        if let components = origin.splits {
            guard let componentIndex, components.indices.contains(componentIndex) else {
                throw MutationError.refundOriginInvalid
            }
        } else {
            guard componentIndex == nil else { throw MutationError.refundOriginInvalid }
        }

        var copy = self
        row.kind = .refund
        row.refundOfTransactionID = originID
        row.refundOfComponentIndex = componentIndex
        var meta = row.stageMetadata ?? StageMetadata()
        meta.refundOfTransactionID = originID
        row.stageMetadata = meta
        row.userEditedAtEpoch = nowEpoch
        copy.setTransaction(row)
        try copy.runReplayAndApplyDecisions()
        copy.recordAudit(
            entityType: "transaction", entityID: transactionID.description,
            eventKind: "linkRefundOrigin", nowEpoch: nowEpoch
        )
        try copy.bumpRevision()
        self = copy
    }
}

import Foundation

/// What permanently deleting a closed account removed or rewrote.
public struct AccountDeletionSummary: Sendable, Equatable {
    public var removedTransactions = 0
    public var removedSchedules = 0
    public var removedRules = 0
    public var updatedRules = 0
    public var removedPaymentCategory = false
    /// The card's payment category held assignments in past months. It is
    /// kept as a hidden ordinary category so those months keep their totals.
    public var keptPaymentCategoryHidden = false

    public init() {}
}

extension BudgetWorkspace {
    /// Permanently removes a closed account and everything that belongs only
    /// to it: its transactions (voided or not), import identities, review
    /// items, reconciliations, file-import batches, and schedules. This is the
    /// one deliberate exception to "history is never deleted", so it is only
    /// offered for closed accounts and carries the same guards as Void History
    /// and Close: it refuses when a row sits in a closed month, is reconciled,
    /// is a transfer leg, or is referenced by a row on another account.
    ///
    /// Anything owned by another object is rewritten instead of lost:
    /// - a rule that requires this account can never match again, so it is
    ///   removed; in an "any" rule only the dead condition is dropped;
    /// - a credit card's payment category is removed, or kept hidden as an
    ///   ordinary category when it holds assignments;
    /// - schedule reviews and occurrences elsewhere drop the removed rows.
    /// The audit trail keeps an `accountDeleted` event with the counts.
    @discardableResult
    public mutating func deleteClosedAccount(accountID: AccountID, nowEpoch: Int64) throws -> AccountDeletionSummary {
        guard let account = accounts[accountID] else { throw MutationError.accountNotFound }
        guard account.closed else { throw MutationError.accountNotClosed }

        let ownRows = transactions.values.filter { $0.accountID == accountID }
        let ownIDs = Set(ownRows.map(\.id))
        for row in ownRows {
            if row.postingState != .voided {
                guard !isMonthClosed(row.date.budgetMonth) else { throw MutationError.closedMonth }
                guard row.cleared != .reconciled, !reconciliationMembership.contains(row.id) else {
                    throw MutationError.reconciledTransaction
                }
            }
            guard row.transferPairID == nil else { throw MutationError.accountHasTransferPairs }
        }
        let foreignReference = transactions.values.contains { row in
            guard !ownIDs.contains(row.id), let origin = row.refundOfTransactionID else { return false }
            return ownIDs.contains(origin)
        }
        guard !foreignReference else { throw MutationError.accountHasCrossAccountLinks }
        var copy = self
        var summary = AccountDeletionSummary()

        // Review items and import identities that hang off this account.
        let importIDs = Set(ownRows.compactMap { copy.simpleFINImports[$0.id]?.id })
        for (id, conflict) in copy.syncConflicts {
            let touchesAccount = conflict.transactionID.map(ownIDs.contains) == true
                || conflict.simpleFINImportID.map(importIDs.contains) == true
            if touchesAccount { copy.removeSyncConflict(id) }
        }
        for (id, discrepancy) in copy.snapshotDiscrepancies where discrepancy.accountID == accountID {
            copy.removeSnapshotDiscrepancy(id)
        }
        for id in ownIDs {
            copy.removeSimpleFINImport(transactionID: id)
            copy.removeFileImport(transactionID: id)
            copy.removeReconciliationMembership(id)
            copy.removeTransaction(id)
        }
        summary.removedTransactions = ownIDs.count
        for (id, reconciliation) in copy.reconciliations where reconciliation.accountID == accountID {
            copy.removeReconciliation(id)
        }
        for (id, batch) in copy.importBatches where batch.accountID == accountID {
            copy.removeImportBatch(id)
        }

        // Schedules on or into this account, with their occurrences and reviews.
        let doomedSchedules = Set(copy.schedules.values.filter {
            $0.accountID == accountID || $0.transferToAccountID == accountID
        }.map(\.id))
        for id in doomedSchedules { copy.removeSchedule(id) }
        summary.removedSchedules = doomedSchedules.count
        for (key, occurrence) in copy.scheduleOccurrences {
            if doomedSchedules.contains(occurrence.scheduleID) {
                copy.removeScheduleOccurrence(key)
            } else if let linked = occurrence.transactionID, ownIDs.contains(linked) {
                copy.removeScheduleOccurrence(key)
            }
        }
        for (id, review) in copy.scheduleReviews {
            if doomedSchedules.contains(review.scheduleID) {
                copy.removeScheduleReview(id)
                continue
            }
            let remaining = review.candidateTransactionIDs.filter { !ownIDs.contains($0) }
            guard remaining.count != review.candidateTransactionIDs.count else { continue }
            var updated = review
            updated.candidateTransactionIDs = remaining
            if remaining.isEmpty, updated.status == .open {
                updated.status = .dismissed
                updated.resolvedAtEpoch = nowEpoch
            }
            copy.setScheduleReview(updated)
        }

        // Rules conditioned on the account.
        for rule in copy.automationRules.values {
            let dead = rule.conditions.filter { if case .account(accountID) = $0 { return true } else { return false } }
            guard !dead.isEmpty else { continue }
            let remaining = rule.conditions.filter { if case .account(accountID) = $0 { return false } else { return true } }
            if rule.matchMode == .all || remaining.isEmpty {
                copy.removeAutomationRule(rule.id)
                summary.removedRules += 1
            } else {
                var updated = rule
                updated.conditions = remaining
                copy.setAutomationRule(updated)
                summary.updatedRules += 1
            }
        }

        // A card's payment category.
        if let paymentID = copy.paymentCategoryID(forCard: accountID), let payment = copy.categories[paymentID] {
            let hasAssignments = copy.allocations.values.contains { $0.categoryID == paymentID && $0.budgetedMilliunits != 0 }
            if hasAssignments {
                copy.setCategory(CategoryRow(
                    id: payment.id, budgetID: payment.budgetID, groupID: payment.groupID,
                    name: "\(payment.name) (deleted card)", sortOrder: payment.sortOrder,
                    hidden: true, kind: .spending, linkedAccountID: nil, systemKind: nil, note: payment.note
                ))
                summary.keptPaymentCategoryHidden = true
            } else {
                copy.removeCategory(paymentID)
                summary.removedPaymentCategory = true
            }
        }

        copy.removeAccount(accountID)
        try copy.runReplayAndApplyDecisions()
        copy.recordAudit(
            entityType: "account",
            entityID: accountID.description,
            eventKind: "accountDeleted",
            metadata: [
                "name": account.name,
                "removedTransactions": "\(summary.removedTransactions)",
                "removedSchedules": "\(summary.removedSchedules)",
                "removedRules": "\(summary.removedRules)",
                "updatedRules": "\(summary.updatedRules)",
                "paymentCategory": summary.keptPaymentCategoryHidden ? "keptHidden" : (summary.removedPaymentCategory ? "removed" : "none")
            ],
            nowEpoch: nowEpoch
        )
        try copy.bumpRevision()
        _ = try BudgetWorkspace(snapshot: copy.snapshot()) // fail closed on any dangling reference
        self = copy
        return summary
    }
}

extension SimpleFINConnectionState {
    /// Drops links bound to a deleted local account, with their reconnect
    /// provenance. Re-linking the remote account later starts fresh.
    @discardableResult
    public mutating func removeLinks(boundTo accountID: AccountID) -> Int {
        let doomed = Set(links.filter { $0.localAccountID == accountID }.map(\.identity))
        guard !doomed.isEmpty else { return 0 }
        links.removeAll { doomed.contains($0.identity) }
        disconnectPausedLinkIdentities.removeAll { doomed.contains($0) }
        authRevokedLinkIdentitiesAwaitingReconnect.removeAll { doomed.contains($0) }
        return doomed.count
    }
}

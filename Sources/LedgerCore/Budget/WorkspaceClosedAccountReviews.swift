import Foundation

/// What closing an account (or the explicit cleanup action) did to review
/// items that pointed at it.
public struct ClosedAccountReviewCleanup: Sendable, Equatable {
    public let dismissedConflicts: Int
    public let resolvedDiscrepancies: Int

    public init(dismissedConflicts: Int, resolvedDiscrepancies: Int) {
        self.dismissedConflicts = dismissedConflicts
        self.resolvedDiscrepancies = resolvedDiscrepancies
    }

    public var total: Int { dismissedConflicts + resolvedDiscrepancies }
}

extension BudgetWorkspace {
    /// The local account a sync conflict concerns. The conflict's own
    /// transaction wins; when that row was removed (void-and-close deletes
    /// manual rows) the imported row behind the conflict decides.
    public func accountID(forConflict conflict: SyncConflictRow) -> AccountID? {
        if let transactionID = conflict.transactionID, let row = transactions[transactionID] {
            return row.accountID
        }
        if let importID = conflict.simpleFINImportID,
           let record = simpleFINImports.values.first(where: { $0.id == importID }),
           let row = transactions[record.transactionID] {
            return row.accountID
        }
        return nil
    }

    /// True when a review item can no longer be decided because the account
    /// it concerns is closed. The Review Queue offers a dismissal for these.
    public func conflictConcernsClosedAccount(_ conflict: SyncConflictRow) -> Bool {
        guard let accountID = accountID(forConflict: conflict) else { return false }
        return accounts[accountID]?.closed == true
    }

    public func discrepancyConcernsClosedAccount(_ discrepancy: SnapshotDiscrepancyRow) -> Bool {
        accounts[discrepancy.accountID]?.closed == true
    }

    /// Settles every open review item for a closed account without touching
    /// the ledger. Conflicts become `dismissed`; discrepancies are resolved
    /// with no adjustment. Each item gets an audit event naming the cause, so
    /// the history shows why it left the queue. Callers own the revision bump.
    @discardableResult
    mutating func settleOpenReviewItems(forClosedAccount accountID: AccountID, nowEpoch: Int64) -> ClosedAccountReviewCleanup {
        guard accounts[accountID]?.closed == true else {
            return ClosedAccountReviewCleanup(dismissedConflicts: 0, resolvedDiscrepancies: 0)
        }
        var conflicts = 0
        for id in syncConflicts.keys.sorted() {
            guard var conflict = syncConflicts[id],
                  conflict.status == .open,
                  self.accountID(forConflict: conflict) == accountID else { continue }
            conflict.status = .dismissed
            conflict.resolvedAtEpoch = nowEpoch
            setSyncConflict(conflict)
            recordAudit(
                entityType: "syncConflict",
                entityID: id.description,
                eventKind: "syncConflictDismissed",
                metadata: ["cause": "accountClosed", "accountID": accountID.description],
                nowEpoch: nowEpoch
            )
            conflicts += 1
        }
        var discrepancies = 0
        for id in snapshotDiscrepancies.keys.sorted() {
            guard var discrepancy = snapshotDiscrepancies[id],
                  discrepancy.status == .open,
                  discrepancy.accountID == accountID else { continue }
            discrepancy.status = .resolved
            discrepancy.resolutionReason = .manualAttestation
            discrepancy.adjustmentTransactionID = nil
            discrepancy.resolvedAtEpoch = nowEpoch
            setSnapshotDiscrepancy(discrepancy)
            recordAudit(
                entityType: "snapshotDiscrepancy",
                entityID: id.description,
                eventKind: "snapshotDiscrepancyResolved",
                metadata: [
                    "reason": SnapshotDiscrepancyResolutionReason.manualAttestation.rawValue,
                    "artifact": "none",
                    "cause": "accountClosed",
                    "accountID": accountID.description
                ],
                nowEpoch: nowEpoch
            )
            discrepancies += 1
        }
        return ClosedAccountReviewCleanup(dismissedConflicts: conflicts, resolvedDiscrepancies: discrepancies)
    }

    /// Explicit cleanup for review items stranded by an account closed before
    /// closing settled them. Rejects open accounts: their items still need a
    /// real decision.
    @discardableResult
    public mutating func dismissReviewItems(forClosedAccount accountID: AccountID, nowEpoch: Int64) throws -> ClosedAccountReviewCleanup {
        guard let account = accounts[accountID] else { throw MutationError.accountNotFound }
        guard account.closed else { throw MutationError.accountNotClosed }
        var copy = self
        let cleanup = copy.settleOpenReviewItems(forClosedAccount: accountID, nowEpoch: nowEpoch)
        guard cleanup.total > 0 else { return cleanup }
        try copy.bumpRevision()
        self = copy
        return cleanup
    }
}

extension BudgetWorkspaceSnapshot {
    /// Snapshot twin of `BudgetWorkspace.accountID(forConflict:)` for views
    /// that only hold the published snapshot.
    public func accountID(forConflict conflict: SyncConflictRow) -> AccountID? {
        if let transactionID = conflict.transactionID,
           let row = transactions.first(where: { $0.id == transactionID }) {
            return row.accountID
        }
        if let importID = conflict.simpleFINImportID,
           let record = simpleFINImports.first(where: { $0.id == importID }),
           let row = transactions.first(where: { $0.id == record.transactionID }) {
            return row.accountID
        }
        return nil
    }

    /// The closed account a review item is stranded on, if any.
    public func closedAccountID(forConflict conflict: SyncConflictRow) -> AccountID? {
        guard let accountID = accountID(forConflict: conflict),
              accounts.first(where: { $0.id == accountID })?.closed == true else { return nil }
        return accountID
    }

    public func closedAccountID(forDiscrepancy discrepancy: SnapshotDiscrepancyRow) -> AccountID? {
        accounts.first(where: { $0.id == discrepancy.accountID })?.closed == true ? discrepancy.accountID : nil
    }

    /// Open conflicts plus open discrepancies stranded on one closed account.
    public func openReviewItemCount(forClosedAccount accountID: AccountID) -> Int {
        syncConflicts.filter { $0.status == .open && closedAccountID(forConflict: $0) == accountID }.count
            + snapshotDiscrepancies.filter { $0.status == .open && closedAccountID(forDiscrepancy: $0) == accountID }.count
    }
}

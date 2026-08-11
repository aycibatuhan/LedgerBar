import Foundation

// MARK: - Sync-conflict resolution

/// Explicit, stale-checked command for resolving one persisted sync conflict.
/// It contains only local identifiers and fixed enum choices; remote metadata
/// remains on the conflict row and is never echoed through this API.
public struct SyncConflictResolutionCommand: Sendable, Equatable {
    public let budgetID: BudgetID
    public let conflictID: SyncConflictID
    public let expectedBudgetRevision: Int64
    /// Optional optimistic fingerprint for a row displayed by a local edit
    /// sheet. This is intentionally separate from the workspace revision:
    /// unrelated changes must not make a review action stale, but an
    /// intervening edit to the reviewed transaction must.
    public let expectedTransactionFingerprint: String?
    public let choice: SyncConflictResolutionChoice

    public init(
        budgetID: BudgetID,
        conflictID: SyncConflictID,
        expectedBudgetRevision: Int64,
        expectedTransactionFingerprint: String? = nil,
        choice: SyncConflictResolutionChoice
    ) {
        self.budgetID = budgetID
        self.conflictID = conflictID
        self.expectedBudgetRevision = expectedBudgetRevision
        self.expectedTransactionFingerprint = expectedTransactionFingerprint
        self.choice = choice
    }
}

public enum SyncConflictResolutionChoice: Sendable, Equatable {
    case remoteChanged(RemoteChangedResolution)
    case remoteDisappeared(RemoteDisappearedResolution)
    case manualPotentialDuplicate(ManualPotentialDuplicateResolution)
}

public enum RemoteChangedResolution: Sendable, Equatable {
    case keepLocal
    case acceptRemote
}

public enum RemoteDisappearedResolution: Sendable, Equatable {
    case keepLocal
    case editLocal([RemoteDisappearedLocalEdit])
    case softVoidImported
}

/// The bounded subset of existing transaction edits that can accompany an
/// explicit disappearance decision. Imported amount/account ownership and
/// transfer/refund identity are deliberately absent.
public enum RemoteDisappearedLocalEdit: Sendable, Equatable {
    case date(BudgetDate)
    case category(CategoryID)
    case memo(String?)
    case approval(Bool)
    case cleared(ClearedState)
}

public enum ManualPotentialDuplicateResolution: Sendable, Equatable {
    case keepBoth
    case softVoidImported
    case deleteManual
}

/// Fixed, bounded action values used by results and sanitized audit metadata.
public enum SyncConflictResolutionAction: String, Sendable, Equatable {
    case remoteChangedKeepLocal
    case remoteChangedAcceptRemote
    case remoteDisappearedKeepLocal
    case remoteDisappearedEditLocal
    case remoteDisappearedSoftVoidImported
    case manualPotentialDuplicateKeepBoth
    case manualPotentialDuplicateSoftVoidImported
    case manualPotentialDuplicateDeleteManual
}

public struct SyncConflictResolutionResult: Sendable, Equatable {
    public let conflictID: SyncConflictID
    public let status: SyncConflictStatus
    public let action: SyncConflictResolutionAction
    public let affectedTransactionIDs: [TransactionID]
    public let budgetRevision: Int64

    public init(
        conflictID: SyncConflictID,
        status: SyncConflictStatus,
        action: SyncConflictResolutionAction,
        affectedTransactionIDs: [TransactionID],
        budgetRevision: Int64
    ) {
        self.conflictID = conflictID
        self.status = status
        self.action = action
        self.affectedTransactionIDs = affectedTransactionIDs
        self.budgetRevision = budgetRevision
    }
}

// MARK: - Snapshot-discrepancy resolution

/// Optimistic version of the exact observed snapshot facts presented to the
/// user. It intentionally excludes unrelated later workspace revisions.
public struct SnapshotDiscrepancyVersion: Sendable, Equatable {
    public let observedEpoch: Int64
    public let remoteBalanceMilliunits: Milliunits
    public let localRegisterMilliunits: Milliunits
    public let differenceMilliunits: Milliunits

    public init(
        observedEpoch: Int64,
        remoteBalanceMilliunits: Milliunits,
        localRegisterMilliunits: Milliunits,
        differenceMilliunits: Milliunits
    ) {
        self.observedEpoch = observedEpoch
        self.remoteBalanceMilliunits = remoteBalanceMilliunits
        self.localRegisterMilliunits = localRegisterMilliunits
        self.differenceMilliunits = differenceMilliunits
    }

    public init(discrepancy: SnapshotDiscrepancyRow) {
        self.init(
            observedEpoch: discrepancy.observedEpoch,
            remoteBalanceMilliunits: discrepancy.remoteBalanceMilliunits,
            localRegisterMilliunits: discrepancy.localRegisterMilliunits,
            differenceMilliunits: discrepancy.differenceMilliunits
        )
    }
}

/// Closed, non-textual confirmation. Unknown or empty serialized values fail
/// Codable decoding instead of becoming persisted free-form attestations.
public enum SnapshotDiscrepancyManualAttestation: String, Codable, Sendable, Equatable {
    case confirmedWithoutAccountingAdjustment
}

public enum SnapshotDiscrepancyResolutionChoice: Sendable, Equatable {
    case adjustment
    case accountClosedOffBudget
    case manualAttestation(SnapshotDiscrepancyManualAttestation)
}

public struct SnapshotDiscrepancyResolutionCommand: Sendable, Equatable {
    public let budgetID: BudgetID
    public let discrepancyID: SnapshotDiscrepancyID
    public let expectedVersion: SnapshotDiscrepancyVersion
    public let choice: SnapshotDiscrepancyResolutionChoice

    public init(
        budgetID: BudgetID,
        discrepancyID: SnapshotDiscrepancyID,
        expectedVersion: SnapshotDiscrepancyVersion,
        choice: SnapshotDiscrepancyResolutionChoice
    ) {
        self.budgetID = budgetID
        self.discrepancyID = discrepancyID
        self.expectedVersion = expectedVersion
        self.choice = choice
    }
}

public enum SnapshotDiscrepancyResolutionArtifact: Sendable, Equatable {
    case none
    case adjustment(TransactionID)
    case offBudgetSuccessor(AccountID)
}

public struct SnapshotDiscrepancyResolutionResult: Sendable, Equatable {
    public let discrepancyID: SnapshotDiscrepancyID
    public let reason: SnapshotDiscrepancyResolutionReason
    public let artifact: SnapshotDiscrepancyResolutionArtifact
    public let budgetRevision: Int64

    public init(
        discrepancyID: SnapshotDiscrepancyID,
        reason: SnapshotDiscrepancyResolutionReason,
        artifact: SnapshotDiscrepancyResolutionArtifact,
        budgetRevision: Int64
    ) {
        self.discrepancyID = discrepancyID
        self.reason = reason
        self.artifact = artifact
        self.budgetRevision = budgetRevision
    }
}

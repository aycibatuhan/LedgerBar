import Foundation

/// Budget row. `currency`, `timeZoneIdentifier`, and `firstMonth` are immutable
/// after creation. `lastObservedBudgetMonth` is monotonic: the injected budget
/// clock may advance it but never decreases it.
public struct BudgetRow: Sendable, Equatable, Identifiable, Codable {
    public var id: BudgetID
    public var name: String
    public let currency: String
    public let timeZoneIdentifier: String
    public let firstMonth: BudgetMonth
    public var lastObservedBudgetMonth: BudgetMonth
    /// Single source-order allocator shared by `manual:` and `system:` keys.
    public var nextLocalSourceSequence: Int64
    public var createdAtEpoch: Int64
    public var revision: Int64

    public init(
        id: BudgetID = BudgetID(),
        name: String,
        currency: String,
        timeZoneIdentifier: String,
        firstMonth: BudgetMonth,
        lastObservedBudgetMonth: BudgetMonth? = nil,
        nextLocalSourceSequence: Int64 = 0,
        createdAtEpoch: Int64 = 0,
        revision: Int64 = 0
    ) {
        self.id = id
        self.name = name
        self.currency = currency
        self.timeZoneIdentifier = timeZoneIdentifier
        self.firstMonth = firstMonth
        self.lastObservedBudgetMonth = lastObservedBudgetMonth ?? firstMonth
        self.nextLocalSourceSequence = nextLocalSourceSequence
        self.createdAtEpoch = createdAtEpoch
        self.revision = revision
    }
}

public struct AccountRow: Sendable, Equatable, Identifiable, Codable {
    public var id: AccountID
    public var budgetID: BudgetID
    public var name: String
    public let type: AccountType
    /// Immutable after creation in v1 (§5.4).
    public let onBudget: Bool
    public var closed: Bool
    public var currency: String
    public var historyIncomplete: Bool
    public var createdAtEpoch: Int64

    public init(
        id: AccountID = AccountID(),
        budgetID: BudgetID,
        name: String,
        type: AccountType,
        onBudget: Bool,
        closed: Bool = false,
        currency: String,
        historyIncomplete: Bool = false,
        createdAtEpoch: Int64 = 0
    ) {
        self.id = id
        self.budgetID = budgetID
        self.name = name
        self.type = type
        self.onBudget = onBudget
        self.closed = closed
        self.currency = currency
        self.historyIncomplete = historyIncomplete
        self.createdAtEpoch = createdAtEpoch
    }
}

/// `budgetEligible` (§2.3/§3.5.3): the account participates in envelope
/// projection, card guards, and conservation checks only while it is an open,
/// on-budget account whose currency matches the budget currency. Closed
/// accounts remain available for historical register/import audit but are
/// excluded after the explicit close workflow.
public func budgetEligible(_ account: AccountRow, budgetCurrency: String) -> Bool {
    !account.closed && account.onBudget && account.currency == budgetCurrency
}

public struct CategoryGroupRow: Sendable, Equatable, Identifiable, Codable {
    public var id: CategoryGroupID
    public var budgetID: BudgetID
    public var name: String
    public var sortOrder: Int
    public var hidden: Bool

    public init(
        id: CategoryGroupID = CategoryGroupID(),
        budgetID: BudgetID,
        name: String,
        sortOrder: Int,
        hidden: Bool = false
    ) {
        self.id = id
        self.budgetID = budgetID
        self.name = name
        self.sortOrder = sortOrder
        self.hidden = hidden
    }
}

public struct CategoryRow: Sendable, Equatable, Identifiable, Codable {
    public var id: CategoryID
    public var budgetID: BudgetID
    public var groupID: CategoryGroupID
    public var name: String
    public var sortOrder: Int
    public var hidden: Bool
    public let kind: CategoryKind
    /// For `cc_payment` categories: the single credit-card account they pay.
    public var linkedAccountID: AccountID?
    public let systemKind: CategorySystemKind?
    public var note: String?

    public init(
        id: CategoryID = CategoryID(),
        budgetID: BudgetID,
        groupID: CategoryGroupID,
        name: String,
        sortOrder: Int,
        hidden: Bool = false,
        kind: CategoryKind,
        linkedAccountID: AccountID? = nil,
        systemKind: CategorySystemKind? = nil,
        note: String? = nil
    ) {
        self.id = id
        self.budgetID = budgetID
        self.groupID = groupID
        self.name = name
        self.sortOrder = sortOrder
        self.hidden = hidden
        self.kind = kind
        self.linkedAccountID = linkedAccountID
        self.systemKind = systemKind
        self.note = note
    }
}

public struct PayeeRow: Sendable, Equatable, Identifiable, Codable {
    public var id: PayeeID
    public var budgetID: BudgetID
    public let systemKind: PayeeSystemKind?
    public var namespace: PayeeNamespace
    /// Normalized (NFKC + uppercase + whitespace-collapsed); unique within namespace.
    public var name: String
    public var displayName: String
    public var lastUsedCategoryID: CategoryID?
    public var hidden: Bool

    public init(
        id: PayeeID = PayeeID(),
        budgetID: BudgetID,
        systemKind: PayeeSystemKind? = nil,
        namespace: PayeeNamespace,
        name: String,
        displayName: String,
        lastUsedCategoryID: CategoryID? = nil,
        hidden: Bool = false
    ) {
        self.id = id
        self.budgetID = budgetID
        self.systemKind = systemKind
        self.namespace = namespace
        self.name = name
        self.displayName = displayName
        self.lastUsedCategoryID = lastUsedCategoryID
        self.hidden = hidden
    }
}

/// Sparse monthly allocation. `budgeted_milliunits` may be negative only as the
/// audited result of `moveMoney`; `setBudgeted` accepts only `>= 0`.
public struct AllocationRow: Sendable, Equatable, Codable {
    public var budgetID: BudgetID
    public var categoryID: CategoryID
    public var month: BudgetMonth
    public var budgetedMilliunits: Milliunits

    public init(budgetID: BudgetID, categoryID: CategoryID, month: BudgetMonth, budgetedMilliunits: Milliunits) {
        self.budgetID = budgetID
        self.categoryID = categoryID
        self.month = month
        self.budgetedMilliunits = budgetedMilliunits
    }
}

/// Sanitized staged-row metadata (§2.1). Preserves the original/proposed
/// category, refund origin, transfer-pair ID, and triggering fields needed for
/// deterministic re-staging. Never contains credentials or free-form remote
/// payloads.
public struct StageMetadata: Sendable, Equatable, Codable {
    public var proposedCategoryID: CategoryID?
    public var originalCategoryID: CategoryID?
    public var refundOfTransactionID: TransactionID?
    public var transferPairID: TransferPairID?
    public var triggeringBalanceMilliunits: Milliunits?
    public var triggeringReason: String?

    public init(
        proposedCategoryID: CategoryID? = nil,
        originalCategoryID: CategoryID? = nil,
        refundOfTransactionID: TransactionID? = nil,
        transferPairID: TransferPairID? = nil,
        triggeringBalanceMilliunits: Milliunits? = nil,
        triggeringReason: String? = nil
    ) {
        self.proposedCategoryID = proposedCategoryID
        self.originalCategoryID = originalCategoryID
        self.refundOfTransactionID = refundOfTransactionID
        self.transferPairID = transferPairID
        self.triggeringBalanceMilliunits = triggeringBalanceMilliunits
        self.triggeringReason = triggeringReason
    }
}

public struct TransactionRow: Sendable, Equatable, Identifiable, Codable {
    public var id: TransactionID
    public var budgetID: BudgetID
    public var accountID: AccountID
    public var payeeID: PayeeID?
    public var sourceKind: SourceKind
    public var date: BudgetDate
    /// SimpleFIN `posted` epoch for imported rows; local date-noon for manual
    /// rows. `nil` falls back to date-noon at replay time.
    public var effectiveAtEpoch: Int64?
    public var sourceOrderKey: SourceOrderKey
    public var memo: String?
    public var amountMilliunits: Milliunits
    public var cleared: ClearedState
    public var approved: Bool
    public var flagColor: FlagColor?
    public var postingState: PostingState
    public var stageReason: StageReason?
    public var stageMetadata: StageMetadata?
    public var userEditedAtEpoch: Int64?
    public var categoryID: CategoryID?
    public var transferPairID: TransferPairID?
    public var refundOfTransactionID: TransactionID?
    public var kind: TransactionKind

    public init(
        id: TransactionID = TransactionID(),
        budgetID: BudgetID,
        accountID: AccountID,
        payeeID: PayeeID?,
        sourceKind: SourceKind,
        date: BudgetDate,
        effectiveAtEpoch: Int64?,
        sourceOrderKey: SourceOrderKey,
        memo: String? = nil,
        amountMilliunits: Milliunits,
        cleared: ClearedState = .uncleared,
        approved: Bool = false,
        flagColor: FlagColor? = nil,
        postingState: PostingState,
        stageReason: StageReason? = nil,
        stageMetadata: StageMetadata? = nil,
        userEditedAtEpoch: Int64? = nil,
        categoryID: CategoryID? = nil,
        transferPairID: TransferPairID? = nil,
        refundOfTransactionID: TransactionID? = nil,
        kind: TransactionKind = .normal
    ) {
        self.id = id
        self.budgetID = budgetID
        self.accountID = accountID
        self.payeeID = payeeID
        self.sourceKind = sourceKind
        self.date = date
        self.effectiveAtEpoch = effectiveAtEpoch
        self.sourceOrderKey = sourceOrderKey
        self.memo = memo
        self.amountMilliunits = amountMilliunits
        self.cleared = cleared
        self.approved = approved
        self.flagColor = flagColor
        self.postingState = postingState
        self.stageReason = stageReason
        self.stageMetadata = stageMetadata
        self.userEditedAtEpoch = userEditedAtEpoch
        self.categoryID = categoryID
        self.transferPairID = transferPairID
        self.refundOfTransactionID = refundOfTransactionID
        self.kind = kind
    }
}

public struct TransferPairRow: Sendable, Equatable, Identifiable, Codable {
    public var id: TransferPairID
    public var budgetID: BudgetID
    public var status: TransferPairStatus
    public var createdAtEpoch: Int64

    public init(id: TransferPairID = TransferPairID(), budgetID: BudgetID, status: TransferPairStatus, createdAtEpoch: Int64 = 0) {
        self.id = id
        self.budgetID = budgetID
        self.status = status
        self.createdAtEpoch = createdAtEpoch
    }
}

/// Immutable pre-pair snapshot of one transfer leg (§2.1). Restored exactly on
/// unpair; `requiresUnpairResolution` marks legs created inside pairing that
/// have no valid standalone classification.
public struct TransferPairLegSnapshotRow: Sendable, Equatable, Codable {
    public var transferPairID: TransferPairID
    public var transactionID: TransactionID
    public var payeeID: PayeeID?
    public var categoryID: CategoryID?
    public var kind: TransactionKind
    public var postingState: PostingState
    public var stageReason: StageReason?
    public var stageMetadata: StageMetadata?
    public var approved: Bool
    public var cleared: ClearedState
    public var memo: String?
    public var capturedAtEpoch: Int64
    public var requiresUnpairResolution: Bool

    public init(
        transferPairID: TransferPairID,
        transactionID: TransactionID,
        payeeID: PayeeID?,
        categoryID: CategoryID?,
        kind: TransactionKind,
        postingState: PostingState,
        stageReason: StageReason?,
        stageMetadata: StageMetadata?,
        approved: Bool,
        cleared: ClearedState,
        memo: String?,
        capturedAtEpoch: Int64 = 0,
        requiresUnpairResolution: Bool = false
    ) {
        self.transferPairID = transferPairID
        self.transactionID = transactionID
        self.payeeID = payeeID
        self.categoryID = categoryID
        self.kind = kind
        self.postingState = postingState
        self.stageReason = stageReason
        self.stageMetadata = stageMetadata
        self.approved = approved
        self.cleared = cleared
        self.memo = memo
        self.capturedAtEpoch = capturedAtEpoch
        self.requiresUnpairResolution = requiresUnpairResolution
    }
}

public struct ClosedMonthRow: Sendable, Equatable, Codable {
    public var budgetID: BudgetID
    public var month: BudgetMonth
    public var status: ClosedMonthStatus
    public var closedAtEpoch: Int64
    public var reopenedAtEpoch: Int64?

    public init(budgetID: BudgetID, month: BudgetMonth, status: ClosedMonthStatus, closedAtEpoch: Int64 = 0, reopenedAtEpoch: Int64? = nil) {
        self.budgetID = budgetID
        self.month = month
        self.status = status
        self.closedAtEpoch = closedAtEpoch
        self.reopenedAtEpoch = reopenedAtEpoch
    }
}

/// Audit trail for staged-row resolutions, explicit pairing, reconciliation
/// undo, and other user-visible accounting mutations. Metadata is sanitized —
/// never secrets, tokens, or URLs.
public struct AuditEventRow: Sendable, Equatable, Identifiable, Codable {
    public var id: AuditEventID
    public var budgetID: BudgetID
    public var entityType: String
    public var entityID: String
    public var eventKind: String
    public var metadata: [String: String]
    public var createdAtEpoch: Int64

    public init(
        id: AuditEventID = AuditEventID(),
        budgetID: BudgetID,
        entityType: String,
        entityID: String,
        eventKind: String,
        metadata: [String: String] = [:],
        createdAtEpoch: Int64 = 0
    ) {
        self.id = id
        self.budgetID = budgetID
        self.entityType = entityType
        self.entityID = entityID
        self.eventKind = eventKind
        self.metadata = metadata
        self.createdAtEpoch = createdAtEpoch
    }
}

/// One completed (or undone) reconciliation (§3.9 steps 6–7).
public struct ReconciliationRow: Sendable, Equatable, Identifiable, Codable {
    public enum Status: String, Sendable, Codable {
        case completed
        case undone
    }

    public var id: ReconciliationID
    public var budgetID: BudgetID
    public var accountID: AccountID
    public var statementDate: BudgetDate
    /// Stored in the account's normalized sign convention.
    public var statementBalanceMilliunits: Milliunits
    public var clearedBalanceMilliunits: Milliunits
    public var adjustmentTransactionID: TransactionID?
    /// Canonical accounting fingerprint of the generated adjustment at
    /// creation; undo requires it to still match.
    public var adjustmentFingerprintAtCreation: String?
    public var status: Status
    public var createdAtEpoch: Int64
    public var completedAtEpoch: Int64?

    public init(
        id: ReconciliationID = ReconciliationID(),
        budgetID: BudgetID,
        accountID: AccountID,
        statementDate: BudgetDate,
        statementBalanceMilliunits: Milliunits,
        clearedBalanceMilliunits: Milliunits,
        adjustmentTransactionID: TransactionID? = nil,
        adjustmentFingerprintAtCreation: String? = nil,
        status: Status = .completed,
        createdAtEpoch: Int64 = 0,
        completedAtEpoch: Int64? = nil
    ) {
        self.id = id
        self.budgetID = budgetID
        self.accountID = accountID
        self.statementDate = statementDate
        self.statementBalanceMilliunits = statementBalanceMilliunits
        self.clearedBalanceMilliunits = clearedBalanceMilliunits
        self.adjustmentTransactionID = adjustmentTransactionID
        self.adjustmentFingerprintAtCreation = adjustmentFingerprintAtCreation
        self.status = status
        self.createdAtEpoch = createdAtEpoch
        self.completedAtEpoch = completedAtEpoch
    }
}

/// Membership join: one transaction included in one reconciliation, with the
/// accounting fingerprint captured at that instant (§2.1). Undo removes the
/// reconciled state only from rows with `wasNewlyMarkedReconciled` whose
/// current fingerprint still matches.
public struct ReconciliationTransactionRow: Sendable, Equatable, Codable {
    public var reconciliationID: ReconciliationID
    public var transactionID: TransactionID
    public var fingerprintAtReconciliation: String
    public var wasNewlyMarkedReconciled: Bool

    public init(
        reconciliationID: ReconciliationID,
        transactionID: TransactionID,
        fingerprintAtReconciliation: String,
        wasNewlyMarkedReconciled: Bool
    ) {
        self.reconciliationID = reconciliationID
        self.transactionID = transactionID
        self.fingerprintAtReconciliation = fingerprintAtReconciliation
        self.wasNewlyMarkedReconciled = wasNewlyMarkedReconciled
    }
}

extension TransactionRow {
    /// Canonical accounting fingerprint (§2.1): every field that affects the
    /// row's accounting meaning — account, date/effective ordering, amount,
    /// category, kind, posting/void state, transfer/refund links, payee,
    /// memo, cleared, and approved. Deterministic pipe-delimited encoding
    /// with length-prefixed free text so user strings cannot forge structure.
    public var accountingFingerprint: String {
        func text(_ value: String?) -> String {
            guard let value else { return "nil" }
            return "\(value.utf8.count):\(value)"
        }
        return [
            "account=\(accountID.description)",
            "date=\(date.description)",
            "effective=\(effectiveAtEpoch.map(String.init) ?? "nil")",
            "order=\(sourceOrderKey.rawValue)",
            "amount=\(amountMilliunits)",
            "category=\(categoryID?.description ?? "nil")",
            "kind=\(kind.rawValue)",
            "posting=\(postingState.rawValue)",
            "stage=\(stageReason?.rawValue ?? "nil")",
            "transfer=\(transferPairID?.description ?? "nil")",
            "refundOf=\(refundOfTransactionID?.description ?? "nil")",
            "payee=\(payeeID?.description ?? "nil")",
            "memo=\(text(memo))",
            "cleared=\(cleared.rawValue)",
            "approved=\(approved)"
        ].joined(separator: "|")
    }
}

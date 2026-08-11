import Foundation

/// Redacted data-integrity failure. Carries a machine-readable code and the
/// affected month, never amounts, payees, memos, or credentials. An integrity
/// failure aborts the current mutation and rolls back its database
/// transaction; it never wraps arithmetic and never crashes the process.
public struct IntegrityError: Error, Equatable, Sendable {
    public enum Code: String, Sendable, Equatable {
        case arithmeticOverflow
        case conservationOracleViolated
        case bucketIdentityViolated
        case invalidRowState
        case invalidReference
        case invalidCalendar
        case positiveCardProjection
    }

    public let code: Code
    public let month: BudgetMonth?

    public init(code: Code, month: BudgetMonth? = nil) {
        self.code = code
        self.month = month
    }
}

/// Rejection of a user/sync mutation before any state is written. The prior
/// state is left byte-for-byte unchanged.
public enum MutationError: Error, Equatable, Sendable {
    // Allocation primitives
    case allocationMonthNotCurrent
    case negativeSetBudgeted
    case allocationTargetNotAllowed          // RTA, Uncategorized, hidden/system-ineligible
    case moveMoneyAmountNotPositive
    case moveMoneySameCategory
    case moveMoneySourceUnavailable          // exceeds source's non-negative available
    case moveMoneyRTAUnavailable             // exceeds RTADisplayed / would cross below zero
    case moveMoneyCategoryNotEligible

    // Transactions
    case futureDatedTransaction
    case dateBeforeFirstMonth
    case closedMonth
    case accountNotFound
    case accountClosed
    case categoryRequired
    case categoryNotAllowed                  // kind/sign mismatch, cc_payment direct use, system misuse
    case cardBalanceWouldBecomePositive
    case negativeCashOpeningBalance
    case positiveCardOpeningBalance
    case refundNotPositive
    case refundOriginInvalid
    case refundExceedsRemainingLot
    case cashRefundWithCreditDebt
    case transactionNotFound
    case transactionImmutable                // imported identity/account immutability
    case reconciledTransaction
    case transactionHasDependents

    // Transfers
    case unsupportedTransferPair             // card→cash, card→card, off→card, mismatched currency
    case transferLegsInvalid                 // not equal/opposite, same account, month straddle, window
    case transferPairNotFound

    // Staged-row resolution
    case stagedRowNotFound
    case resolutionGuardFailed               // projectionBalanceAsIfResolved would exceed zero
    case resolutionNotEligible

    // Reconciliation
    case reconciliationInvalid
    case reconciliationUndoBlocked

    // Structure
    case budgetMismatch
    case currencyMismatch
    case duplicateEntity
    case entityNotFound
    case systemEntityImmutable
    case monthNotClosed
    case monthAlreadyClosed
    case accountHasActivity                  // close-account guard
    case categoryHasAvailable                // hide-category guard

    case arithmeticOverflow
}

/// Fixed, redacted rejection codes for explicit sync-record resolution. These
/// cases never carry provider metadata, account names, amounts, URLs, or any
/// credential-adjacent material.
public enum SyncResolutionError: Error, Equatable, Sendable {
    case budgetMismatch
    case conflictNotFound
    case conflictNotOpen
    case discrepancyNotFound
    case discrepancyNotOpen
    case staleRequest
    case resolutionKindMismatch
    case malformedConflict
    case malformedDiscrepancy
    case missingReference
    case invalidEdit
    case dependencyInvalid
    case accountLifecycleUnsupported
}

import Foundation

/// Everything the replay engine needs, already resolved into value types.
/// The persistence layer builds this from SQLite; tests build it directly.
public struct ReplayInput: Sendable {
    public var budget: BudgetRow
    public var accounts: [AccountID: AccountRow]
    public var categories: [CategoryID: CategoryRow]
    public var allocations: [AllocationRow]
    public var transactions: [TransactionRow]
    public var transferPairs: [TransferPairID: TransferPairRow]
    /// Months whose `ClosedMonth` status is `closed`.
    public var closedMonths: Set<BudgetMonth>

    public init(
        budget: BudgetRow,
        accounts: [AccountID: AccountRow],
        categories: [CategoryID: CategoryRow],
        allocations: [AllocationRow],
        transactions: [TransactionRow],
        transferPairs: [TransferPairID: TransferPairRow] = [:],
        closedMonths: Set<BudgetMonth> = []
    ) {
        self.budget = budget
        self.accounts = accounts
        self.categories = categories
        self.allocations = allocations
        self.transactions = transactions
        self.transferPairs = transferPairs
        self.closedMonths = closedMonths
    }
}

/// Deterministic posting classification produced by the replay pass for every
/// non-voided transaction row. The mutation service persists changed states;
/// applying decisions and replaying again is a no-op (idempotence).
public struct PostingDecision: Sendable, Equatable, Codable {
    public var postingState: PostingState
    public var stageReason: StageReason?

    public init(postingState: PostingState, stageReason: StageReason? = nil) {
        self.postingState = postingState
        self.stageReason = stageReason
    }
}

public struct CategoryMonthSnapshot: Sendable, Equatable, Codable {
    public var budgeted: Milliunits
    public var activity: Milliunits
    public var available: Milliunits
    public var creditDebt: Milliunits
    /// Derived `max(0, -available - creditDebt)`, materialized with checked
    /// arithmetic at snapshot construction (never a stored database column).
    public var cashDebt: Milliunits

    public init(budgeted: Milliunits = 0, activity: Milliunits = 0, available: Milliunits = 0, creditDebt: Milliunits = 0, cashDebt: Milliunits = 0) {
        self.budgeted = budgeted
        self.activity = activity
        self.available = available
        self.creditDebt = creditDebt
        self.cashDebt = cashDebt
    }
}

public struct PaymentMonthSnapshot: Sendable, Equatable, Codable {
    public var budgeted: Milliunits
    public var activity: Milliunits
    public var available: Milliunits
    /// Derived `max(0, -available)`, materialized with checked arithmetic.
    public var paymentCashDebt: Milliunits

    public init(budgeted: Milliunits = 0, activity: Milliunits = 0, available: Milliunits = 0, paymentCashDebt: Milliunits = 0) {
        self.budgeted = budgeted
        self.activity = activity
        self.available = available
        self.paymentCashDebt = paymentCashDebt
    }
}

public struct MonthSnapshot: Sendable, Equatable, Codable {
    public var month: BudgetMonth
    public var rtaStart: Milliunits
    public var rtaActivity: Milliunits
    public var totalAssigned: Milliunits
    /// `RTAEnd(m) = RTAStart(m) + activity - assigned`; also `RTADisplayed(m)`.
    /// Materialized with checked arithmetic at snapshot construction.
    public var rtaEnd: Milliunits
    /// Spending categories (including `Uncategorized`).
    public var categories: [CategoryID: CategoryMonthSnapshot]
    /// Credit-card payment categories.
    public var payments: [CategoryID: PaymentMonthSnapshot]
    /// `sum(cashDebt) + sum(paymentCashDebt)` at month end. Reduces next RTA.
    public var cashOverspendingAtEnd: Milliunits
    /// Month-local test/oracle term; never reduces RTA.
    public var creditOverspendingAtEnd: Milliunits

    public init(
        month: BudgetMonth,
        rtaStart: Milliunits = 0,
        rtaActivity: Milliunits = 0,
        totalAssigned: Milliunits = 0,
        rtaEnd: Milliunits = 0,
        categories: [CategoryID: CategoryMonthSnapshot] = [:],
        payments: [CategoryID: PaymentMonthSnapshot] = [:],
        cashOverspendingAtEnd: Milliunits = 0,
        creditOverspendingAtEnd: Milliunits = 0
    ) {
        self.month = month
        self.rtaStart = rtaStart
        self.rtaActivity = rtaActivity
        self.totalAssigned = totalAssigned
        self.rtaEnd = rtaEnd
        self.categories = categories
        self.payments = payments
        self.cashOverspendingAtEnd = cashOverspendingAtEnd
        self.creditOverspendingAtEnd = creditOverspendingAtEnd
    }
}

/// Provenance for one posted credit-card purchase within its `(month,
/// category)` scope (§3.5.3). Derived in-memory state, never a stored column.
public struct PurchaseLot: Sendable, Equatable, Codable {
    public var purchaseID: TransactionID
    /// Component of a split purchase this lot belongs to (0 when unsplit).
    public var componentIndex: Int
    public var cardAccountID: AccountID
    public var remainingRefundable: Milliunits
    public var remainingFunded: Milliunits
}

/// Cross-month index entry for a posted credit-card purchase, used to
/// classify linked refunds (`crossMonthRefund` vs `missingRefundOrigin`).
public struct PurchaseInfo: Sendable, Equatable, Codable {
    public var month: BudgetMonth
    /// The purchase's category, or component 0's category when split.
    public var categoryID: CategoryID
    public var cardAccountID: AccountID
    /// Per-component categories for a split purchase; nil when unsplit.
    public var componentCategoryIDs: [CategoryID]?

    public init(month: BudgetMonth, categoryID: CategoryID, cardAccountID: AccountID, componentCategoryIDs: [CategoryID]? = nil) {
        self.month = month
        self.categoryID = categoryID
        self.cardAccountID = cardAccountID
        self.componentCategoryIDs = componentCategoryIDs
    }

    /// Resolves the category a refund of `componentIndex` targets. A split
    /// origin requires an in-range component index; an unsplit origin
    /// requires none (D3.3).
    public func refundCategory(componentIndex: Int?) -> CategoryID? {
        if let components = componentCategoryIDs {
            guard let index = componentIndex, components.indices.contains(index) else { return nil }
            return components[index]
        }
        return componentIndex == nil ? categoryID : nil
    }
}

/// State at the START of a month, before that month's allocations. Captured
/// per month so a mutation invalidates checkpoints from the earliest affected
/// month forward and replays from there instead of `first_month` (§6.3).
public struct MonthCheckpoint: Sendable, Equatable, Codable {
    public var month: BudgetMonth
    public var rtaStart: Milliunits
    /// Non-negative carried available per spending category.
    public var spendingAvailable: [CategoryID: Milliunits]
    /// Non-negative carried available per payment category.
    public var paymentAvailable: [CategoryID: Milliunits]
    public var projectionBalances: [AccountID: Milliunits]
    public var registerBalances: [AccountID: Milliunits]
    public var purchaseIndex: [TransactionID: PurchaseInfo]
    public var postingDecisions: [TransactionID: PostingDecision]
}

public struct ProjectionResult: Sendable, Equatable, Codable {
    public var months: [MonthSnapshot]
    public var registerBalances: [AccountID: Milliunits]
    public var projectionBalances: [AccountID: Milliunits]
    public var postingDecisions: [TransactionID: PostingDecision]
    public var checkpoints: [BudgetMonth: MonthCheckpoint]
    public var horizon: BudgetMonth

    public func month(_ m: BudgetMonth) -> MonthSnapshot? {
        months.first { $0.month == m }
    }
}

import Foundation

public enum AccountType: String, Sendable, Codable, CaseIterable {
    case checking
    case savings
    case cash
    case creditCard
    case other

    /// Checking, savings, and cash participate in `CashLikeAssets`.
    public var isCashLike: Bool {
        switch self {
        case .checking, .savings, .cash: return true
        case .creditCard, .other: return false
        }
    }
}

public enum CategoryKind: String, Sendable, Codable {
    case inflow
    case ccPayment = "cc_payment"
    case spending
}

public enum CategorySystemKind: String, Sendable, Codable {
    case readyToAssign
    case uncategorized
}

public enum PayeeSystemKind: String, Sendable, Codable {
    case openingBalance
    case transfer
    case reconciliationAdjustment
    case cardDebtAdjustment
    case unknown
}

public enum PayeeNamespace: String, Sendable, Codable {
    case system
    case user
}

public enum SourceKind: String, Sendable, Codable {
    case manual
    case simplefin
    case system
    /// Imported from a user-supplied file (CSV/OFX/QFX); carries a
    /// `FileImportRecord` identity like `simplefin` carries an import record.
    case file
}

public enum ClearedState: String, Sendable, Codable {
    case uncleared
    case cleared
    case reconciled
}

public enum PostingState: String, Sendable, Codable {
    case needsCategory
    case staged
    case posted
    case voided
}

public enum StageReason: String, Sendable, Codable {
    case cardBalanceWouldBecomePositive
    case crossMonthRefund
    case missingRefundOrigin
    case overRefund
    case unlinkedCardInflow
    case cashInflowWithCreditDebt
    case transferPairCounterpartyStaged
    case closedMonthImport
    case transferPairUnpairNeedsCategorization
}

public enum TransactionKind: String, Sendable, Codable {
    case normal
    case refund
    case openingBalance
    case adjustment
}

public enum TransferPairStatus: String, Sendable, Codable {
    case complete
    case unpaired
    case voided
}

public enum FlagColor: String, Sendable, Codable, CaseIterable {
    case red, orange, yellow, green, blue, purple
}

public enum ClosedMonthStatus: String, Sendable, Codable {
    case closed
    case reopened
}

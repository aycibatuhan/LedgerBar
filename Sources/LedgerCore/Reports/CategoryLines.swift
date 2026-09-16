import Foundation

/// The accounting role of one line, decided once so every report, the
/// assistant, and the schedule matcher agree (docs/DESIGN.md D7.2).
public enum LineRole: String, Sendable, Codable, CaseIterable {
    /// Category outflow on a budget-eligible account (cash or card), or the
    /// on-budget leg of an on→off transfer.
    case spending
    /// Positive category activity that reduces net spending.
    case refund
    /// Money entering the plan: normal positive rows to RTA and the on-budget
    /// leg of an off→on transfer.
    case income
    /// on↔on and off↔off legs, and the off-budget leg of an on↔off pair.
    case transfer
    /// Cash → credit-card payment legs.
    case cardPayment
    /// Opening balances (either sign, any account).
    case opening
    /// Reconciliation / card-debt adjustments.
    case adjustment
    /// Rows on off-budget or currency-mismatched accounts.
    case offBudget
    /// Excluded from projection until resolved; counted only in balances.
    case staged
}

/// One category line: an unsplit row or one split component (D3.4).
public struct CategoryLine: Sendable, Equatable, Identifiable {
    public var transactionID: TransactionID
    public var componentIndex: Int
    public var date: BudgetDate
    public var accountID: AccountID
    public var payeeID: PayeeID?
    public var categoryID: CategoryID?
    public var amountMilliunits: Milliunits
    public var role: LineRole
    public var kind: TransactionKind
    public var sourceKind: SourceKind
    public var postingState: PostingState
    public var memo: String?
    public var importedDescription: String?
    public var approved: Bool
    public var cleared: ClearedState

    public var id: String { "\(transactionID.description)#\(componentIndex)" }
    public var month: BudgetMonth { date.budgetMonth }
}

extension BudgetWorkspaceSnapshot {

    /// Expands every non-voided row into category lines with a role. Lines
    /// are sorted by `(date, sourceOrderKey, id, component)` so aggregation
    /// order is deterministic.
    public func categoryLines() -> [CategoryLine] {
        let accountsByID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        let pairStatus = Dictionary(uniqueKeysWithValues: transferPairs.map { ($0.id, $0.status) })
        let legsByPair: [TransferPairID: [TransactionRow]] = transactions.reduce(into: [:]) { result, row in
            if let pairID = row.transferPairID, row.postingState != .voided { result[pairID, default: []].append(row) }
        }
        let currency = budget.currency
        func eligible(_ id: AccountID) -> Bool {
            guard let account = accountsByID[id] else { return false }
            return budgetEligible(account, budgetCurrency: currency)
        }
        var lines: [CategoryLine] = []
        for row in transactions.sorted(by: { ($0.date, $0.sourceOrderKey, $0.id) < ($1.date, $1.sourceOrderKey, $1.id) }) {
            guard row.postingState != .voided else { continue }
            let role = Self.role(of: row, eligible: eligible, accountsByID: accountsByID, pairStatus: pairStatus, legsByPair: legsByPair)
            if let splits = row.splits, role == .spending {
                for (index, component) in splits.enumerated() {
                    lines.append(CategoryLine(
                        transactionID: row.id, componentIndex: index, date: row.date, accountID: row.accountID,
                        payeeID: row.payeeID, categoryID: component.categoryID, amountMilliunits: component.amountMilliunits,
                        role: role, kind: row.kind, sourceKind: row.sourceKind, postingState: row.postingState,
                        memo: component.memo ?? row.memo, importedDescription: row.importedDescription,
                        approved: row.approved, cleared: row.cleared
                    ))
                }
            } else {
                lines.append(CategoryLine(
                    transactionID: row.id, componentIndex: 0, date: row.date, accountID: row.accountID,
                    payeeID: row.payeeID, categoryID: row.categoryID, amountMilliunits: row.amountMilliunits,
                    role: role, kind: row.kind, sourceKind: row.sourceKind, postingState: row.postingState,
                    memo: row.memo, importedDescription: row.importedDescription,
                    approved: row.approved, cleared: row.cleared
                ))
            }
        }
        return lines
    }

    private static func role(
        of row: TransactionRow,
        eligible: (AccountID) -> Bool,
        accountsByID: [AccountID: AccountRow],
        pairStatus: [TransferPairID: TransferPairStatus],
        legsByPair: [TransferPairID: [TransactionRow]]
    ) -> LineRole {
        if row.postingState == .staged { return .staged }
        let isEligible = eligible(row.accountID)
        if let pairID = row.transferPairID, pairStatus[pairID] == .complete {
            let legs = legsByPair[pairID] ?? []
            let other = legs.first { $0.id != row.id }
            let otherEligible = other.map { eligible($0.accountID) } ?? false
            let otherIsCard = other.flatMap { accountsByID[$0.accountID]?.type } == .creditCard
            let selfIsCard = accountsByID[row.accountID]?.type == .creditCard
            if isEligible && otherEligible {
                if row.amountMilliunits < 0 && otherIsCard { return .cardPayment }
                if row.amountMilliunits > 0 && selfIsCard { return .cardPayment }
                return .transfer
            }
            if isEligible && !otherEligible {
                return row.amountMilliunits < 0 ? .spending : .income
            }
            return .transfer
        }
        guard isEligible else { return .offBudget }
        switch row.kind {
        case .openingBalance: return .opening
        case .adjustment: return .adjustment
        case .refund: return .refund
        case .normal:
            return row.amountMilliunits > 0 ? .income : .spending
        }
    }
}

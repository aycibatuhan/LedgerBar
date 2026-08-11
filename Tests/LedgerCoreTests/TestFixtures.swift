import Foundation
@testable import LedgerCore

/// $1 = 1000 milliunits.
func usd(_ dollars: Int) -> Milliunits { Milliunits(dollars) * 1000 }

func month(_ s: String) -> BudgetMonth { BudgetMonth(string: s)! }
func date(_ s: String) -> BudgetDate { BudgetDate(string: s)! }

let testEpoch: Int64 = 1_735_689_600 // 2025-01-01T00:00:00Z

/// Standard fixture: USD budget in a fixed-offset zone (deterministic across
/// machines), first month January 2025.
func makeWorkspace(
    firstMonth: String = "2025-01",
    currentMonth: String = "2025-01",
    timeZone: String = "America/New_York"
) throws -> BudgetWorkspace {
    try BudgetWorkspace.create(
        name: "Test Budget",
        currency: "USD",
        timeZoneIdentifier: timeZone,
        firstMonth: month(firstMonth),
        currentMonth: month(currentMonth),
        nowEpoch: testEpoch
    )
}

extension BudgetWorkspace {
    func categoryID(named name: String) -> CategoryID {
        categories.values.first { $0.name == name }!.id
    }

    func paymentCategoryIDForOnlyCard() -> CategoryID {
        categories.values.first { $0.kind == .ccPayment }!.id
    }

    /// Current-state projection snapshot for one month.
    func snapshot(_ m: String) throws -> MonthSnapshot {
        try projection().month(month(m))!
    }

    func available(_ category: String, in m: String) throws -> Milliunits {
        let s = try snapshot(m)
        let id = categoryID(named: category)
        return s.categories[id]?.available ?? s.payments[id]?.available ?? 0
    }
}

/// Asserts the §3.7 conservation identity for the given month snapshot
/// against explicit expected values, summing every spending and payment
/// category (never an abbreviated display row).
struct ConservationCheck {
    var cashLikeAssets: Milliunits
    var rta: Milliunits
    var totalSpendingAvailable: Milliunits
    var totalPaymentAvailable: Milliunits
    var creditOverspending: Milliunits

    static func compute(_ ws: BudgetWorkspace, month m: BudgetMonth) throws -> ConservationCheck {
        let result = try ws.projection()
        let snap = result.month(m)!
        var cash: Milliunits = 0
        for (id, account) in ws.accounts
        where account.type.isCashLike && budgetEligible(account, budgetCurrency: ws.budget.currency) {
            cash += result.projectionBalances[id] ?? 0
        }
        return ConservationCheck(
            cashLikeAssets: cash,
            rta: snap.rtaEnd,
            totalSpendingAvailable: snap.categories.values.reduce(0) { $0 + $1.available },
            totalPaymentAvailable: snap.payments.values.reduce(0) { $0 + $1.available },
            creditOverspending: snap.creditOverspendingAtEnd
        )
    }

    var rhs: Milliunits { rta + totalSpendingAvailable + totalPaymentAvailable + creditOverspending }
    var holds: Bool { cashLikeAssets == rhs }
}

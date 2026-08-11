import Foundation
import Testing
@testable import LedgerCore

@Suite("§3.10 worked three-month golden scenario — exact checkpoint table")
struct GoldenScenarioTests {

    struct Checkpoint {
        var label: String
        var cashLike: Int
        var rta: Int
        var rent: Int
        var dining: Int
        var groceries: Int
        var ccPayment: Int
        var creditOverspending: Int
        var rhs: Int
    }

    /// Asserts one row of the §3.10 table. The conservation RHS includes ALL
    /// spending categories (the unlisted placeholders are all zero throughout,
    /// which the full-sum comparison verifies implicitly).
    func assertCheckpoint(
        _ ws: BudgetWorkspace, month m: String, _ cp: Checkpoint,
        rent: CategoryID, dining: CategoryID, groceries: CategoryID, payment: CategoryID
    ) throws {
        let check = try ConservationCheck.compute(ws, month: month(m))
        let snap = try ws.snapshot(m)
        #expect(check.cashLikeAssets == usd(cp.cashLike), "\(cp.label): cash-like")
        #expect(snap.rtaEnd == usd(cp.rta), "\(cp.label): RTA")
        #expect(snap.categories[rent]?.available == usd(cp.rent), "\(cp.label): Rent")
        #expect(snap.categories[dining]?.available == usd(cp.dining), "\(cp.label): Dining")
        #expect(snap.categories[groceries]?.available == usd(cp.groceries), "\(cp.label): Groceries")
        #expect(snap.payments[payment]?.available == usd(cp.ccPayment), "\(cp.label): CC payment")
        #expect(snap.creditOverspendingAtEnd == usd(cp.creditOverspending), "\(cp.label): credit overspending")
        #expect(check.rhs == usd(cp.rhs), "\(cp.label): RHS")
        #expect(check.holds, "\(cp.label): conservation oracle")
    }

    @Test("Full January–March scenario with the exact balances")
    func threeMonthScenario() throws {
        var ws = try makeWorkspace(firstMonth: "2025-01", currentMonth: "2025-01")
        let rent = ws.categoryID(named: "Rent")
        let dining = ws.categoryID(named: "Dining")
        let groceries = ws.categoryID(named: "Groceries")

        let checking = try ws.addAccount(
            name: "Checking", type: .checking, onBudget: true,
            openingBalance: usd(1000), openingDate: date("2025-01-01"), nowEpoch: testEpoch
        )
        let card = try ws.addAccount(
            name: "Card", type: .creditCard, onBudget: true,
            openingBalance: -usd(200), openingDate: date("2025-01-01"), nowEpoch: testEpoch
        )
        let payment = ws.paymentCategoryIDForOnlyCard()

        func cp(_ label: String, _ m: String, _ values: (Int, Int, Int, Int, Int, Int, Int, Int)) throws {
            try assertCheckpoint(
                ws, month: m,
                Checkpoint(
                    label: label, cashLike: values.0, rta: values.1, rent: values.2, dining: values.3,
                    groceries: values.4, ccPayment: values.5, creditOverspending: values.6, rhs: values.7
                ),
                rent: rent, dining: dining, groceries: groceries, payment: payment
            )
        }

        // ---- January ----
        try ws.setBudgeted(categoryID: rent, month: month("2025-01"), value: usd(500))
        try ws.setBudgeted(categoryID: dining, month: month("2025-01"), value: usd(300))
        try ws.setBudgeted(categoryID: groceries, month: month("2025-01"), value: usd(100))
        try cp("Jan after assignments", "2025-01", (1000, 100, 500, 300, 100, 0, 0, 1000))

        try ws.addManualTransaction(
            accountID: checking, date: date("2025-01-02"), payeeName: "Landlord",
            categoryID: rent, amountMilliunits: -usd(500), nowEpoch: testEpoch
        )
        try cp("Jan after rent", "2025-01", (500, 100, 0, 300, 100, 0, 0, 500))

        try ws.addManualTransaction(
            accountID: checking, date: date("2025-01-05"), payeeName: "Grocer",
            categoryID: groceries, amountMilliunits: -usd(150), nowEpoch: testEpoch
        )
        try cp("Jan after cash groceries", "2025-01", (350, 100, 0, 300, -50, 0, 0, 350))

        let diningPurchaseJan = try ws.addManualTransaction(
            accountID: card, date: date("2025-01-10"), payeeName: "Bistro",
            categoryID: dining, amountMilliunits: -usd(350), nowEpoch: testEpoch
        )
        try cp("Jan after CC dining", "2025-01", (350, 100, 0, -50, -50, 300, 50, 350))
        _ = diningPurchaseJan

        try ws.createManualTransferPair(
            sourceAccountID: checking, destinationAccountID: card,
            amount: usd(300), date: date("2025-01-15"), nowEpoch: testEpoch
        )
        try cp("Jan after CC payment", "2025-01", (50, 100, 0, -50, -50, 0, 50, 50))
        #expect(try ws.projection().projectionBalances[card] == -usd(250), "card ends January at -250")

        // ---- February ----
        try ws.advanceObservedMonth(to: month("2025-02"))
        #expect(try ws.snapshot("2025-02").rtaStart == usd(50), "RTA starts at 50: January cash overspending was 50")

        try ws.addManualTransaction(
            accountID: checking, date: date("2025-02-01"), payeeName: "Employer",
            categoryID: ws.rtaCategoryID, amountMilliunits: usd(500), nowEpoch: testEpoch
        )
        try ws.setBudgeted(categoryID: rent, month: month("2025-02"), value: usd(300))
        try ws.setBudgeted(categoryID: dining, month: month("2025-02"), value: usd(100))
        try cp("Feb after assignments", "2025-02", (550, 150, 300, 100, 0, 0, 0, 550))

        try ws.addManualTransaction(
            accountID: checking, date: date("2025-02-03"), payeeName: "Landlord",
            categoryID: rent, amountMilliunits: -usd(300), nowEpoch: testEpoch
        )
        let diningPurchaseFeb = try ws.addManualTransaction(
            accountID: card, date: date("2025-02-05"), payeeName: "Bistro",
            categoryID: dining, amountMilliunits: -usd(100), nowEpoch: testEpoch
        )
        try cp("Feb after rent + card spend", "2025-02", (250, 150, 0, 0, 0, 100, 0, 250))

        try ws.addManualTransaction(
            accountID: card, date: date("2025-02-10"), payeeName: "Bistro",
            categoryID: dining, amountMilliunits: usd(50), kind: .refund,
            refundOf: diningPurchaseFeb, nowEpoch: testEpoch
        )
        try cp("Feb after refund", "2025-02", (250, 150, 0, 50, 0, 50, 0, 250))

        try ws.createManualTransferPair(
            sourceAccountID: checking, destinationAccountID: card,
            amount: usd(50), date: date("2025-02-12"), nowEpoch: testEpoch
        )
        try cp("Feb after payment", "2025-02", (200, 150, 0, 50, 0, 0, 0, 200))
        #expect(try ws.projection().projectionBalances[card] == -usd(250), "card ends February at -250")
        #expect(try ws.projection().projectionBalances[checking] == usd(200), "checking ends February at 200")

        // ---- March ----
        try ws.advanceObservedMonth(to: month("2025-03"))
        let marSnap = try ws.snapshot("2025-03")
        #expect(marSnap.rtaStart == usd(150), "RTA starts March at 150")
        #expect(marSnap.categories[dining]?.available == usd(50), "Dining carries 50 into March")

        try ws.setBudgeted(categoryID: dining, month: month("2025-03"), value: usd(50))
        #expect(try ws.snapshot("2025-03").rtaEnd == usd(100))
        #expect(try ws.available("Dining", in: "2025-03") == usd(100))

        try ws.addManualTransaction(
            accountID: card, date: date("2025-03-08"), payeeName: "Bistro",
            categoryID: dining, amountMilliunits: -usd(150), nowEpoch: testEpoch
        )
        try cp("Mar after card overspend", "2025-03", (200, 100, 0, -50, 0, 100, 50, 200))
        #expect(try ws.projection().projectionBalances[checking] == usd(200), "checking remains 200")
        #expect(try ws.projection().projectionBalances[card] == -usd(400), "card becomes -400")
    }
}

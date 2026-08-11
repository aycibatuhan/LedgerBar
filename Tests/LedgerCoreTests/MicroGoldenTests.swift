import Foundation
import Testing
@testable import LedgerCore

/// §3.7 required micro-goldens 1–17, asserted with the exact balances from the
/// specification. Every case ends with a conservation check computed by full
/// per-category summation.
@Suite("§3.7 micro-goldens")
struct MicroGoldenTests {

    struct Fixture {
        var ws: BudgetWorkspace
        var checking: AccountID
        var card: AccountID
        var dining: CategoryID
        var payment: CategoryID
    }

    /// Checking +1000 → RTA; card opening `cardOpening` (default -100).
    func fixture(cardOpening: Int = -100) throws -> Fixture {
        var ws = try makeWorkspace()
        let checking = try ws.addAccount(
            name: "Checking", type: .checking, onBudget: true,
            openingBalance: usd(1000), openingDate: date("2025-01-01"), nowEpoch: testEpoch
        )
        let card = try ws.addAccount(
            name: "Card", type: .creditCard, onBudget: true,
            openingBalance: usd(cardOpening), openingDate: date("2025-01-01"), nowEpoch: testEpoch
        )
        return Fixture(
            ws: ws, checking: checking, card: card,
            dining: ws.categoryID(named: "Dining"),
            payment: ws.paymentCategoryIDForOnlyCard()
        )
    }

    func conserve(_ ws: BudgetWorkspace, _ m: String) throws {
        #expect(try ConservationCheck.compute(ws, month: month(m)).holds)
    }

    @Test("1: funded purchase then payment — per-event effects and final state")
    func golden1() throws {
        var f = try fixture()
        try f.ws.setBudgeted(categoryID: f.dining, month: month("2025-01"), value: usd(40))
        try conserve(f.ws, "2025-01")

        try f.ws.addManualTransaction(
            accountID: f.card, date: date("2025-01-05"), payeeName: "Cafe",
            categoryID: f.dining, amountMilliunits: -usd(40), nowEpoch: testEpoch
        )
        var snap = try f.ws.snapshot("2025-01")
        #expect(snap.categories[f.dining]?.activity == -usd(40))
        #expect(snap.payments[f.payment]?.available == usd(40))
        #expect(try f.ws.projection().projectionBalances[f.card] == -usd(140))
        try conserve(f.ws, "2025-01")

        try f.ws.createManualTransferPair(
            sourceAccountID: f.checking, destinationAccountID: f.card,
            amount: usd(40), date: date("2025-01-06"), nowEpoch: testEpoch
        )
        snap = try f.ws.snapshot("2025-01")
        #expect(snap.categories[f.dining]?.activity == -usd(40))
        #expect(snap.payments[f.payment]?.activity == 0, "payment month activity nets to zero")
        #expect(snap.payments[f.payment]?.available == 0)
        let balances = try f.ws.projection().projectionBalances
        #expect(balances[f.card] == -usd(100), "card net unchanged at -100")
        #expect(balances[f.checking] == usd(960), "net cash-like assets decreased by 40")
        try conserve(f.ws, "2025-01")
    }

    @Test("2: credit-overspent purchase — creditDebt 40, RTA unchanged")
    func golden2() throws {
        var f = try fixture()
        let rtaBefore = try f.ws.snapshot("2025-01").rtaEnd
        try f.ws.addManualTransaction(
            accountID: f.card, date: date("2025-01-05"), payeeName: "Cafe",
            categoryID: f.dining, amountMilliunits: -usd(40), nowEpoch: testEpoch
        )
        let snap = try f.ws.snapshot("2025-01")
        #expect(snap.categories[f.dining]?.activity == -usd(40))
        #expect(snap.categories[f.dining]?.available == -usd(40))
        #expect(snap.categories[f.dining]?.creditDebt == usd(40))
        #expect(snap.rtaEnd == rtaBefore, "RTA unchanged")
        try conserve(f.ws, "2025-01")
    }

    @Test("3: linked same-month refund of a funded purchase")
    func golden3() throws {
        var f = try fixture()
        try f.ws.setBudgeted(categoryID: f.dining, month: month("2025-01"), value: usd(100))
        let purchase = try f.ws.addManualTransaction(
            accountID: f.card, date: date("2025-01-05"), payeeName: "Cafe",
            categoryID: f.dining, amountMilliunits: -usd(100), nowEpoch: testEpoch
        )
        try f.ws.addManualTransaction(
            accountID: f.card, date: date("2025-01-08"), payeeName: "Cafe",
            categoryID: f.dining, amountMilliunits: usd(40), kind: .refund,
            refundOf: purchase, nowEpoch: testEpoch
        )
        let snap = try f.ws.snapshot("2025-01")
        #expect(snap.categories[f.dining]?.available == usd(40), "spending +40")
        #expect(snap.payments[f.payment]?.available == usd(60), "payment -40")
        let card = try f.ws.projection().projectionBalances[f.card]!
        #expect(card == -usd(160) && card < 0, "card remains negative")
        try conserve(f.ws, "2025-01")
    }

    @Test("4: partial refund of a fully credit-overspent purchase reduces creditDebt")
    func golden4() throws {
        var f = try fixture()
        let purchase = try f.ws.addManualTransaction(
            accountID: f.card, date: date("2025-01-05"), payeeName: "Cafe",
            categoryID: f.dining, amountMilliunits: -usd(100), nowEpoch: testEpoch
        )
        #expect(try f.ws.snapshot("2025-01").categories[f.dining]?.creditDebt == usd(100))
        try f.ws.addManualTransaction(
            accountID: f.card, date: date("2025-01-08"), payeeName: "Cafe",
            categoryID: f.dining, amountMilliunits: usd(40), kind: .refund,
            refundOf: purchase, nowEpoch: testEpoch
        )
        let snap = try f.ws.snapshot("2025-01")
        #expect(snap.categories[f.dining]?.available == -usd(60), "spending +40 from -100")
        #expect(snap.categories[f.dining]?.creditDebt == usd(60), "creditDebt decreases by 40")
        #expect(snap.payments[f.payment]?.available == 0, "no funded lots consumed")
        #expect(try f.ws.projection().projectionBalances[f.card]! < 0)
        try conserve(f.ws, "2025-01")
    }

    @Test("5: mixed funded 60 / credit 40 purchase, refund 75 — credit-first")
    func golden5() throws {
        var f = try fixture(cardOpening: -200)
        try f.ws.setBudgeted(categoryID: f.dining, month: month("2025-01"), value: usd(60))
        let purchase = try f.ws.addManualTransaction(
            accountID: f.card, date: date("2025-01-05"), payeeName: "Cafe",
            categoryID: f.dining, amountMilliunits: -usd(100), nowEpoch: testEpoch
        )
        var snap = try f.ws.snapshot("2025-01")
        #expect(snap.categories[f.dining]?.available == -usd(40))
        #expect(snap.categories[f.dining]?.creditDebt == usd(40))
        #expect(snap.payments[f.payment]?.available == usd(60))

        try f.ws.addManualTransaction(
            accountID: f.card, date: date("2025-01-08"), payeeName: "Cafe",
            categoryID: f.dining, amountMilliunits: usd(75), kind: .refund,
            refundOf: purchase, nowEpoch: testEpoch
        )
        snap = try f.ws.snapshot("2025-01")
        #expect(snap.categories[f.dining]?.creditDebt == 0, "creditDebt decreases 40 to 0")
        #expect(snap.payments[f.payment]?.available == usd(25), "payment decreases 35")
        #expect(snap.categories[f.dining]?.available == usd(35), "available becomes +35")
        #expect(snap.categories[f.dining]?.cashDebt == 0, "bucket identity holds")
        try conserve(f.ws, "2025-01")
    }

    @Test("6: cross-month refund and repeated over-refund are staged, not projected")
    func golden6() throws {
        var f = try fixture(cardOpening: -500)
        let purchase = try f.ws.addManualTransaction(
            accountID: f.card, date: date("2025-01-05"), payeeName: "Cafe",
            categoryID: f.dining, amountMilliunits: -usd(100), nowEpoch: testEpoch
        )
        try f.ws.advanceObservedMonth(to: month("2025-02"))

        // Imported cross-month refund: staged after linking, no projection.
        let refund = try f.ws.importPostedTransaction(
            accountID: f.card, connectionKey: "c1", remoteAccountID: "a1", remoteTransactionID: "t1",
            postedEpoch: try f.ws.calendar.noonEpoch(of: date("2025-02-03")),
            payeeName: "Cafe", amountMilliunits: usd(100), nowEpoch: testEpoch
        )
        let beforeLink = try f.ws.projection()
        #expect(f.ws.transactions[refund]?.postingState == .staged)
        #expect(f.ws.transactions[refund]?.stageReason == .unlinkedCardInflow)
        try f.ws.linkRefundOrigin(refund, originID: purchase, nowEpoch: testEpoch)
        #expect(f.ws.transactions[refund]?.postingState == .staged)
        #expect(f.ws.transactions[refund]?.stageReason == .crossMonthRefund)
        let afterLink = try f.ws.projection()
        #expect(afterLink.projectionBalances[f.card] == beforeLink.projectionBalances[f.card],
                "no envelope/projection mutation until explicit resolution")
        try conserve(f.ws, "2025-02")

        // Manual over-refund is rejected outright; imported over-refund stages.
        let before = f.ws
        #expect(throws: MutationError.refundExceedsRemainingLot) {
            var copy = before
            try copy.addManualTransaction(
                accountID: f.card, date: date("2025-01-06"), payeeName: "Cafe",
                categoryID: f.dining, amountMilliunits: usd(150), kind: .refund,
                refundOf: purchase, nowEpoch: testEpoch
            )
        }
        let overRefund = try f.ws.importPostedTransaction(
            accountID: f.card, connectionKey: "c1", remoteAccountID: "a1", remoteTransactionID: "t2",
            postedEpoch: try f.ws.calendar.noonEpoch(of: date("2025-02-04")),
            payeeName: "Cafe", amountMilliunits: usd(150), nowEpoch: testEpoch
        )
        try f.ws.linkRefundOrigin(overRefund, originID: purchase, nowEpoch: testEpoch)
        // Cross-month wins over over-refund classification here; both are staged.
        #expect(f.ws.transactions[overRefund]?.postingState == .staged)
        try conserve(f.ws, "2025-02")
    }

    @Test("7: staged inflow reclassified as Card Debt Adjustment; zero-crossing rejected")
    func golden7() throws {
        var f = try fixture()
        let inflow = try f.ws.importPostedTransaction(
            accountID: f.card, connectionKey: "c1", remoteAccountID: "a1", remoteTransactionID: "t1",
            postedEpoch: try f.ws.calendar.noonEpoch(of: date("2025-01-10")),
            payeeName: "Card Co", amountMilliunits: usd(30), nowEpoch: testEpoch
        )
        #expect(f.ws.transactions[inflow]?.stageReason == .unlinkedCardInflow)
        let before = try f.ws.projection()
        #expect(before.registerBalances[f.card] == -usd(70), "register includes the staged row")
        #expect(before.projectionBalances[f.card] == -usd(100), "projection excludes it")
        let rtaBefore = try f.ws.snapshot("2025-01").rtaEnd

        try f.ws.resolveStagedAsCardDebtAdjustment(inflow, nowEpoch: testEpoch)
        let after = try f.ws.projection()
        #expect(after.registerBalances[f.card] == -usd(70), "register balance unchanged")
        #expect(after.projectionBalances[f.card] == -usd(70), "projection gains the row once")
        #expect(try f.ws.snapshot("2025-01").rtaEnd == rtaBefore, "envelopes/RTA unchanged")
        try conserve(f.ws, "2025-01")

        // Zero-crossing resolution is rejected and the row stays staged.
        var g = try fixture(cardOpening: -20)
        let big = try g.ws.importPostedTransaction(
            accountID: g.card, connectionKey: "c1", remoteAccountID: "a1", remoteTransactionID: "t9",
            postedEpoch: try g.ws.calendar.noonEpoch(of: date("2025-01-11")),
            payeeName: "Card Co", amountMilliunits: usd(30), nowEpoch: testEpoch
        )
        let pre = g.ws
        #expect(throws: MutationError.resolutionGuardFailed) {
            var copy = pre
            try copy.resolveStagedAsCardDebtAdjustment(big, nowEpoch: testEpoch)
        }
        #expect(g.ws.transactions[big]?.postingState == .staged)
        try conserve(g.ws, "2025-01")
    }

    @Test("8: payment transfer that would cross the card above zero is rejected with no rows")
    func golden8() throws {
        var f = try fixture()
        let before = f.ws
        #expect(throws: MutationError.cardBalanceWouldBecomePositive) {
            var copy = before
            try copy.createManualTransferPair(
                sourceAccountID: f.checking, destinationAccountID: f.card,
                amount: usd(150), date: date("2025-01-10"), nowEpoch: testEpoch
            )
        }
        #expect(f.ws == before, "rejection leaves state unchanged, no inserted rows")
        try conserve(f.ws, "2025-01")
    }

    @Test("9: negative cash reconciliation adjustment — signed RTA activity and equal cash decrease")
    func golden9() throws {
        var f = try fixture()
        let rtaBefore = try f.ws.snapshot("2025-01").rtaEnd
        let cashBefore = try f.ws.projection().projectionBalances[f.checking]!
        try f.ws.addReconciliationAdjustment(
            accountID: f.checking, date: date("2025-01-20"), amountMilliunits: -usd(25), nowEpoch: testEpoch
        )
        #expect(try f.ws.snapshot("2025-01").rtaEnd == rtaBefore - usd(25))
        #expect(try f.ws.projection().projectionBalances[f.checking] == cashBefore - usd(25))
        try conserve(f.ws, "2025-01")
    }

    @Test("10: cash inflow into a creditDebt category is staged; register up, projection unchanged")
    func golden10() throws {
        var f = try fixture()
        try f.ws.addManualTransaction(
            accountID: f.card, date: date("2025-01-05"), payeeName: "Cafe",
            categoryID: f.dining, amountMilliunits: -usd(100), nowEpoch: testEpoch
        )
        #expect(try f.ws.snapshot("2025-01").categories[f.dining]?.creditDebt == usd(100))

        let inflow = try f.ws.importPostedTransaction(
            accountID: f.checking, connectionKey: "c1", remoteAccountID: "chk", remoteTransactionID: "t1",
            postedEpoch: try f.ws.calendar.noonEpoch(of: date("2025-01-10")),
            payeeName: "Friend", amountMilliunits: usd(30), nowEpoch: testEpoch
        )
        let snapBefore = try f.ws.snapshot("2025-01")
        try f.ws.classifyAsCashReimbursement(inflow, categoryID: f.dining, nowEpoch: testEpoch)
        let row = f.ws.transactions[inflow]!
        #expect(row.postingState == .staged)
        #expect(row.stageReason == .cashInflowWithCreditDebt)
        #expect(row.stageMetadata?.proposedCategoryID == f.dining, "metadata preserves the proposed category")
        let result = try f.ws.projection()
        #expect(result.registerBalances[f.checking] == usd(1030), "register increases")
        #expect(result.projectionBalances[f.checking] == usd(1000), "projection unchanged")
        #expect(try f.ws.snapshot("2025-01").categories[f.dining] == snapBefore.categories[f.dining])
        try conserve(f.ws, "2025-01")

        // Resolution (a): categorize to RTA creates income without touching creditDebt.
        try f.ws.resolveCashInflowToRTA(inflow, nowEpoch: testEpoch)
        let snap = try f.ws.snapshot("2025-01")
        #expect(snap.categories[f.dining]?.creditDebt == usd(100))
        #expect(try f.ws.projection().projectionBalances[f.checking] == usd(1030))
        try conserve(f.ws, "2025-01")
    }

    @Test("11: multi-purchase category — refund of funded P1 consumes creditDebt first")
    func golden11() throws {
        var f = try fixture(cardOpening: -500)
        try f.ws.setBudgeted(categoryID: f.dining, month: month("2025-01"), value: usd(100))
        let p1 = try f.ws.addManualTransaction(
            accountID: f.card, date: date("2025-01-05"), payeeName: "Cafe",
            categoryID: f.dining, amountMilliunits: -usd(100), nowEpoch: testEpoch
        )
        try f.ws.addManualTransaction(
            accountID: f.card, date: date("2025-01-06"), payeeName: "Cafe",
            categoryID: f.dining, amountMilliunits: -usd(50), nowEpoch: testEpoch
        )
        try f.ws.addManualTransaction(
            accountID: f.card, date: date("2025-01-08"), payeeName: "Cafe",
            categoryID: f.dining, amountMilliunits: usd(50), kind: .refund,
            refundOf: p1, nowEpoch: testEpoch
        )
        let snap = try f.ws.snapshot("2025-01")
        #expect(snap.categories[f.dining]?.available == 0, "Dining 0")
        #expect(snap.payments[f.payment]?.available == usd(100), "payment 100 — no funded lot consumed")
        #expect(snap.categories[f.dining]?.creditDebt == 0, "creditDebt 0")
        try conserve(f.ws, "2025-01")
    }

    @Test("12: sequential refunds — P2 refund consumes P1's funded lot in replay order")
    func golden12() throws {
        var f = try fixture(cardOpening: -500)
        try f.ws.setBudgeted(categoryID: f.dining, month: month("2025-01"), value: usd(100))
        let p1 = try f.ws.addManualTransaction(
            accountID: f.card, date: date("2025-01-05"), payeeName: "Cafe",
            categoryID: f.dining, amountMilliunits: -usd(100), nowEpoch: testEpoch
        )
        let p2 = try f.ws.addManualTransaction(
            accountID: f.card, date: date("2025-01-06"), payeeName: "Cafe",
            categoryID: f.dining, amountMilliunits: -usd(50), nowEpoch: testEpoch
        )
        try f.ws.addManualTransaction(
            accountID: f.card, date: date("2025-01-08"), payeeName: "Cafe",
            categoryID: f.dining, amountMilliunits: usd(50), kind: .refund,
            refundOf: p1, nowEpoch: testEpoch
        )
        try f.ws.addManualTransaction(
            accountID: f.card, date: date("2025-01-09"), payeeName: "Cafe",
            categoryID: f.dining, amountMilliunits: usd(50), kind: .refund,
            refundOf: p2, nowEpoch: testEpoch
        )
        let snap = try f.ws.snapshot("2025-01")
        #expect(snap.categories[f.dining]?.available == usd(50), "Dining +50")
        #expect(snap.payments[f.payment]?.available == usd(50), "payment 50 after -50 funded-lot consumption")
        #expect(snap.categories[f.dining]?.creditDebt == 0)
        try conserve(f.ws, "2025-01")

        // P2's refundable lot is exhausted: a further linked refund stages/rejects.
        let before = f.ws
        #expect(throws: MutationError.refundExceedsRemainingLot) {
            var copy = before
            try copy.addManualTransaction(
                accountID: f.card, date: date("2025-01-10"), payeeName: "Cafe",
                categoryID: f.dining, amountMilliunits: usd(10), kind: .refund,
                refundOf: p2, nowEpoch: testEpoch
            )
        }
    }

    @Test("13: mixed cash/card debt refund — derived cashDebt falls as available rises")
    func golden13() throws {
        var f = try fixture(cardOpening: -500)
        try f.ws.setBudgeted(categoryID: f.dining, month: month("2025-01"), value: usd(50))
        let purchase = try f.ws.addManualTransaction(
            accountID: f.card, date: date("2025-01-05"), payeeName: "Cafe",
            categoryID: f.dining, amountMilliunits: -usd(100), nowEpoch: testEpoch
        )
        try f.ws.addManualTransaction(
            accountID: f.checking, date: date("2025-01-06"), payeeName: "Cafe",
            categoryID: f.dining, amountMilliunits: -usd(30), nowEpoch: testEpoch
        )
        var snap = try f.ws.snapshot("2025-01")
        #expect(snap.categories[f.dining]?.available == -usd(80))
        #expect(snap.categories[f.dining]?.creditDebt == usd(50))
        #expect(snap.categories[f.dining]?.cashDebt == usd(30))

        try f.ws.addManualTransaction(
            accountID: f.card, date: date("2025-01-08"), payeeName: "Cafe",
            categoryID: f.dining, amountMilliunits: usd(60), kind: .refund,
            refundOf: purchase, nowEpoch: testEpoch
        )
        snap = try f.ws.snapshot("2025-01")
        #expect(snap.categories[f.dining]?.available == -usd(20))
        #expect(snap.categories[f.dining]?.creditDebt == 0)
        #expect(snap.categories[f.dining]?.cashDebt == usd(20))
        #expect(snap.payments[f.payment]?.available == usd(40), "payment decreases by 10 from 50")
        try conserve(f.ws, "2025-01")

        // Next-month RTA deduction reflects the remaining cash-like bucket.
        try f.ws.advanceObservedMonth(to: month("2025-02"))
        let jan = try f.ws.projection().month(month("2025-01"))!
        #expect(jan.cashOverspendingAtEnd == usd(20))
        try conserve(f.ws, "2025-02")
    }

    @Test("14: one category across two credit cards — segments debit their own payment categories")
    func golden14() throws {
        var ws = try makeWorkspace()
        let dining = ws.categoryID(named: "Dining")
        _ = try ws.addAccount(
            name: "Checking", type: .checking, onBudget: true,
            openingBalance: usd(1000), openingDate: date("2025-01-01"), nowEpoch: testEpoch
        )
        let cardA = try ws.addAccount(
            name: "Card A", type: .creditCard, onBudget: true,
            openingBalance: -usd(200), openingDate: date("2025-01-01"), nowEpoch: testEpoch
        )
        let cardB = try ws.addAccount(
            name: "Card B", type: .creditCard, onBudget: true,
            openingBalance: -usd(50), openingDate: date("2025-01-01"), nowEpoch: testEpoch
        )
        let paymentA = ws.categories.values.first { $0.kind == .ccPayment && $0.linkedAccountID == cardA }!.id
        let paymentB = ws.categories.values.first { $0.kind == .ccPayment && $0.linkedAccountID == cardB }!.id

        try ws.setBudgeted(categoryID: dining, month: month("2025-01"), value: usd(100))
        let purchaseA = try ws.addManualTransaction(
            accountID: cardA, date: date("2025-01-05"), payeeName: "Cafe",
            categoryID: dining, amountMilliunits: -usd(100), nowEpoch: testEpoch
        )
        try ws.addManualTransaction(
            accountID: cardB, date: date("2025-01-06"), payeeName: "Cafe",
            categoryID: dining, amountMilliunits: -usd(50), nowEpoch: testEpoch
        )
        var snap = try ws.snapshot("2025-01")
        #expect(snap.payments[paymentA]?.available == usd(100))
        #expect(snap.payments[paymentB]?.available == 0)
        #expect(snap.categories[dining]?.creditDebt == usd(50))

        // A refund's origin must be on the same card: cross-card link rejected.
        let before = ws
        #expect(throws: MutationError.refundOriginInvalid) {
            var copy = before
            try copy.addManualTransaction(
                accountID: cardB, date: date("2025-01-07"), payeeName: "Cafe",
                categoryID: dining, amountMilliunits: usd(20), kind: .refund,
                refundOf: purchaseA, nowEpoch: testEpoch
            )
        }

        // Same-card refund on A: d=50 clears creditDebt (from B's purchase),
        // f=25 consumed from A's funded lot → A's own payment category.
        try ws.addManualTransaction(
            accountID: cardA, date: date("2025-01-08"), payeeName: "Cafe",
            categoryID: dining, amountMilliunits: usd(75), kind: .refund,
            refundOf: purchaseA, nowEpoch: testEpoch
        )
        snap = try ws.snapshot("2025-01")
        #expect(snap.categories[dining]?.available == usd(25))
        #expect(snap.categories[dining]?.creditDebt == 0)
        #expect(snap.payments[paymentA]?.available == usd(75), "A debited by its own segment")
        #expect(snap.payments[paymentB]?.available == 0, "B untouched")
        let balances = try ws.projection().projectionBalances
        #expect(balances[cardA]! <= 0 && balances[cardB]! <= 0, "both card guards valid")
        try conserve(ws, "2025-01")
    }

    @Test("15: funded purchase refunded after payment — paymentCashDebt reduces next-month RTA")
    func golden15() throws {
        var f = try fixture()
        try f.ws.setBudgeted(categoryID: f.dining, month: month("2025-01"), value: usd(100))
        let purchase = try f.ws.addManualTransaction(
            accountID: f.card, date: date("2025-01-05"), payeeName: "Cafe",
            categoryID: f.dining, amountMilliunits: -usd(100), nowEpoch: testEpoch
        )
        #expect(try f.ws.projection().projectionBalances[f.card] == -usd(200))
        try f.ws.createManualTransferPair(
            sourceAccountID: f.checking, destinationAccountID: f.card,
            amount: usd(100), date: date("2025-01-06"), nowEpoch: testEpoch
        )
        #expect(try f.ws.projection().projectionBalances[f.card] == -usd(100))

        try f.ws.addManualTransaction(
            accountID: f.card, date: date("2025-01-08"), payeeName: "Cafe",
            categoryID: f.dining, amountMilliunits: usd(40), kind: .refund,
            refundOf: purchase, nowEpoch: testEpoch
        )
        let snap = try f.ws.snapshot("2025-01")
        #expect(try f.ws.projection().projectionBalances[f.card] == -usd(60))
        #expect(snap.categories[f.dining]?.available == usd(40), "spending category +40")
        #expect(snap.payments[f.payment]?.available == -usd(40), "payment envelope -40")
        #expect(snap.payments[f.payment]?.paymentCashDebt == usd(40))
        try conserve(f.ws, "2025-01")

        let rtaJan = snap.rtaEnd
        try f.ws.advanceObservedMonth(to: month("2025-02"))
        let feb = try f.ws.snapshot("2025-02")
        #expect(feb.rtaStart == rtaJan - usd(40), "paymentCashDebt reduces next-month RTA")
        try conserve(f.ws, "2025-02")
    }

    @Test("16: cross-month recovery with funded origin — RTA +100, payment -100, oracle holds")
    func golden16() throws {
        var ws = try makeWorkspace()
        let dining = ws.categoryID(named: "Dining")
        let checking = try ws.addAccount(
            name: "Checking", type: .checking, onBudget: true,
            openingBalance: usd(1000), openingDate: date("2025-01-01"), nowEpoch: testEpoch
        )
        let card = try ws.addAccount(
            name: "Card", type: .creditCard, onBudget: true,
            openingBalance: 0, openingDate: date("2025-01-01"), nowEpoch: testEpoch
        )
        let payment = ws.paymentCategoryIDForOnlyCard()
        try ws.setBudgeted(categoryID: dining, month: month("2025-01"), value: usd(100))
        let purchase = try ws.addManualTransaction(
            accountID: card, date: date("2025-01-10"), payeeName: "Shop",
            categoryID: dining, amountMilliunits: -usd(100), nowEpoch: testEpoch
        )
        var snap = try ws.snapshot("2025-01")
        #expect(snap.categories[dining]?.available == 0)
        #expect(snap.payments[payment]?.available == usd(100))
        #expect(try ws.projection().projectionBalances[card] == -usd(100))

        try ws.advanceObservedMonth(to: month("2025-02"))
        let refund = try ws.importPostedTransaction(
            accountID: card, connectionKey: "c1", remoteAccountID: "a1", remoteTransactionID: "r1",
            postedEpoch: try ws.calendar.noonEpoch(of: date("2025-02-05")),
            payeeName: "Shop", amountMilliunits: usd(100), nowEpoch: testEpoch
        )
        try ws.linkRefundOrigin(refund, originID: purchase, nowEpoch: testEpoch)
        #expect(ws.transactions[refund]?.stageReason == .crossMonthRefund)
        var check = try ConservationCheck.compute(ws, month: month("2025-02"))
        #expect(check.cashLikeAssets == usd(1000))
        #expect(check.rta == usd(900))
        #expect(check.totalPaymentAvailable == usd(100))
        #expect(check.holds, "oracle holds while staged: 1000 == 900 + 100")

        try ws.resolveCrossMonthRefund(refund, nowEpoch: testEpoch)
        let row = ws.transactions[refund]!
        #expect(row.postingState == .posted)
        #expect(row.categoryID == ws.rtaCategoryID)
        #expect(row.payeeID == ws.systemPayeeID(.cardDebtAdjustment))
        #expect(row.refundOfTransactionID == purchase, "origin link retained for audit")
        snap = try ws.snapshot("2025-02")
        #expect(snap.rtaEnd == usd(1000), "RTA activity +100")
        #expect(snap.payments[payment]?.available == -usd(100) + usd(100), "payment category returns to 0")
        let result = try ws.projection()
        #expect(result.projectionBalances[card] == 0, "card -100 → 0")
        #expect(result.registerBalances[card] == 0, "register unchanged by the resolution itself")
        #expect(result.registerBalances[checking] == usd(1000))
        check = try ConservationCheck.compute(ws, month: month("2025-02"))
        #expect(check.holds, "oracle holds after the event: 1000 == 1000")
    }

    @Test("17: cross-month recovery clawback with credit-overspent origin — transient RTA gain clawed back")
    func golden17() throws {
        var ws = try makeWorkspace()
        let dining = ws.categoryID(named: "Dining")
        _ = try ws.addAccount(
            name: "Checking", type: .checking, onBudget: true,
            openingBalance: usd(1000), openingDate: date("2025-01-01"), nowEpoch: testEpoch
        )
        let card = try ws.addAccount(
            name: "Card", type: .creditCard, onBudget: true,
            openingBalance: 0, openingDate: date("2025-01-01"), nowEpoch: testEpoch
        )
        let payment = ws.paymentCategoryIDForOnlyCard()
        let purchase = try ws.addManualTransaction(
            accountID: card, date: date("2025-01-10"), payeeName: "Shop",
            categoryID: dining, amountMilliunits: -usd(100), nowEpoch: testEpoch
        )
        var check = try ConservationCheck.compute(ws, month: month("2025-01"))
        #expect(check.rta == usd(1000))
        #expect(try ws.snapshot("2025-01").categories[dining]?.available == -usd(100))
        #expect(try ws.snapshot("2025-01").categories[dining]?.creditDebt == usd(100))
        #expect(check.holds, "1000 == 1000 + (-100) + 100")

        try ws.advanceObservedMonth(to: month("2025-02"))
        #expect(try ws.snapshot("2025-02").rtaStart == usd(1000), "creditDebt resets with no RTA deduction")

        let refund = try ws.importPostedTransaction(
            accountID: card, connectionKey: "c1", remoteAccountID: "a1", remoteTransactionID: "r1",
            postedEpoch: try ws.calendar.noonEpoch(of: date("2025-02-05")),
            payeeName: "Shop", amountMilliunits: usd(100), nowEpoch: testEpoch
        )
        try ws.linkRefundOrigin(refund, originID: purchase, nowEpoch: testEpoch)
        try ws.resolveCrossMonthRefund(refund, nowEpoch: testEpoch)
        let feb = try ws.snapshot("2025-02")
        #expect(feb.rtaEnd == usd(1100), "RTA 1000 → 1100")
        #expect(feb.payments[payment]?.available == -usd(100), "payment 0 → -100")
        #expect(feb.payments[payment]?.paymentCashDebt == usd(100))
        check = try ConservationCheck.compute(ws, month: month("2025-02"))
        #expect(check.holds, "1000 == 1100 + (-100)")

        try ws.advanceObservedMonth(to: month("2025-03"))
        let mar = try ws.snapshot("2025-03")
        #expect(mar.rtaStart == usd(1000), "paymentCashDebt claws the transient gain back")
        #expect(mar.payments[payment]?.available == 0, "payment category resets to 0")
        check = try ConservationCheck.compute(ws, month: month("2025-03"))
        #expect(check.holds, "no cash was created")
    }
}

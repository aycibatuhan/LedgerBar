import Foundation
import Testing
@testable import LedgerCore

@Suite("RTA and category recurrence — §3.3/§3.4/§3.5.4")
struct RecurrenceTests {

    @Test("RTA base case, signed activity, and monthly recurrence")
    func rtaRecurrence() throws {
        var ws = try makeWorkspace()
        #expect(try ws.snapshot("2025-01").rtaEnd == 0, "RTAStart(first_month) = 0")
        let checking = try ws.addAccount(
            name: "Checking", type: .checking, onBudget: true,
            openingBalance: usd(100), openingDate: date("2025-01-01"), nowEpoch: testEpoch
        )
        #expect(try ws.snapshot("2025-01").rtaEnd == usd(100))
        // Signed activity: a negative adjustment reduces RTA.
        try ws.addReconciliationAdjustment(
            accountID: checking, date: date("2025-01-10"), amountMilliunits: -usd(30), nowEpoch: testEpoch
        )
        #expect(try ws.snapshot("2025-01").rtaEnd == usd(70))
        // Recurrence with no cash overspending: RTA carries.
        try ws.advanceObservedMonth(to: month("2025-02"))
        #expect(try ws.snapshot("2025-02").rtaStart == usd(70))
        try ws.advanceObservedMonth(to: month("2025-03"))
        #expect(try ws.snapshot("2025-03").rtaStart == usd(70))
    }

    @Test("Negative RTA over-assignment carries; cash-like underfunding deducts at boundary")
    func negativeRTAAndUnderfunding() throws {
        var ws = try makeWorkspace()
        let checking = try ws.addAccount(
            name: "Checking", type: .checking, onBudget: true,
            openingBalance: usd(100), openingDate: date("2025-01-01"), nowEpoch: testEpoch
        )
        let groceries = ws.categoryID(named: "Groceries")
        // Over-assign: setBudgeted may exceed RTA, RTAEnd goes negative.
        try ws.setBudgeted(categoryID: groceries, month: month("2025-01"), value: usd(150))
        #expect(try ws.snapshot("2025-01").rtaEnd == -usd(50), "over-assignment displays negative")
        // Cash overspending: spend beyond the envelope.
        try ws.addManualTransaction(
            accountID: checking, date: date("2025-01-05"), payeeName: "Store",
            categoryID: groceries, amountMilliunits: -usd(180), nowEpoch: testEpoch
        )
        let jan = try ws.snapshot("2025-01")
        #expect(jan.categories[groceries]?.available == -usd(30))
        #expect(jan.categories[groceries]?.cashDebt == usd(30))
        #expect(jan.cashOverspendingAtEnd == usd(30))
        try ws.advanceObservedMonth(to: month("2025-02"))
        // RTAStart(next) = RTAEnd - CashOverspendingAtEnd = -50 - 30 = -80.
        #expect(try ws.snapshot("2025-02").rtaStart == -usd(80))
        #expect(try ws.snapshot("2025-02").categories[groceries]?.available == 0, "negative resets")
        #expect(try ConservationCheck.compute(ws, month: month("2025-02")).holds)
    }

    @Test("Category recurrence: positive carry, negative reset")
    func categoryRecurrence() throws {
        var ws = try makeWorkspace()
        _ = try ws.addAccount(
            name: "Checking", type: .checking, onBudget: true,
            openingBalance: usd(500), openingDate: date("2025-01-01"), nowEpoch: testEpoch
        )
        let dining = ws.categoryID(named: "Dining")
        let groceries = ws.categoryID(named: "Groceries")
        try ws.setBudgeted(categoryID: dining, month: month("2025-01"), value: usd(80))
        try ws.setBudgeted(categoryID: groceries, month: month("2025-01"), value: usd(20))
        let checking = ws.accounts.values.first { $0.type == .checking }!.id
        try ws.addManualTransaction(
            accountID: checking, date: date("2025-01-10"), payeeName: "Store",
            categoryID: groceries, amountMilliunits: -usd(50), nowEpoch: testEpoch
        )
        try ws.advanceObservedMonth(to: month("2025-02"))
        let feb = try ws.snapshot("2025-02")
        #expect(feb.categories[dining]?.available == usd(80), "positive carries")
        #expect(feb.categories[groceries]?.available == 0, "negative resets to zero")
    }

    @Test("Multiple cards are isolated: each payment category tracks its own card")
    func multipleCardsIsolated() throws {
        var ws = try makeWorkspace()
        _ = try ws.addAccount(
            name: "Checking", type: .checking, onBudget: true,
            openingBalance: usd(1000), openingDate: date("2025-01-01"), nowEpoch: testEpoch
        )
        let cardA = try ws.addAccount(
            name: "A", type: .creditCard, onBudget: true,
            openingBalance: -usd(100), openingDate: date("2025-01-01"), nowEpoch: testEpoch
        )
        let cardB = try ws.addAccount(
            name: "B", type: .creditCard, onBudget: true,
            openingBalance: -usd(100), openingDate: date("2025-01-01"), nowEpoch: testEpoch
        )
        let payA = ws.categories.values.first { $0.kind == .ccPayment && $0.linkedAccountID == cardA }!.id
        let payB = ws.categories.values.first { $0.kind == .ccPayment && $0.linkedAccountID == cardB }!.id
        let dining = ws.categoryID(named: "Dining")
        let groceries = ws.categoryID(named: "Groceries")
        try ws.setBudgeted(categoryID: dining, month: month("2025-01"), value: usd(50))
        try ws.setBudgeted(categoryID: groceries, month: month("2025-01"), value: usd(50))
        try ws.addManualTransaction(
            accountID: cardA, date: date("2025-01-05"), payeeName: "Cafe",
            categoryID: dining, amountMilliunits: -usd(50), nowEpoch: testEpoch
        )
        try ws.addManualTransaction(
            accountID: cardB, date: date("2025-01-06"), payeeName: "Store",
            categoryID: groceries, amountMilliunits: -usd(30), nowEpoch: testEpoch
        )
        let snap = try ws.snapshot("2025-01")
        #expect(snap.payments[payA]?.available == usd(50))
        #expect(snap.payments[payB]?.available == usd(30))
        #expect(try ConservationCheck.compute(ws, month: month("2025-01")).holds)
    }

    @Test("Negative-debt opening balance creates no automatic payment funding")
    func negativeOpeningNoFunding() throws {
        var ws = try makeWorkspace()
        _ = try ws.addAccount(
            name: "Card", type: .creditCard, onBudget: true,
            openingBalance: -usd(500), openingDate: date("2025-01-01"), nowEpoch: testEpoch
        )
        let payment = ws.paymentCategoryIDForOnlyCard()
        let snap = try ws.snapshot("2025-01")
        #expect(snap.payments[payment]?.available == 0)
        #expect(snap.rtaEnd == 0)
        #expect(try ConservationCheck.compute(ws, month: month("2025-01")).holds)
    }
}

@Suite("Allocation primitives — §3.3 guards")
struct AllocationRuleTests {

    func fixture() throws -> (BudgetWorkspace, AccountID, CategoryID, CategoryID) {
        var ws = try makeWorkspace()
        let checking = try ws.addAccount(
            name: "Checking", type: .checking, onBudget: true,
            openingBalance: usd(500), openingDate: date("2025-01-01"), nowEpoch: testEpoch
        )
        return (ws, checking, ws.categoryID(named: "Dining"), ws.categoryID(named: "Groceries"))
    }

    @Test("setBudgeted rejects negatives, RTA, Uncategorized, and non-current months")
    func setBudgetedGuards() throws {
        var (ws, _, dining, _) = try fixture()
        #expect(throws: MutationError.negativeSetBudgeted) {
            var copy = ws
            try copy.setBudgeted(categoryID: dining, month: month("2025-01"), value: -1)
        }
        #expect(throws: MutationError.allocationTargetNotAllowed) {
            var copy = ws
            try copy.setBudgeted(categoryID: copy.rtaCategoryID, month: month("2025-01"), value: usd(10))
        }
        #expect(throws: MutationError.allocationTargetNotAllowed) {
            var copy = ws
            try copy.setBudgeted(categoryID: copy.uncategorizedID, month: month("2025-01"), value: usd(10))
        }
        #expect(throws: MutationError.allocationMonthNotCurrent) {
            var copy = ws
            try copy.setBudgeted(categoryID: dining, month: month("2025-02"), value: usd(10))
        }
        // Past months are read-only once the clock advances.
        try ws.setBudgeted(categoryID: dining, month: month("2025-01"), value: usd(10))
        try ws.advanceObservedMonth(to: month("2025-02"))
        #expect(throws: MutationError.allocationMonthNotCurrent) {
            var copy = ws
            try copy.setBudgeted(categoryID: dining, month: month("2025-01"), value: usd(20))
        }
    }

    @Test("moveMoney three forms with exact guard bounds")
    func moveMoneyForms() throws {
        var (ws, _, dining, groceries) = try fixture()
        try ws.setBudgeted(categoryID: dining, month: month("2025-01"), value: usd(100))
        // category → category: total assignment unchanged; source floor is its
        // non-negative available.
        try ws.moveMoney(
            source: .category(dining), destination: .category(groceries),
            amount: usd(40), month: month("2025-01"), nowEpoch: testEpoch
        )
        #expect(try ws.available("Dining", in: "2025-01") == usd(60))
        #expect(try ws.available("Groceries", in: "2025-01") == usd(40))
        #expect(try ws.snapshot("2025-01").totalAssigned == usd(100))
        #expect(throws: MutationError.moveMoneySourceUnavailable) {
            var copy = ws
            try copy.moveMoney(
                source: .category(dining), destination: .category(groceries),
                amount: usd(61), month: month("2025-01"), nowEpoch: testEpoch
            )
        }
        // RTA → category bounded by RTADisplayed.
        let rta = try ws.snapshot("2025-01").rtaEnd
        #expect(rta == usd(400))
        #expect(throws: MutationError.moveMoneyRTAUnavailable) {
            var copy = ws
            try copy.moveMoney(
                source: .rta, destination: .category(dining),
                amount: rta + 1, month: month("2025-01"), nowEpoch: testEpoch
            )
        }
        try ws.moveMoney(
            source: .rta, destination: .category(dining),
            amount: usd(100), month: month("2025-01"), nowEpoch: testEpoch
        )
        #expect(try ws.snapshot("2025-01").rtaEnd == usd(300))
        #expect(try ws.available("Dining", in: "2025-01") == usd(160))
        // category → RTA bounded by non-negative available.
        try ws.moveMoney(
            source: .category(dining), destination: .rta,
            amount: usd(160), month: month("2025-01"), nowEpoch: testEpoch
        )
        #expect(try ws.snapshot("2025-01").rtaEnd == usd(460))
        #expect(try ws.available("Dining", in: "2025-01") == 0)
        // Guards: zero/negative amounts, same category, RTA/Uncategorized endpoints.
        #expect(throws: MutationError.moveMoneyAmountNotPositive) {
            var copy = ws
            try copy.moveMoney(source: .rta, destination: .category(dining), amount: 0, month: month("2025-01"), nowEpoch: testEpoch)
        }
        #expect(throws: MutationError.moveMoneySameCategory) {
            var copy = ws
            try copy.moveMoney(source: .category(dining), destination: .category(dining), amount: usd(1), month: month("2025-01"), nowEpoch: testEpoch)
        }
        #expect(throws: MutationError.moveMoneyCategoryNotEligible) {
            var copy = ws
            try copy.moveMoney(source: .category(copy.rtaCategoryID), destination: .category(dining), amount: usd(1), month: month("2025-01"), nowEpoch: testEpoch)
        }
        #expect(throws: MutationError.moveMoneyCategoryNotEligible) {
            var copy = ws
            try copy.moveMoney(source: .category(copy.uncategorizedID), destination: .rta, amount: usd(1), month: month("2025-01"), nowEpoch: testEpoch)
        }
    }

    @Test("moveMoney from a carry-over source can drive its stored allocation negative (audited)")
    func negativeAllocationRow() throws {
        var ws = try makeWorkspace()
        _ = try ws.addAccount(
            name: "Checking", type: .checking, onBudget: true,
            openingBalance: usd(500), openingDate: date("2025-01-01"), nowEpoch: testEpoch
        )
        let dining = ws.categoryID(named: "Dining")
        let groceries = ws.categoryID(named: "Groceries")
        try ws.setBudgeted(categoryID: dining, month: month("2025-01"), value: usd(100))
        try ws.advanceObservedMonth(to: month("2025-02"))
        // February: Dining carries 100 with a zero February allocation.
        #expect(try ws.available("Dining", in: "2025-02") == usd(100))
        try ws.moveMoney(
            source: .category(dining), destination: .category(groceries),
            amount: usd(60), month: month("2025-02"), nowEpoch: testEpoch
        )
        let key = AllocationKey(categoryID: dining, month: month("2025-02"))
        #expect(ws.allocations[key]?.budgetedMilliunits == -usd(60), "stored negative allocation")
        #expect(try ws.available("Dining", in: "2025-02") == usd(40))
        #expect(try ws.available("Groceries", in: "2025-02") == usd(60))
        #expect(ws.auditEvents.contains { $0.eventKind == "moveMoney" }, "audited")
        #expect(try ConservationCheck.compute(ws, month: month("2025-02")).holds)
    }

    @Test("Payment-category source moves are reallocation, not payments")
    func paymentCategorySource() throws {
        var ws = try makeWorkspace()
        _ = try ws.addAccount(
            name: "Checking", type: .checking, onBudget: true,
            openingBalance: usd(1000), openingDate: date("2025-01-01"), nowEpoch: testEpoch
        )
        let card = try ws.addAccount(
            name: "Card", type: .creditCard, onBudget: true,
            openingBalance: -usd(100), openingDate: date("2025-01-01"), nowEpoch: testEpoch
        )
        let payment = ws.paymentCategoryIDForOnlyCard()
        let dining = ws.categoryID(named: "Dining")
        try ws.setBudgeted(categoryID: dining, month: month("2025-01"), value: usd(50))
        try ws.addManualTransaction(
            accountID: card, date: date("2025-01-05"), payeeName: "Cafe",
            categoryID: dining, amountMilliunits: -usd(50), nowEpoch: testEpoch
        )
        #expect(try ws.snapshot("2025-01").payments[payment]?.available == usd(50))
        try ws.moveMoney(
            source: .category(payment), destination: .category(dining),
            amount: usd(20), month: month("2025-01"), nowEpoch: testEpoch
        )
        let snap = try ws.snapshot("2025-01")
        #expect(snap.payments[payment]?.available == usd(30))
        #expect(snap.categories[dining]?.available == usd(20))
        #expect(try ws.projection().projectionBalances[card] == -usd(150), "card balance untouched")
        #expect(try ConservationCheck.compute(ws, month: month("2025-01")).holds)
    }
}

@Suite("Transfers — §3.8 pairing rules")
struct TransferRuleTests {

    func fixture() throws -> (ws: BudgetWorkspace, checking: AccountID, savings: AccountID, card: AccountID, off: AccountID) {
        var ws = try makeWorkspace()
        let checking = try ws.addAccount(
            name: "Checking", type: .checking, onBudget: true,
            openingBalance: usd(1000), openingDate: date("2025-01-01"), nowEpoch: testEpoch
        )
        let savings = try ws.addAccount(
            name: "Savings", type: .savings, onBudget: true,
            openingBalance: usd(500), openingDate: date("2025-01-01"), nowEpoch: testEpoch
        )
        let card = try ws.addAccount(
            name: "Card", type: .creditCard, onBudget: true,
            openingBalance: -usd(300), openingDate: date("2025-01-01"), nowEpoch: testEpoch
        )
        let off = try ws.addAccount(
            name: "Brokerage", type: .other, onBudget: false,
            openingBalance: usd(2000), openingDate: date("2025-01-01"), nowEpoch: testEpoch
        )
        return (ws, checking, savings, card, off)
    }

    @Test("on↔on transfer has zero envelope effect at the oracle checkpoint")
    func onOnTransfer() throws {
        var f = try fixture()
        let rtaBefore = try f.ws.snapshot("2025-01").rtaEnd
        try f.ws.createManualTransferPair(
            sourceAccountID: f.checking, destinationAccountID: f.savings,
            amount: usd(200), date: date("2025-01-10"), nowEpoch: testEpoch
        )
        let result = try f.ws.projection()
        #expect(result.projectionBalances[f.checking] == usd(800))
        #expect(result.projectionBalances[f.savings] == usd(700))
        #expect(try f.ws.snapshot("2025-01").rtaEnd == rtaBefore)
        #expect(try ConservationCheck.compute(f.ws, month: month("2025-01")).holds)
    }

    @Test("on→off requires a spending category; money leaves the plan")
    func onOffTransfer() throws {
        var f = try fixture()
        let savingsCat = f.ws.categoryID(named: "Emergency Fund")
        #expect(throws: MutationError.categoryRequired) {
            var copy = f.ws
            try copy.createManualTransferPair(
                sourceAccountID: copy.accounts.values.first { $0.name == "Checking" }!.id,
                destinationAccountID: copy.accounts.values.first { $0.name == "Brokerage" }!.id,
                amount: usd(100), date: date("2025-01-10"), nowEpoch: testEpoch
            )
        }
        try f.ws.setBudgeted(categoryID: savingsCat, month: month("2025-01"), value: usd(100))
        try f.ws.createManualTransferPair(
            sourceAccountID: f.checking, destinationAccountID: f.off,
            amount: usd(100), date: date("2025-01-10"), onLegCategoryID: savingsCat, nowEpoch: testEpoch
        )
        #expect(try f.ws.available("Emergency Fund", in: "2025-01") == 0)
        #expect(try f.ws.projection().projectionBalances[f.off] == usd(2100))
        #expect(try ConservationCheck.compute(f.ws, month: month("2025-01")).holds)
    }

    @Test("off→on categorizes the on-budget leg to RTA")
    func offOnTransfer() throws {
        var f = try fixture()
        let rtaBefore = try f.ws.snapshot("2025-01").rtaEnd
        try f.ws.createManualTransferPair(
            sourceAccountID: f.off, destinationAccountID: f.checking,
            amount: usd(150), date: date("2025-01-10"), nowEpoch: testEpoch
        )
        #expect(try f.ws.snapshot("2025-01").rtaEnd == rtaBefore + usd(150), "money enters the plan")
        #expect(try ConservationCheck.compute(f.ws, month: month("2025-01")).holds)
    }

    @Test("card→cash, card→card, off→card, and mismatched-currency pairs are rejected")
    func rejectedPairs() throws {
        var f = try fixture()
        let eur = try f.ws.addAccount(
            name: "EUR Account", type: .checking, onBudget: true, currency: "EUR",
            openingBalance: 0, openingDate: date("2025-01-01"), nowEpoch: testEpoch
        )
        let card2 = try f.ws.addAccount(
            name: "Card 2", type: .creditCard, onBudget: true,
            openingBalance: -usd(50), openingDate: date("2025-01-01"), nowEpoch: testEpoch
        )
        #expect(throws: MutationError.unsupportedTransferPair) {
            var copy = f.ws
            try copy.createManualTransferPair(
                sourceAccountID: f.card, destinationAccountID: f.checking,
                amount: usd(50), date: date("2025-01-10"), nowEpoch: testEpoch
            )
        }
        #expect(throws: MutationError.unsupportedTransferPair) {
            var copy = f.ws
            try copy.createManualTransferPair(
                sourceAccountID: f.card, destinationAccountID: card2,
                amount: usd(50), date: date("2025-01-10"), nowEpoch: testEpoch
            )
        }
        #expect(throws: MutationError.unsupportedTransferPair) {
            var copy = f.ws
            try copy.createManualTransferPair(
                sourceAccountID: f.off, destinationAccountID: f.card,
                amount: usd(50), date: date("2025-01-10"), nowEpoch: testEpoch
            )
        }
        #expect(throws: MutationError.currencyMismatch) {
            var copy = f.ws
            try copy.createManualTransferPair(
                sourceAccountID: f.checking, destinationAccountID: eur,
                amount: usd(50), date: date("2025-01-10"), nowEpoch: testEpoch
            )
        }
    }

    @Test("Pairing two existing imported rows validates window and month; unpair restores snapshots")
    func pairExistingAndUnpair() throws {
        var f = try fixture()
        let noonJan10 = try f.ws.calendar.noonEpoch(of: date("2025-01-10"))
        let noonJan12 = try f.ws.calendar.noonEpoch(of: date("2025-01-12"))
        let outflow = try f.ws.importPostedTransaction(
            accountID: f.checking, connectionKey: "c1", remoteAccountID: "chk", remoteTransactionID: "o1",
            postedEpoch: noonJan10, payeeName: "TRANSFER TO SAVINGS", amountMilliunits: -usd(200), nowEpoch: testEpoch
        )
        let inflow = try f.ws.importPostedTransaction(
            accountID: f.savings, connectionKey: "c1", remoteAccountID: "sav", remoteTransactionID: "i1",
            postedEpoch: noonJan12, payeeName: "TRANSFER FROM CHECKING", amountMilliunits: usd(200), nowEpoch: testEpoch
        )
        // The imported outflow sits in Uncategorized/needsCategory before pairing.
        #expect(f.ws.transactions[outflow]?.postingState == .needsCategory)
        let pairID = try f.ws.pairExistingTransactions(outflow, inflow, nowEpoch: testEpoch)
        #expect(f.ws.transactions[outflow]?.postingState == .posted)
        #expect(f.ws.transactions[outflow]?.categoryID == nil)
        #expect(f.ws.transactions[outflow]?.payeeID == f.ws.systemPayeeID(.transfer))
        #expect(try ConservationCheck.compute(f.ws, month: month("2025-01")).holds)

        try f.ws.unpairTransferPair(pairID, nowEpoch: testEpoch)
        let restored = f.ws.transactions[outflow]!
        #expect(restored.transferPairID == nil)
        #expect(restored.categoryID == f.ws.uncategorizedID, "standalone snapshot restored exactly")
        #expect(restored.postingState == .needsCategory)
        #expect(f.ws.transferPairs[pairID]?.status == .unpaired)
        #expect(try ConservationCheck.compute(f.ws, month: month("2025-01")).holds)
    }

    @Test("Unpairing a pair created from blank legs leaves them staged for explicit categorization")
    func unpairBlankLegs() throws {
        var f = try fixture()
        let pairID = try f.ws.createManualTransferPair(
            sourceAccountID: f.checking, destinationAccountID: f.savings,
            amount: usd(100), date: date("2025-01-10"), nowEpoch: testEpoch
        )
        try f.ws.unpairTransferPair(pairID, nowEpoch: testEpoch)
        let legs = f.ws.transactions.values.filter { $0.payeeID == f.ws.systemPayeeID(.transfer) }
        #expect(legs.count == 2)
        for leg in legs {
            #expect(leg.postingState == .staged)
            #expect(leg.stageReason == .transferPairUnpairNeedsCategorization)
            #expect(leg.categoryID == nil, "never a sign-based RTA/category default")
        }
        #expect(try ConservationCheck.compute(f.ws, month: month("2025-01")).holds)
    }

    @Test("blank transfer legs require explicit standalone categorization after unpair")
    func resolveUnpairedBlankLegsExplicitly() throws {
        var f = try fixture()
        let pairID = try f.ws.createManualTransferPair(
            sourceAccountID: f.checking,
            destinationAccountID: f.savings,
            amount: usd(100),
            date: date("2025-01-10"),
            nowEpoch: testEpoch
        )
        try f.ws.unpairTransferPair(pairID, nowEpoch: testEpoch)
        let outflow = try #require(f.ws.transactions.values.first {
            $0.stageReason == .transferPairUnpairNeedsCategorization && $0.amountMilliunits < 0
        })
        let inflow = try #require(f.ws.transactions.values.first {
            $0.stageReason == .transferPairUnpairNeedsCategorization && $0.amountMilliunits > 0
        })

        #expect(throws: MutationError.categoryRequired) {
            try f.ws.resolveUnpairedTransferLeg(outflow.id, nowEpoch: testEpoch)
        }
        try f.ws.resolveUnpairedTransferLeg(
            outflow.id,
            categoryID: f.ws.categoryID(named: "Groceries"),
            nowEpoch: testEpoch
        )
        try f.ws.resolveUnpairedTransferLeg(inflow.id, nowEpoch: testEpoch)

        #expect(f.ws.transactions[outflow.id]?.postingState == .posted)
        #expect(f.ws.transactions[outflow.id]?.categoryID == f.ws.categoryID(named: "Groceries"))
        #expect(f.ws.transactions[inflow.id]?.postingState == .posted)
        #expect(f.ws.transactions[inflow.id]?.categoryID == f.ws.rtaCategoryID)
        #expect(f.ws.transactions[outflow.id]?.stageReason == nil)
        #expect(f.ws.transactions[inflow.id]?.stageReason == nil)
        #expect(f.ws.transferPairs[pairID]?.status == .unpaired)
        #expect(f.ws.auditEvents.contains { $0.eventKind == "resolveUnpairedTransferLeg" })
        #expect(try ConservationCheck.compute(f.ws, month: month("2025-01")).holds)
    }

    @Test("Deleting a pair with imported legs soft-voids both; manual pairs delete physically")
    func deletePairRules() throws {
        var f = try fixture()
        // Manual pair: physical delete.
        let manualPair = try f.ws.createManualTransferPair(
            sourceAccountID: f.checking, destinationAccountID: f.savings,
            amount: usd(50), date: date("2025-01-05"), nowEpoch: testEpoch
        )
        let manualLegIDs = f.ws.transactions.values.filter { $0.transferPairID == manualPair }.map(\.id)
        try f.ws.deleteTransferPair(manualPair, nowEpoch: testEpoch)
        #expect(f.ws.transferPairs[manualPair] == nil)
        for id in manualLegIDs { #expect(f.ws.transactions[id] == nil) }

        // Imported pair: soft-void with tombstones.
        let noon = try f.ws.calendar.noonEpoch(of: date("2025-01-10"))
        let o = try f.ws.importPostedTransaction(
            accountID: f.checking, connectionKey: "c1", remoteAccountID: "chk", remoteTransactionID: "o2",
            postedEpoch: noon, payeeName: "X", amountMilliunits: -usd(75), nowEpoch: testEpoch
        )
        let i = try f.ws.importPostedTransaction(
            accountID: f.savings, connectionKey: "c1", remoteAccountID: "sav", remoteTransactionID: "i2",
            postedEpoch: noon, payeeName: "X", amountMilliunits: usd(75), nowEpoch: testEpoch
        )
        let importedPair = try f.ws.pairExistingTransactions(o, i, nowEpoch: testEpoch)
        try f.ws.deleteTransferPair(importedPair, nowEpoch: testEpoch)
        #expect(f.ws.transferPairs[importedPair]?.status == .voided)
        #expect(f.ws.transactions[o]?.postingState == .voided, "import tombstone retained")
        #expect(f.ws.transactions[i]?.postingState == .voided)
        #expect(try ConservationCheck.compute(f.ws, month: month("2025-01")).holds)
    }

    @Test("±7-day window and same-month rule for pairing existing rows")
    func pairingWindow() throws {
        var f = try fixture()
        let far = try f.ws.importPostedTransaction(
            accountID: f.checking, connectionKey: "c1", remoteAccountID: "chk", remoteTransactionID: "w1",
            postedEpoch: try f.ws.calendar.noonEpoch(of: date("2025-01-02")),
            payeeName: "X", amountMilliunits: -usd(10), nowEpoch: testEpoch
        )
        let late = try f.ws.importPostedTransaction(
            accountID: f.savings, connectionKey: "c1", remoteAccountID: "sav", remoteTransactionID: "w2",
            postedEpoch: try f.ws.calendar.noonEpoch(of: date("2025-01-20")),
            payeeName: "X", amountMilliunits: usd(10), nowEpoch: testEpoch
        )
        #expect(throws: MutationError.transferLegsInvalid) {
            var copy = f.ws
            _ = try copy.pairExistingTransactions(far, late, nowEpoch: testEpoch)
        }
    }
}

import Foundation
import Testing
@testable import LedgerCore

@Suite("Import lifecycle — §4.3 classification, dedup, payee learning")
struct ImportLifecycleTests {

    func fixture() throws -> (ws: BudgetWorkspace, checking: AccountID) {
        var ws = try makeWorkspace()
        let checking = try ws.addAccount(
            name: "Checking", type: .checking, onBudget: true,
            openingBalance: usd(500), openingDate: date("2025-01-01"), nowEpoch: testEpoch
        )
        return (ws, checking)
    }

    @Test("Imported outflow without category → Uncategorized/needsCategory, included in projection")
    func uncategorizedOutflow() throws {
        var f = try fixture()
        let id = try f.ws.importPostedTransaction(
            accountID: f.checking, connectionKey: "c1", remoteAccountID: "chk", remoteTransactionID: "t1",
            postedEpoch: try f.ws.calendar.noonEpoch(of: date("2025-01-10")),
            payeeName: "MYSTERY SHOP", amountMilliunits: -usd(40), nowEpoch: testEpoch
        )
        let row = f.ws.transactions[id]!
        #expect(row.postingState == .needsCategory)
        #expect(row.categoryID == f.ws.uncategorizedID)
        #expect(row.approved == false)
        let snap = try f.ws.snapshot("2025-01")
        #expect(snap.categories[f.ws.uncategorizedID]?.available == -usd(40),
                "activity included in the projection until categorized")
        #expect(try f.ws.projection().projectionBalances[f.checking] == usd(460))
        #expect(try ConservationCheck.compute(f.ws, month: month("2025-01")).holds)
    }

    @Test("Imported positive inflow defaults to RTA, posted and unapproved")
    func positiveInflowDefault() throws {
        var f = try fixture()
        let id = try f.ws.importPostedTransaction(
            accountID: f.checking, connectionKey: "c1", remoteAccountID: "chk", remoteTransactionID: "t2",
            postedEpoch: try f.ws.calendar.noonEpoch(of: date("2025-01-11")),
            payeeName: "EMPLOYER", amountMilliunits: usd(1000), nowEpoch: testEpoch
        )
        let row = f.ws.transactions[id]!
        #expect(row.postingState == .posted)
        #expect(row.categoryID == f.ws.rtaCategoryID)
        #expect(row.approved == false, "remains visibly unapproved")
        #expect(try f.ws.snapshot("2025-01").rtaEnd == usd(1500))
    }

    @Test("Composite-identity dedup: the same remote row imports once")
    func dedup() throws {
        var f = try fixture()
        let epoch = try f.ws.calendar.noonEpoch(of: date("2025-01-10"))
        let first = try f.ws.importPostedTransaction(
            accountID: f.checking, connectionKey: "c1", remoteAccountID: "chk", remoteTransactionID: "dup",
            postedEpoch: epoch, payeeName: "SHOP", amountMilliunits: -usd(25), nowEpoch: testEpoch
        )
        let second = try f.ws.importPostedTransaction(
            accountID: f.checking, connectionKey: "c1", remoteAccountID: "chk", remoteTransactionID: "dup",
            postedEpoch: epoch, payeeName: "SHOP", amountMilliunits: -usd(25), nowEpoch: testEpoch
        )
        #expect(first == second)
        #expect(f.ws.transactions.values.filter { $0.sourceKind == .simplefin }.count == 1)
        // A different remote id on another connection key is a distinct row.
        let third = try f.ws.importPostedTransaction(
            accountID: f.checking, connectionKey: "c2", remoteAccountID: "chk", remoteTransactionID: "dup",
            postedEpoch: epoch, payeeName: "SHOP", amountMilliunits: -usd(25), nowEpoch: testEpoch
        )
        #expect(third != first)
    }

    @Test("Payee learning: explicit categorization drives exact-payee auto-categorization")
    func payeeLearning() throws {
        var f = try fixture()
        let groceries = f.ws.categoryID(named: "Groceries")
        let firstImport = try f.ws.importPostedTransaction(
            accountID: f.checking, connectionKey: "c1", remoteAccountID: "chk", remoteTransactionID: "p1",
            postedEpoch: try f.ws.calendar.noonEpoch(of: date("2025-01-05")),
            payeeName: "Whole  Foods  Market", amountMilliunits: -usd(30), nowEpoch: testEpoch
        )
        #expect(f.ws.transactions[firstImport]?.postingState == .needsCategory)
        try f.ws.categorize(transactionID: firstImport, categoryID: groceries, nowEpoch: testEpoch)
        #expect(f.ws.transactions[firstImport]?.postingState == .posted)

        // Same normalized payee (case/whitespace-insensitive) auto-categorizes.
        let secondImport = try f.ws.importPostedTransaction(
            accountID: f.checking, connectionKey: "c1", remoteAccountID: "chk", remoteTransactionID: "p2",
            postedEpoch: try f.ws.calendar.noonEpoch(of: date("2025-01-12")),
            payeeName: "whole foods market", amountMilliunits: -usd(45), nowEpoch: testEpoch
        )
        let row = f.ws.transactions[secondImport]!
        #expect(row.categoryID == groceries, "exact normalized-payee history applied")
        #expect(row.postingState == .posted)
        #expect(row.approved == false)
        // Sign-incompatible remembered category falls through to the default.
        let inflow = try f.ws.importPostedTransaction(
            accountID: f.checking, connectionKey: "c1", remoteAccountID: "chk", remoteTransactionID: "p3",
            postedEpoch: try f.ws.calendar.noonEpoch(of: date("2025-01-13")),
            payeeName: "WHOLE FOODS MARKET", amountMilliunits: usd(10), nowEpoch: testEpoch
        )
        #expect(f.ws.transactions[inflow]?.categoryID == f.ws.rtaCategoryID)
    }

    @Test("Normalization is NFKC + uppercase + whitespace collapse")
    func normalization() {
        #expect(BudgetWorkspace.normalizePayeeName("  café   du  Monde ") == "CAFÉ DU MONDE")
        #expect(BudgetWorkspace.normalizePayeeName("ｗｉｄｅ") == "WIDE", "NFKC folds full-width forms")
        #expect(BudgetWorkspace.normalizePayeeName("a\u{00A0}b") == "A B", "non-breaking space collapses")
    }
}

@Suite("Closed months — §2.1 append-only exception and reopen workflow")
struct ClosedMonthTests {

    @Test("Closing blocks user mutations; imports append staged; reopen restores the workflow")
    func closedMonthLifecycle() throws {
        var ws = try makeWorkspace()
        let checking = try ws.addAccount(
            name: "Checking", type: .checking, onBudget: true,
            openingBalance: usd(500), openingDate: date("2025-01-01"), nowEpoch: testEpoch
        )
        let groceries = ws.categoryID(named: "Groceries")
        let janTxn = try ws.addManualTransaction(
            accountID: checking, date: date("2025-01-10"), payeeName: "Store",
            categoryID: groceries, amountMilliunits: -usd(50), nowEpoch: testEpoch
        )
        try ws.advanceObservedMonth(to: month("2025-02"))
        try ws.closeMonth(month("2025-01"), nowEpoch: testEpoch)

        // User edits/deletes/inserts in the closed month are rejected.
        #expect(throws: MutationError.closedMonth) {
            var copy = ws
            try copy.updateAmount(transactionID: janTxn, amountMilliunits: -usd(60), nowEpoch: testEpoch)
        }
        #expect(throws: MutationError.closedMonth) {
            var copy = ws
            try copy.deleteTransaction(janTxn, nowEpoch: testEpoch)
        }
        #expect(throws: MutationError.closedMonth) {
            var copy = ws
            try copy.addManualTransaction(
                accountID: checking, date: date("2025-01-15"), payeeName: "Store",
                categoryID: groceries, amountMilliunits: -usd(10), nowEpoch: testEpoch
            )
        }
        #expect(throws: MutationError.closedMonth) {
            var copy = ws
            try copy.categorize(transactionID: janTxn, categoryID: copy.categoryID(named: "Dining"), nowEpoch: testEpoch)
        }

        // Append-only exception: a new remote row lands as staged closedMonthImport.
        let imported = try ws.importPostedTransaction(
            accountID: checking, connectionKey: "c1", remoteAccountID: "chk", remoteTransactionID: "late1",
            postedEpoch: try ws.calendar.noonEpoch(of: date("2025-01-20")),
            payeeName: "LATE POST", amountMilliunits: -usd(20), nowEpoch: testEpoch
        )
        let row = ws.transactions[imported]!
        #expect(row.postingState == .staged)
        #expect(row.stageReason == .closedMonthImport)
        let result = try ws.projection()
        #expect(result.registerBalances[checking] == usd(430), "register includes the append")
        #expect(result.projectionBalances[checking] == usd(450), "projection excludes it while closed")

        // It is never auto-resolved while closed — replay keeps it staged.
        try ws.advanceObservedMonth(to: month("2025-03"))
        #expect(ws.transactions[imported]?.postingState == .staged)

        // Reopen: audited, and the normal replay pass may now resolve it.
        try ws.reopenMonth(month("2025-01"), nowEpoch: testEpoch)
        #expect(ws.transactions[imported]?.postingState == .needsCategory,
                "after reopen the deterministic pass reclassifies the appended row")
        #expect(ws.auditEvents.contains { $0.eventKind == "reopen" })
        #expect(try ConservationCheck.compute(ws, month: month("2025-03")).holds)
    }
}

@Suite("Edits and dependents — §3.8")
struct EditRuleTests {

    @Test("Origin recategorization updates the dependent refund's materialized copy atomically")
    func originRecategorization() throws {
        var ws = try makeWorkspace()
        _ = try ws.addAccount(
            name: "Checking", type: .checking, onBudget: true,
            openingBalance: usd(1000), openingDate: date("2025-01-01"), nowEpoch: testEpoch
        )
        let card = try ws.addAccount(
            name: "Card", type: .creditCard, onBudget: true,
            openingBalance: -usd(300), openingDate: date("2025-01-01"), nowEpoch: testEpoch
        )
        let dining = ws.categoryID(named: "Dining")
        let groceries = ws.categoryID(named: "Groceries")
        try ws.setBudgeted(categoryID: dining, month: month("2025-01"), value: usd(100))
        try ws.setBudgeted(categoryID: groceries, month: month("2025-01"), value: usd(100))
        let purchase = try ws.addManualTransaction(
            accountID: card, date: date("2025-01-05"), payeeName: "Shop",
            categoryID: dining, amountMilliunits: -usd(80), nowEpoch: testEpoch
        )
        let refund = try ws.addManualTransaction(
            accountID: card, date: date("2025-01-08"), payeeName: "Shop",
            categoryID: dining, amountMilliunits: usd(30), kind: .refund,
            refundOf: purchase, nowEpoch: testEpoch
        )
        // Direct recategorization of a linked refund is rejected.
        #expect(throws: MutationError.categoryNotAllowed) {
            var copy = ws
            try copy.categorize(transactionID: refund, categoryID: groceries, nowEpoch: testEpoch)
        }
        // Recategorizing the origin updates the refund's copy in one mutation.
        try ws.categorize(transactionID: purchase, categoryID: groceries, nowEpoch: testEpoch)
        #expect(ws.transactions[refund]?.categoryID == groceries)
        let snap = try ws.snapshot("2025-01")
        #expect(snap.categories[groceries]?.available == usd(100) - usd(80) + usd(30))
        #expect(snap.categories[dining]?.available == usd(100))
        #expect(try ConservationCheck.compute(ws, month: month("2025-01")).holds)
    }

    @Test("Shrinking an origin re-stages its over-sized refund; imported amounts are immutable")
    func editReStagesDependents() throws {
        var ws = try makeWorkspace()
        _ = try ws.addAccount(
            name: "Checking", type: .checking, onBudget: true,
            openingBalance: usd(1000), openingDate: date("2025-01-01"), nowEpoch: testEpoch
        )
        let card = try ws.addAccount(
            name: "Card", type: .creditCard, onBudget: true,
            openingBalance: -usd(300), openingDate: date("2025-01-01"), nowEpoch: testEpoch
        )
        let dining = ws.categoryID(named: "Dining")
        let purchase = try ws.addManualTransaction(
            accountID: card, date: date("2025-01-05"), payeeName: "Shop",
            categoryID: dining, amountMilliunits: -usd(80), nowEpoch: testEpoch
        )
        let refund = try ws.addManualTransaction(
            accountID: card, date: date("2025-01-08"), payeeName: "Shop",
            categoryID: dining, amountMilliunits: usd(50), kind: .refund,
            refundOf: purchase, nowEpoch: testEpoch
        )
        try ws.updateAmount(transactionID: purchase, amountMilliunits: -usd(40), nowEpoch: testEpoch)
        let row = ws.transactions[refund]!
        #expect(row.postingState == .staged, "dependent refund atomically re-staged")
        #expect(row.stageReason == .overRefund)
        #expect(try ConservationCheck.compute(ws, month: month("2025-01")).holds)

        // Growing the origin back rehabilitates the refund deterministically.
        try ws.updateAmount(transactionID: purchase, amountMilliunits: -usd(80), nowEpoch: testEpoch)
        #expect(ws.transactions[refund]?.postingState == .posted)
        #expect(ws.transactions[refund]?.categoryID == dining, "materialized copy restored")

        // Imported rows: amount edits rejected.
        let imported = try ws.importPostedTransaction(
            accountID: card, connectionKey: "c1", remoteAccountID: "cc", remoteTransactionID: "x1",
            postedEpoch: try ws.calendar.noonEpoch(of: date("2025-01-12")),
            payeeName: "SHOP", amountMilliunits: -usd(15), nowEpoch: testEpoch
        )
        #expect(throws: MutationError.transactionImmutable) {
            var copy = ws
            try copy.updateAmount(transactionID: imported, amountMilliunits: -usd(20), nowEpoch: testEpoch)
        }
    }

    @Test("Date edits recompute effective ordering; a soft-voided origin re-stages its refund")
    func dateEditsAndVoid() throws {
        var ws = try makeWorkspace()
        _ = try ws.addAccount(
            name: "Checking", type: .checking, onBudget: true,
            openingBalance: usd(1000), openingDate: date("2025-01-01"), nowEpoch: testEpoch
        )
        let card = try ws.addAccount(
            name: "Card", type: .creditCard, onBudget: true,
            openingBalance: -usd(300), openingDate: date("2025-01-01"), nowEpoch: testEpoch
        )
        let dining = ws.categoryID(named: "Dining")
        // Imported purchase, then linked imported refund.
        let purchase = try ws.importPostedTransaction(
            accountID: card, connectionKey: "c1", remoteAccountID: "cc", remoteTransactionID: "buy",
            postedEpoch: try ws.calendar.noonEpoch(of: date("2025-01-05")),
            payeeName: "SHOP", amountMilliunits: -usd(60), nowEpoch: testEpoch
        )
        try ws.categorize(transactionID: purchase, categoryID: dining, nowEpoch: testEpoch)
        let refund = try ws.importPostedTransaction(
            accountID: card, connectionKey: "c1", remoteAccountID: "cc", remoteTransactionID: "ref",
            postedEpoch: try ws.calendar.noonEpoch(of: date("2025-01-10")),
            payeeName: "SHOP", amountMilliunits: usd(25), nowEpoch: testEpoch
        )
        try ws.linkRefundOrigin(refund, originID: purchase, nowEpoch: testEpoch)
        #expect(ws.transactions[refund]?.postingState == .posted)

        // Date edit on the imported refund keeps the remote source key but
        // moves the effective epoch; moving it before the origin re-stages it.
        try ws.updateDate(transactionID: refund, date: date("2025-01-02"), nowEpoch: testEpoch)
        let moved = ws.transactions[refund]!
        #expect(moved.postingState == .staged, "refund now precedes its origin in replay order")
        #expect(moved.stageReason == .missingRefundOrigin)
        #expect(moved.sourceOrderKey.rawValue.hasPrefix("remote:"), "remote key retained")
        try ws.updateDate(transactionID: refund, date: date("2025-01-12"), nowEpoch: testEpoch)
        #expect(ws.transactions[refund]?.postingState == .posted)

        // Soft-voiding the imported origin re-stages the dependent refund.
        try ws.deleteTransaction(purchase, nowEpoch: testEpoch)
        #expect(ws.transactions[purchase]?.postingState == .voided, "imported rows are never physically deleted")
        #expect(ws.transactions[refund]?.postingState == .staged)
        #expect(ws.transactions[refund]?.stageReason == .missingRefundOrigin)
        #expect(try ConservationCheck.compute(ws, month: month("2025-01")).holds)
    }
}

@Suite("Engine internals — checkpoints and idempotence")
struct EngineInternalTests {

    @Test("Replay from any captured checkpoint equals the full replay")
    func checkpointEquivalence() throws {
        var ws = try makeWorkspace()
        let checking = try ws.addAccount(
            name: "Checking", type: .checking, onBudget: true,
            openingBalance: usd(1000), openingDate: date("2025-01-01"), nowEpoch: testEpoch
        )
        let card = try ws.addAccount(
            name: "Card", type: .creditCard, onBudget: true,
            openingBalance: -usd(100), openingDate: date("2025-01-01"), nowEpoch: testEpoch
        )
        let dining = ws.categoryID(named: "Dining")
        try ws.setBudgeted(categoryID: dining, month: month("2025-01"), value: usd(100))
        try ws.addManualTransaction(
            accountID: card, date: date("2025-01-05"), payeeName: "Cafe",
            categoryID: dining, amountMilliunits: -usd(150), nowEpoch: testEpoch
        )
        try ws.advanceObservedMonth(to: month("2025-02"))
        try ws.addManualTransaction(
            accountID: checking, date: date("2025-02-03"), payeeName: "Employer",
            categoryID: ws.rtaCategoryID, amountMilliunits: usd(500), nowEpoch: testEpoch
        )
        try ws.setBudgeted(categoryID: dining, month: month("2025-02"), value: usd(60))
        try ws.advanceObservedMonth(to: month("2025-03"))
        try ws.addManualTransaction(
            accountID: card, date: date("2025-03-04"), payeeName: "Cafe",
            categoryID: dining, amountMilliunits: -usd(20), nowEpoch: testEpoch
        )

        let full = try ReplayEngine.replay(ws.replayInput())
        for (m, checkpoint) in full.checkpoints {
            let resumed = try ReplayEngine.replay(ws.replayInput(), startingAt: checkpoint)
            #expect(resumed.registerBalances == full.registerBalances, "register parity from \(m)")
            #expect(resumed.projectionBalances == full.projectionBalances, "projection parity from \(m)")
            #expect(resumed.postingDecisions == full.postingDecisions, "decision parity from \(m)")
            for snap in resumed.months {
                #expect(full.month(snap.month) == snap, "month snapshot parity for \(snap.month) from \(m)")
            }
        }
    }

    @Test("The re-staging pass is idempotent: a second replay changes nothing")
    func idempotence() throws {
        var ws = try makeWorkspace()
        _ = try ws.addAccount(
            name: "Checking", type: .checking, onBudget: true,
            openingBalance: usd(300), openingDate: date("2025-01-01"), nowEpoch: testEpoch
        )
        let card = try ws.addAccount(
            name: "Card", type: .creditCard, onBudget: true,
            openingBalance: -usd(50), openingDate: date("2025-01-01"), nowEpoch: testEpoch
        )
        _ = try ws.importPostedTransaction(
            accountID: card, connectionKey: "c1", remoteAccountID: "cc", remoteTransactionID: "s1",
            postedEpoch: try ws.calendar.noonEpoch(of: date("2025-01-08")),
            payeeName: "CREDIT", amountMilliunits: usd(80), nowEpoch: testEpoch
        )
        var copy = ws
        try copy.runReplayAndApplyDecisions()
        #expect(copy.transactions == ws.transactions, "second pass is a no-op")
    }

    @Test("Overflow in replay arithmetic is rejected without state corruption")
    func overflowRejection() throws {
        var ws = try makeWorkspace()
        let checking = try ws.addAccount(
            name: "Checking", type: .checking, onBudget: true,
            openingBalance: Int64.max - 10, openingDate: date("2025-01-01"), nowEpoch: testEpoch
        )
        let before = ws
        #expect(throws: ArithmeticOverflowError.self) {
            var copy = before
            try copy.addManualTransaction(
                accountID: checking, date: date("2025-01-05"), payeeName: "Bank",
                categoryID: copy.rtaCategoryID, amountMilliunits: 100, nowEpoch: testEpoch
            )
        }
        #expect(ws == before)
    }
}

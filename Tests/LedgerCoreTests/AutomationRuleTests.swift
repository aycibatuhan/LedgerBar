import Foundation
import Testing
@testable import LedgerCore

@Suite("Automation rules — D4")
struct AutomationRuleTests {

    private func fixture() throws -> (ws: BudgetWorkspace, checking: AccountID, card: AccountID) {
        var ws = try makeWorkspace()
        let checking = try ws.addAccount(
            name: "Checking", type: .checking, onBudget: true,
            openingBalance: usd(1000), openingDate: date("2025-01-01"), nowEpoch: testEpoch
        )
        let card = try ws.addAccount(
            name: "Card", type: .creditCard, onBudget: true,
            openingBalance: -usd(100), openingDate: date("2025-01-01"), nowEpoch: testEpoch
        )
        return (ws, checking, card)
    }

    @discardableResult
    private func importRow(
        _ ws: inout BudgetWorkspace, account: AccountID, id: String, day: Int,
        payee: String, amount: Milliunits, memo: String? = nil
    ) throws -> TransactionID {
        try ws.importPostedTransaction(
            accountID: account, connectionKey: "c1", remoteAccountID: "a1", remoteTransactionID: id,
            postedEpoch: try ws.calendar.noonEpoch(of: date(String(format: "2025-01-%02d", day))),
            payeeName: payee, amountMilliunits: amount, memo: memo, nowEpoch: testEpoch
        )
    }

    @Test("Import applies matching rules before payee learning; raw description is kept")
    func importAppliesRules() throws {
        var f = try fixture()
        let groceries = f.ws.categoryID(named: "Groceries")
        try f.ws.addRule(
            name: "Trader Joe's",
            conditions: [.importedDescription(.contains, "trader joe"), .account(f.checking)],
            actions: [.setPayee("Trader Joe's"), .setCategory(groceries), .setMemo(.append, "auto")],
            nowEpoch: testEpoch
        )
        let id = try importRow(&f.ws, account: f.checking, id: "r1", day: 5, payee: "TRADER JOE'S #123 SAN FR", amount: -usd(42))
        let row = try #require(f.ws.transactions[id])
        #expect(row.importedDescription == "TRADER JOE'S #123 SAN FR")
        #expect(f.ws.payees[row.payeeID!]?.displayName == "Trader Joe's")
        #expect(row.categoryID == groceries)
        #expect(row.postingState == .posted)
        #expect(row.memo == "auto")
        #expect(row.approved == false, "rules never approve unless asked")
        #expect(f.ws.lastRuleApplication(for: id) != nil)
        // The account condition keeps it from firing on the card.
        let cardRow = try importRow(&f.ws, account: f.card, id: "r2", day: 6, payee: "TRADER JOE'S #123", amount: -usd(10))
        #expect(f.ws.transactions[cardRow]?.categoryID == f.ws.uncategorizedID)
        #expect(try ConservationCheck.compute(f.ws, month: month("2025-01")).holds)
    }

    @Test("Ordering: a later rule sees the earlier rule's changes; stopAfterMatch ends the pass")
    func orderingAndStop() throws {
        var f = try fixture()
        let groceries = f.ws.categoryID(named: "Groceries")
        let dining = f.ws.categoryID(named: "Dining")
        let first = try f.ws.addRule(
            name: "rename", conditions: [.importedDescription(.startsWith, "SQ *")],
            actions: [.setPayee("Cafe Luna")], nowEpoch: testEpoch
        )
        let second = try f.ws.addRule(
            name: "categorize renamed", conditions: [.payee(.equals, "Cafe Luna")],
            actions: [.setCategory(dining)], nowEpoch: testEpoch
        )
        let third = try f.ws.addRule(
            name: "never reached", conditions: [.payee(.equals, "Cafe Luna")],
            actions: [.setCategory(groceries)], nowEpoch: testEpoch
        )
        let id = try importRow(&f.ws, account: f.checking, id: "r1", day: 5, payee: "SQ *CAFE LUNA", amount: -usd(8))
        #expect(f.ws.transactions[id]?.categoryID == groceries, "without stop, the last matching rule wins")

        var stop = f.ws.automationRules[second]!
        stop.stopAfterMatch = true
        try f.ws.updateRule(stop, nowEpoch: testEpoch)
        let id2 = try importRow(&f.ws, account: f.checking, id: "r2", day: 6, payee: "SQ *CAFE LUNA", amount: -usd(9))
        #expect(f.ws.transactions[id2]?.categoryID == dining)
        _ = first; _ = third

        // Reordering changes the outcome deterministically.
        try f.ws.reorderRules([third, first, second], nowEpoch: testEpoch)
        let id3 = try importRow(&f.ws, account: f.checking, id: "r3", day: 7, payee: "SQ *CAFE LUNA", amount: -usd(9))
        #expect(f.ws.transactions[id3]?.categoryID == dining, "third runs before the rename so it cannot match")
    }

    @Test("Operators, AND/OR, amount, direction, date, and source conditions")
    func conditions() throws {
        let f = try fixture()
        let subject = RuleSubject(
            importedDescription: "AMZN Mktp US*2K4 ", payeeDisplayName: "Amazon", memo: nil,
            accountID: f.checking, amountMilliunits: -usd(45), date: date("2025-01-15"),
            sourceKind: .simplefin, categoryID: nil, isSplit: false
        )
        func rule(_ mode: RuleMatchMode, _ conditions: [RuleCondition]) -> AutomationRule {
            AutomationRule(budgetID: f.ws.budget.id, name: "t", sortOrder: 0, matchMode: mode, conditions: conditions, actions: [.setApproved(true)])
        }
        #expect(RuleEngine.matches(rule(.all, [.importedDescription(.contains, "amzn mktp")]), subject: subject))
        #expect(RuleEngine.matches(rule(.all, [.importedDescription(.startsWith, "AMZN")]), subject: subject))
        #expect(RuleEngine.matches(rule(.all, [.importedDescription(.endsWith, "2k4")]), subject: subject), "whitespace-collapsed")
        #expect(RuleEngine.matches(rule(.all, [.importedDescription(.wildcard, "amzn*us*")]), subject: subject))
        #expect(!RuleEngine.matches(rule(.all, [.importedDescription(.equals, "amzn")]), subject: subject))
        #expect(RuleEngine.matches(rule(.all, [.payee(.equals, "AMAZON"), .amount(.between(usd(40), usd(50)))]), subject: subject))
        #expect(!RuleEngine.matches(rule(.all, [.payee(.equals, "AMAZON"), .amount(.greaterThan(usd(50)))]), subject: subject))
        #expect(RuleEngine.matches(rule(.any, [.payee(.equals, "nope"), .amount(.lessThan(usd(50)))]), subject: subject))
        #expect(RuleEngine.matches(rule(.all, [.direction(.outflow), .source(.imported), .source(.simplefin)]), subject: subject))
        #expect(!RuleEngine.matches(rule(.all, [.direction(.inflow)]), subject: subject))
        #expect(!RuleEngine.matches(rule(.all, [.source(.manual)]), subject: subject))
        #expect(RuleEngine.matches(rule(.all, [.date(.dayOfMonth(from: 10, to: 20))]), subject: subject))
        #expect(RuleEngine.matches(rule(.all, [.date(.weekdays([4]))]), subject: subject), "2025-01-15 is a Wednesday")
        #expect(!RuleEngine.matches(rule(.all, [.date(.weekdays([1, 7]))]), subject: subject))
        #expect(RuleEngine.matches(rule(.all, [.date(.range(from: date("2025-01-01"), to: date("2025-01-31")))]), subject: subject))
        #expect(RuleEngine.matches(rule(.all, [.category(nil)]), subject: subject))
        #expect(!RuleEngine.matches(rule(.all, []), subject: subject), "no conditions never fires")
        #expect(RuleEngine.weekday(of: date("2025-01-05")) == 1, "Sunday")
        #expect(RuleEngine.weekday(of: date("2024-02-29")) == 5, "leap-day Thursday")
    }

    @Test("Incompatible category actions are skipped and reported, never coerced")
    func incompatibleActionsSkipped() throws {
        var f = try fixture()
        let groceries = f.ws.categoryID(named: "Groceries")
        let rule = try f.ws.addRule(
            name: "payroll", conditions: [.importedDescription(.contains, "payroll")],
            actions: [.setCategory(groceries), .setApproved(true)], nowEpoch: testEpoch
        )
        let id = try importRow(&f.ws, account: f.checking, id: "r1", day: 5, payee: "ACME PAYROLL", amount: usd(2000))
        let row = try #require(f.ws.transactions[id])
        #expect(row.categoryID == f.ws.rtaCategoryID, "an inflow keeps the RTA default")
        #expect(row.approved == true, "the compatible action still applied")
        let proposal = try #require(f.ws.evaluateRules(for: id))
        #expect(proposal.skipped.contains(RuleSkip(ruleID: rule, reason: .categoryNotAllowed)))
    }

    @Test("Retroactive preview equals apply; user edits are skipped unless overwriting")
    func retroactive() throws {
        var f = try fixture()
        let groceries = f.ws.categoryID(named: "Groceries")
        let dining = f.ws.categoryID(named: "Dining")
        let a = try importRow(&f.ws, account: f.checking, id: "r1", day: 5, payee: "WHOLEFDS 123", amount: -usd(30))
        let b = try importRow(&f.ws, account: f.checking, id: "r2", day: 6, payee: "WHOLEFDS 456", amount: -usd(20))
        let c = try importRow(&f.ws, account: f.checking, id: "r3", day: 7, payee: "WHOLEFDS 789", amount: -usd(10))
        try f.ws.categorize(transactionID: c, categoryID: dining, nowEpoch: testEpoch) // user decision
        try f.ws.addRule(
            name: "whole foods", conditions: [.importedDescription(.startsWith, "WHOLEFDS")],
            actions: [.setPayee("Whole Foods"), .setCategory(groceries)], nowEpoch: testEpoch
        )
        let preview = f.ws.previewRules(scope: RuleApplicationScope())
        #expect(Set(preview.map(\.transactionID)) == [a, b], "the user-categorized row is excluded by default")
        #expect(preview.allSatisfy { $0.proposal.categoryID == groceries && $0.proposal.payeeName == "Whole Foods" })

        let before = f.ws
        let summary = try f.ws.applyRules(scope: RuleApplicationScope(), nowEpoch: testEpoch)
        #expect(summary.changedRows == 2)
        #expect(f.ws.transactions[a]?.categoryID == groceries)
        #expect(f.ws.transactions[b]?.postingState == .posted)
        #expect(f.ws.transactions[c]?.categoryID == dining)
        #expect(f.ws.budget.revision == before.budget.revision + 1)
        #expect(f.ws.previewRules(scope: RuleApplicationScope()).isEmpty, "idempotent: a second pass proposes nothing")
        #expect(try ConservationCheck.compute(f.ws, month: month("2025-01")).holds)

        let overwrite = f.ws.previewRules(scope: RuleApplicationScope(overwriteUserEdits: true))
        #expect(overwrite.map(\.transactionID) == [c])
        try f.ws.applyRules(scope: RuleApplicationScope(overwriteUserEdits: true), nowEpoch: testEpoch)
        #expect(f.ws.transactions[c]?.categoryID == groceries)
        // A row imported after the rule exists is handled at import, so the
        // retroactive preview has nothing left to propose for it.
        let cardRow = try importRow(&f.ws, account: f.card, id: "r4", day: 8, payee: "WHOLEFDS 999", amount: -usd(5))
        #expect(f.ws.transactions[cardRow]?.categoryID == groceries)
        #expect(f.ws.previewRules(scope: RuleApplicationScope(accountID: f.card)).isEmpty)
        // Scope by account: a new rule only previews rows on that account.
        try f.ws.addRule(name: "flag cards", conditions: [.account(f.card)], actions: [.setFlag(.red)], nowEpoch: testEpoch)
        #expect(f.ws.previewRules(scope: RuleApplicationScope(accountID: f.checking, overwriteUserEdits: true)).isEmpty)
        #expect(f.ws.previewRules(scope: RuleApplicationScope(accountID: f.card, overwriteUserEdits: true)).map(\.transactionID) == [cardRow])
    }

    @Test("Rules never touch reconciled rows, transfer legs, staged rows, or closed months")
    func protectedRowsUntouched() throws {
        var f = try fixture()
        let groceries = f.ws.categoryID(named: "Groceries")
        let dining = f.ws.categoryID(named: "Dining")
        let reconciled = try importRow(&f.ws, account: f.checking, id: "r1", day: 5, payee: "SHOP A", amount: -usd(10))
        try f.ws.categorize(transactionID: reconciled, categoryID: dining, nowEpoch: testEpoch)
        try f.ws.setCleared(transactionID: reconciled, cleared: .cleared, nowEpoch: testEpoch)
        try f.ws.completeReconciliation(accountID: f.checking, statementDate: date("2025-01-31"),
                                        statementBalanceMilliunits: usd(990), nowEpoch: testEpoch)
        let leg = try f.ws.createManualTransferPair(
            sourceAccountID: f.checking, destinationAccountID: f.card, amount: usd(20),
            date: date("2025-01-10"), nowEpoch: testEpoch
        )
        try f.ws.addRule(name: "all shops", conditions: [.importedDescription(.contains, "shop"), ],
                         actions: [.setCategory(groceries)], nowEpoch: testEpoch)
        try f.ws.addRule(name: "all", matchMode: .any, conditions: [.direction(.outflow), .direction(.inflow)],
                         actions: [.setMemo(.replace, "touched")], nowEpoch: testEpoch)
        try f.ws.applyRules(scope: RuleApplicationScope(overwriteUserEdits: true), nowEpoch: testEpoch)
        #expect(f.ws.transactions[reconciled]?.categoryID == dining)
        #expect(f.ws.transactions[reconciled]?.memo == nil)
        for legRow in f.ws.transactions.values where legRow.transferPairID == leg {
            #expect(legRow.memo == nil)
        }
        // Closed month: import lands staged and rules do not run on it.
        try f.ws.advanceObservedMonth(to: month("2025-02"))
        try f.ws.closeMonth(month("2025-01"), nowEpoch: testEpoch)
        let staged = try importRow(&f.ws, account: f.checking, id: "r9", day: 20, payee: "SHOP Z", amount: -usd(3))
        #expect(f.ws.transactions[staged]?.postingState == .staged)
        #expect(f.ws.transactions[staged]?.memo == nil)
    }

    @Test("Percentage splits use largest-remainder rounding and sum exactly")
    func percentageSplit() throws {
        var f = try fixture()
        let groceries = f.ws.categoryID(named: "Groceries")
        let dining = f.ws.categoryID(named: "Dining")
        let transport = f.ws.categoryID(named: "Transport")
        let specs = [
            RuleSplitSpec(categoryID: groceries, share: .basisPoints(3_333)),
            RuleSplitSpec(categoryID: dining, share: .basisPoints(3_333)),
            RuleSplitSpec(categoryID: transport, share: .basisPoints(3_334))
        ]
        let components = try #require(RuleEngine.resolveSplit(specs, totalMagnitude: 100_000))
        #expect(components.map(\.amountMilliunits).reduce(0, +) == -100_000)
        #expect(components.map(\.amountMilliunits) == [-33_330, -33_330, -33_340])
        // 10 units across three thirds: 3/3/4 by largest remainder, exact.
        let tiny = try #require(RuleEngine.resolveSplit(specs, totalMagnitude: 10))
        #expect(tiny.map(\.amountMilliunits) == [-3, -3, -4])
        // Mixed fixed + percent: fixed first, percentages over the remainder.
        let mixed = try #require(RuleEngine.resolveSplit([
            RuleSplitSpec(categoryID: groceries, share: .fixed(25_000)),
            RuleSplitSpec(categoryID: dining, share: .basisPoints(5_000)),
            RuleSplitSpec(categoryID: transport, share: .basisPoints(5_000))
        ], totalMagnitude: 100_000))
        #expect(mixed.map(\.amountMilliunits) == [-25_000, -37_500, -37_500])
        #expect(RuleEngine.resolveSplit([RuleSplitSpec(categoryID: groceries, share: .basisPoints(5_000)),
                                         RuleSplitSpec(categoryID: dining, share: .basisPoints(4_000))], totalMagnitude: 100) == nil)
        #expect(RuleEngine.resolveSplit([RuleSplitSpec(categoryID: groceries, share: .fixed(60)),
                                         RuleSplitSpec(categoryID: dining, share: .fixed(50))], totalMagnitude: 100) == nil)

        // Through the engine on import: the row lands split and posted.
        try f.ws.addRule(name: "costco", conditions: [.importedDescription(.contains, "costco")],
                         actions: [.split(specs)], nowEpoch: testEpoch)
        let id = try importRow(&f.ws, account: f.card, id: "r1", day: 5, payee: "COSTCO WHSE", amount: -usd(90))
        let row = try #require(f.ws.transactions[id])
        #expect(row.splits?.count == 3 && row.categoryID == nil && row.postingState == .posted)
        #expect(row.splits?.map(\.amountMilliunits).reduce(0, +) == -usd(90))
        #expect(try ConservationCheck.compute(f.ws, month: month("2025-01")).holds)
        // A second split rule on an already-split row is skipped, not stacked.
        let proposal = try #require(f.ws.evaluateRules(for: id))
        #expect(proposal.skipped.contains { $0.reason == .rowAlreadySplit })
    }

    @Test("Rule CRUD validates references; persistence round-trips rules")
    func crudAndPersistence() throws {
        var f = try fixture()
        let groceries = f.ws.categoryID(named: "Groceries")
        #expect(throws: MutationError.ruleInvalid) {
            try f.ws.addRule(name: " ", conditions: [.direction(.outflow)], actions: [.setCategory(groceries)], nowEpoch: testEpoch)
        }
        #expect(throws: MutationError.ruleInvalid) {
            try f.ws.addRule(name: "x", conditions: [], actions: [.setCategory(groceries)], nowEpoch: testEpoch)
        }
        #expect(throws: MutationError.ruleInvalid) {
            try f.ws.addRule(name: "x", conditions: [.direction(.outflow)], actions: [.setCategory(f.ws.uncategorizedID)], nowEpoch: testEpoch)
        }
        #expect(throws: MutationError.ruleInvalid) {
            try f.ws.addRule(name: "x", conditions: [.account(AccountID())], actions: [.setCategory(groceries)], nowEpoch: testEpoch)
        }
        let id = try f.ws.addRule(name: "ok", conditions: [.direction(.outflow)], actions: [.setFlag(.blue)], nowEpoch: testEpoch)
        try f.ws.setRuleEnabled(id, enabled: false, nowEpoch: testEpoch)
        #expect(f.ws.automationRules[id]?.enabled == false)
        let rowID = try importRow(&f.ws, account: f.checking, id: "r1", day: 5, payee: "X", amount: -usd(1))
        #expect(f.ws.transactions[rowID]?.flagColor == nil, "disabled rules do not run")

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledgerbar-rules-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LedgerWorkspaceStore(databaseURL: directory.appendingPathComponent("db.sqlite"))
        try store.save(f.ws, nowEpoch: testEpoch)
        let restored = try store.load(budgetID: f.ws.budget.id)
        #expect(restored.snapshot() == f.ws.snapshot())
        #expect(restored.automationRules[id]?.actions == [.setFlag(.blue)])
        let mirrored = try store.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM automation_rules WHERE enabled = 0") ?? 0
        }
        #expect(mirrored == 1)
        try f.ws.deleteRule(id, nowEpoch: testEpoch)
        #expect(f.ws.automationRules.isEmpty)
    }
}

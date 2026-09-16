import Foundation
import GRDB
import Testing
@testable import LedgerCore

@Suite("Split transactions — D3")
struct SplitTransactionTests {

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

    @Test("Cash split debits each component category; register counts the parent once")
    func cashSplit() throws {
        var f = try fixture()
        let groceries = f.ws.categoryID(named: "Groceries")
        let dining = f.ws.categoryID(named: "Dining")
        try f.ws.setBudgeted(categoryID: groceries, month: month("2025-01"), value: usd(100))
        try f.ws.setBudgeted(categoryID: dining, month: month("2025-01"), value: usd(50))
        let id = try f.ws.addManualTransaction(
            accountID: f.checking, date: date("2025-01-05"), payeeName: "Target", categoryID: nil,
            amountMilliunits: -usd(120),
            splits: [
                SplitComponent(categoryID: groceries, amountMilliunits: -usd(70)),
                SplitComponent(categoryID: dining, amountMilliunits: -usd(50))
            ],
            nowEpoch: testEpoch
        )
        let row = try #require(f.ws.transactions[id])
        #expect(row.isSplit && row.categoryID == nil && row.postingState == .posted)
        let snap = try f.ws.snapshot("2025-01")
        #expect(snap.categories[groceries]?.activity == -usd(70))
        #expect(snap.categories[dining]?.activity == -usd(50))
        #expect(snap.categories[groceries]?.available == usd(30))
        #expect(snap.categories[dining]?.available == 0)
        #expect(try f.ws.projection().registerBalances[f.checking] == usd(880))
        #expect(try ConservationCheck.compute(f.ws, month: month("2025-01")).holds)
    }

    @Test("Card split creates one provenance lot per component with funded/credit mix")
    func cardSplitLots() throws {
        var f = try fixture()
        let groceries = f.ws.categoryID(named: "Groceries")
        let dining = f.ws.categoryID(named: "Dining")
        let payment = f.ws.paymentCategoryIDForOnlyCard()
        try f.ws.setBudgeted(categoryID: groceries, month: month("2025-01"), value: usd(50))
        // Dining unfunded → its component is fully credit overspending.
        _ = try f.ws.addManualTransaction(
            accountID: f.card, date: date("2025-01-05"), payeeName: "Costco", categoryID: nil,
            amountMilliunits: -usd(100),
            splits: [
                SplitComponent(categoryID: groceries, amountMilliunits: -usd(60)),
                SplitComponent(categoryID: dining, amountMilliunits: -usd(40))
            ],
            nowEpoch: testEpoch
        )
        let snap = try f.ws.snapshot("2025-01")
        #expect(snap.categories[groceries]?.available == -usd(10))
        #expect(snap.categories[groceries]?.creditDebt == usd(10))
        #expect(snap.categories[dining]?.available == -usd(40))
        #expect(snap.categories[dining]?.creditDebt == usd(40))
        #expect(snap.payments[payment]?.available == usd(50), "only the funded $50 moves to the payment category")
        #expect(snap.creditOverspendingAtEnd == usd(50))
        #expect(try f.ws.projection().projectionBalances[f.card] == -usd(200))
        #expect(try ConservationCheck.compute(f.ws, month: month("2025-01")).holds)
    }

    @Test("Component-addressed card refund targets that component's category and lot")
    func componentRefund() throws {
        var f = try fixture()
        let groceries = f.ws.categoryID(named: "Groceries")
        let dining = f.ws.categoryID(named: "Dining")
        let payment = f.ws.paymentCategoryIDForOnlyCard()
        try f.ws.setBudgeted(categoryID: groceries, month: month("2025-01"), value: usd(100))
        try f.ws.setBudgeted(categoryID: dining, month: month("2025-01"), value: usd(100))
        let purchase = try f.ws.addManualTransaction(
            accountID: f.card, date: date("2025-01-05"), payeeName: "Costco", categoryID: nil,
            amountMilliunits: -usd(100),
            splits: [
                SplitComponent(categoryID: groceries, amountMilliunits: -usd(60)),
                SplitComponent(categoryID: dining, amountMilliunits: -usd(40))
            ],
            nowEpoch: testEpoch
        )
        // Refund of the dining component (index 1), $25.
        let refund = try f.ws.addManualTransaction(
            accountID: f.card, date: date("2025-01-10"), payeeName: "Costco", categoryID: dining,
            amountMilliunits: usd(25), kind: .refund, refundOf: purchase, refundOfComponentIndex: 1,
            nowEpoch: testEpoch
        )
        #expect(f.ws.transactions[refund]?.postingState == .posted)
        let snap = try f.ws.snapshot("2025-01")
        #expect(snap.categories[dining]?.available == usd(85))
        #expect(snap.categories[groceries]?.available == usd(40))
        #expect(snap.payments[payment]?.available == usd(75), "funded lot consumed from the refunded component's card")
        #expect(try ConservationCheck.compute(f.ws, month: month("2025-01")).holds)

        // A refund exceeding the component's refundable lot is rejected.
        #expect(throws: MutationError.refundExceedsRemainingLot) {
            _ = try f.ws.addManualTransaction(
                accountID: f.card, date: date("2025-01-11"), payeeName: "Costco", categoryID: dining,
                amountMilliunits: usd(20), kind: .refund, refundOf: purchase, refundOfComponentIndex: 1,
                nowEpoch: testEpoch
            )
        }
        // Wrong component category or missing index is rejected up front.
        #expect(throws: MutationError.refundOriginInvalid) {
            _ = try f.ws.addManualTransaction(
                accountID: f.card, date: date("2025-01-11"), payeeName: "Costco", categoryID: groceries,
                amountMilliunits: usd(5), kind: .refund, refundOf: purchase, refundOfComponentIndex: 1,
                nowEpoch: testEpoch
            )
        }
        #expect(throws: MutationError.refundOriginInvalid) {
            _ = try f.ws.addManualTransaction(
                accountID: f.card, date: date("2025-01-11"), payeeName: "Costco", categoryID: groceries,
                amountMilliunits: usd(5), kind: .refund, refundOf: purchase, nowEpoch: testEpoch
            )
        }
    }

    @Test("Splitting an origin re-stages an unaddressed refund; categorizing back restores it")
    func splittingOriginRestagesRefund() throws {
        var f = try fixture()
        let groceries = f.ws.categoryID(named: "Groceries")
        let dining = f.ws.categoryID(named: "Dining")
        try f.ws.setBudgeted(categoryID: groceries, month: month("2025-01"), value: usd(100))
        let purchase = try f.ws.addManualTransaction(
            accountID: f.card, date: date("2025-01-05"), payeeName: "Shop", categoryID: groceries,
            amountMilliunits: -usd(80), nowEpoch: testEpoch
        )
        let refund = try f.ws.addManualTransaction(
            accountID: f.card, date: date("2025-01-06"), payeeName: "Shop", categoryID: groceries,
            amountMilliunits: usd(10), kind: .refund, refundOf: purchase, nowEpoch: testEpoch
        )
        try f.ws.setSplits(transactionID: purchase, components: [
            SplitComponent(categoryID: groceries, amountMilliunits: -usd(50)),
            SplitComponent(categoryID: dining, amountMilliunits: -usd(30))
        ], nowEpoch: testEpoch)
        #expect(f.ws.transactions[refund]?.postingState == .staged)
        #expect(f.ws.transactions[refund]?.stageReason == .missingRefundOrigin)
        #expect(try ConservationCheck.compute(f.ws, month: month("2025-01")).holds)
        // Categorizing the origin removes the split and the refund posts again.
        try f.ws.categorize(transactionID: purchase, categoryID: groceries, nowEpoch: testEpoch)
        #expect(f.ws.transactions[purchase]?.splits == nil)
        #expect(f.ws.transactions[refund]?.postingState == .posted)
        #expect(f.ws.transactions[refund]?.categoryID == groceries)
    }

    @Test("Split invariants reject bad components and leave the workspace unchanged")
    func splitGuards() throws {
        var f = try fixture()
        let groceries = f.ws.categoryID(named: "Groceries")
        let dining = f.ws.categoryID(named: "Dining")
        let id = try f.ws.addManualTransaction(
            accountID: f.checking, date: date("2025-01-05"), payeeName: "Target", categoryID: groceries,
            amountMilliunits: -usd(120), nowEpoch: testEpoch
        )
        let before = f.ws
        #expect(throws: MutationError.splitInvalid) {
            try f.ws.setSplits(transactionID: id, components: [
                SplitComponent(categoryID: groceries, amountMilliunits: -usd(70)),
                SplitComponent(categoryID: dining, amountMilliunits: -usd(40))
            ], nowEpoch: testEpoch)
        }
        #expect(throws: MutationError.splitInvalid) {
            try f.ws.setSplits(transactionID: id, components: [
                SplitComponent(categoryID: groceries, amountMilliunits: -usd(130)),
                SplitComponent(categoryID: dining, amountMilliunits: usd(10))
            ], nowEpoch: testEpoch)
        }
        #expect(throws: MutationError.splitInvalid) {
            try f.ws.setSplits(transactionID: id, components: [
                SplitComponent(categoryID: groceries, amountMilliunits: -usd(120))
            ], nowEpoch: testEpoch)
        }
        #expect(throws: MutationError.categoryNotAllowed) {
            try f.ws.setSplits(transactionID: id, components: [
                SplitComponent(categoryID: groceries, amountMilliunits: -usd(70)),
                SplitComponent(categoryID: f.ws.rtaCategoryID, amountMilliunits: -usd(50))
            ], nowEpoch: testEpoch)
        }
        #expect(f.ws == before)
        // Inflows and transfers cannot be split.
        let inflow = try f.ws.addManualTransaction(
            accountID: f.checking, date: date("2025-01-06"), payeeName: "Employer",
            categoryID: f.ws.rtaCategoryID, amountMilliunits: usd(100), nowEpoch: testEpoch
        )
        #expect(throws: MutationError.splitNotAllowed) {
            try f.ws.setSplits(transactionID: inflow, components: [
                SplitComponent(categoryID: groceries, amountMilliunits: usd(50)),
                SplitComponent(categoryID: dining, amountMilliunits: usd(50))
            ], nowEpoch: testEpoch)
        }
        // Amount edits require unsplitting first.
        try f.ws.setSplits(transactionID: id, components: [
            SplitComponent(categoryID: groceries, amountMilliunits: -usd(70)),
            SplitComponent(categoryID: dining, amountMilliunits: -usd(50))
        ], nowEpoch: testEpoch)
        #expect(throws: MutationError.transactionIsSplit) {
            try f.ws.updateAmount(transactionID: id, amountMilliunits: -usd(90), nowEpoch: testEpoch)
        }
    }

    @Test("Partial categorization: an Uncategorized component keeps the row needsCategory")
    func partialCategorization() throws {
        var f = try fixture()
        let groceries = f.ws.categoryID(named: "Groceries")
        let id = try f.ws.importPostedTransaction(
            accountID: f.checking, connectionKey: "c1", remoteAccountID: "a", remoteTransactionID: "r1",
            postedEpoch: try f.ws.calendar.noonEpoch(of: date("2025-01-08")),
            payeeName: "TARGET 00123", amountMilliunits: -usd(90), nowEpoch: testEpoch
        )
        #expect(f.ws.transactions[id]?.importedDescription == "TARGET 00123")
        try f.ws.setSplits(transactionID: id, components: [
            SplitComponent(categoryID: groceries, amountMilliunits: -usd(60)),
            SplitComponent(categoryID: f.ws.uncategorizedID, amountMilliunits: -usd(30))
        ], nowEpoch: testEpoch)
        #expect(f.ws.transactions[id]?.postingState == .needsCategory)
        let snap = try f.ws.snapshot("2025-01")
        #expect(snap.categories[f.ws.uncategorizedID]?.activity == -usd(30))
        #expect(snap.categories[groceries]?.activity == -usd(60))
        try f.ws.setSplits(transactionID: id, components: [
            SplitComponent(categoryID: groceries, amountMilliunits: -usd(60)),
            SplitComponent(categoryID: f.ws.categoryID(named: "Transport"), amountMilliunits: -usd(30))
        ], nowEpoch: testEpoch)
        #expect(f.ws.transactions[id]?.postingState == .posted)
    }

    @Test("Randomized partitions always reconcile to the parent and keep the oracle")
    func randomizedPartitions() throws {
        var f = try fixture()
        let names = ["Groceries", "Dining", "Transport", "Utilities"]
        let ids = names.map { f.ws.categoryID(named: $0) }
        var rng = SplitTestRNG(seed: 0xC0FFEE)
        for step in 0..<40 {
            let total = Milliunits(1_000 + Int(rng.next() % 200_000))
            let parts = 2 + Int(rng.next() % 3)
            var remaining = total
            var components: [SplitComponent] = []
            for i in 0..<parts {
                let amount: Milliunits
                if i == parts - 1 {
                    amount = remaining
                } else {
                    let maxShare = max(1, remaining - Milliunits(parts - i - 1))
                    amount = 1 + Milliunits(rng.next() % UInt64(maxShare))
                }
                remaining -= amount
                components.append(SplitComponent(categoryID: ids[Int(rng.next() % 4)], amountMilliunits: -amount))
            }
            let account = step % 2 == 0 ? f.checking : f.card
            let day = 1 + Int(rng.next() % 28)
            _ = try f.ws.addManualTransaction(
                accountID: account, date: date(String(format: "2025-01-%02d", day)), payeeName: "P\(step)",
                categoryID: nil, amountMilliunits: -total, splits: components, nowEpoch: testEpoch
            )
            #expect(try ConservationCheck.compute(f.ws, month: month("2025-01")).holds)
        }
        // Sum of component activity equals sum of parent amounts.
        let snap = try f.ws.snapshot("2025-01")
        let activity = ids.reduce(Milliunits(0)) { $0 + (snap.categories[$1]?.activity ?? 0) }
        let parents = f.ws.transactions.values.filter { $0.isSplit }.reduce(Milliunits(0)) { $0 + $1.amountMilliunits }
        #expect(activity == parents)
    }

    @Test("A fresh or already-upgraded database gets no pre-upgrade copy")
    func noSpuriousBackup() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledgerbar-nobackup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("db.sqlite")
        _ = try LedgerWorkspaceStore(databaseURL: url)
        _ = try LedgerWorkspaceStore(databaseURL: url)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("db.before-v10.sqlite").path))
    }

    @Test("Splits survive persistence; unsplit fingerprints are unchanged")
    func persistenceAndFingerprint() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledgerbar-split-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LedgerWorkspaceStore(databaseURL: directory.appendingPathComponent("db.sqlite"))
        var f = try fixture()
        let groceries = f.ws.categoryID(named: "Groceries")
        let dining = f.ws.categoryID(named: "Dining")
        let plain = try f.ws.addManualTransaction(
            accountID: f.checking, date: date("2025-01-05"), payeeName: "A", categoryID: groceries,
            amountMilliunits: -usd(10), nowEpoch: testEpoch
        )
        let plainFingerprint = f.ws.transactions[plain]!.accountingFingerprint
        #expect(!plainFingerprint.contains("splits="))
        let split = try f.ws.addManualTransaction(
            accountID: f.checking, date: date("2025-01-06"), payeeName: "B", categoryID: nil,
            amountMilliunits: -usd(30),
            splits: [
                SplitComponent(categoryID: groceries, amountMilliunits: -usd(20), memo: "food"),
                SplitComponent(categoryID: dining, amountMilliunits: -usd(10))
            ],
            nowEpoch: testEpoch
        )
        #expect(f.ws.transactions[split]!.accountingFingerprint.contains("splits="))
        try store.save(f.ws, nowEpoch: testEpoch)
        let restored = try store.load(budgetID: f.ws.budget.id)
        #expect(restored.snapshot() == f.ws.snapshot())
        #expect(restored.transactions[split]?.splits?.count == 2)
        let mirrored = try store.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transaction_splits WHERE transaction_id = ?", arguments: [split.description]) ?? 0
        }
        #expect(mirrored == 2)
    }

    @Test("v10 migration keeps every row, identity, and reconciliation of a v9 database")
    func migrationPreservesData() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledgerbar-migrate-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("db.sqlite")

        // Build a v9-shaped database directly: migrate only through v9, then
        // insert the minimum rows a pre-v10 app would have written.
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        try LedgerDatabaseSchema.migrator.migrate(queue, upTo: "v9-simplefin-link-local-account")
        let budgetID = UUID().uuidString
        let accountID = UUID().uuidString
        let payeeID = UUID().uuidString
        let groupID = UUID().uuidString
        let categoryID = UUID().uuidString
        let transactionID = UUID().uuidString
        try queue.write { db in
            try db.execute(sql: "INSERT INTO budgets(id, name, currency, timezone_identifier, first_month, last_observed_month, next_local_source_sequence, created_at_epoch, revision) VALUES (?, 'B', 'USD', 'UTC', '2025-01', '2025-01', 1, 0, 3)", arguments: [budgetID])
            try db.execute(sql: "INSERT INTO accounts(id, budget_id, name, type, on_budget, closed, currency, history_incomplete, created_at_epoch) VALUES (?, ?, 'Chk', 'checking', 1, 0, 'USD', 0, 0)", arguments: [accountID, budgetID])
            try db.execute(sql: "INSERT INTO category_groups(id, budget_id, name, sort_order, hidden) VALUES (?, ?, 'G', 0, 0)", arguments: [groupID, budgetID])
            try db.execute(sql: "INSERT INTO categories(id, budget_id, group_id, name, sort_order, hidden, kind, linked_account_id, system_kind, note) VALUES (?, ?, ?, 'Groceries', 0, 0, 'spending', NULL, NULL, NULL)", arguments: [categoryID, budgetID, groupID])
            try db.execute(sql: "INSERT INTO payees(id, budget_id, system_kind, namespace, normalized_name, display_name, last_used_category_id, hidden) VALUES (?, ?, NULL, 'user', 'TARGET 123', 'TARGET 123', NULL, 0)", arguments: [payeeID, budgetID])
            try db.execute(sql: "INSERT INTO transactions(id, budget_id, account_id, payee_id, source_kind, date, effective_at_epoch, source_order_key, memo, amount_milliunits, cleared, approved, flag_color, posting_state, stage_reason, stage_metadata, user_edited_at_epoch, category_id, transfer_pair_id, refund_of_transaction_id, kind) VALUES (?, ?, ?, ?, 'simplefin', '2025-01-05', 1736100000, 'remote:2:c13:a12:t1', NULL, -12000, 'reconciled', 1, NULL, 'posted', NULL, NULL, NULL, ?, NULL, NULL, 'normal')", arguments: [transactionID, budgetID, accountID, payeeID, categoryID])
            try db.execute(sql: "INSERT INTO reconciliation_membership(budget_id, transaction_id, reconciliation_id) VALUES (?, ?, 'r')", arguments: [budgetID, transactionID])
        }

        // Opening the store first writes a verified pre-upgrade copy, then runs v10+.
        let store = try LedgerWorkspaceStore(databaseURL: url)
        let backupURL = directory.appendingPathComponent("db.before-v10.sqlite")
        #expect(FileManager.default.fileExists(atPath: backupURL.path), "pre-upgrade copy written next to the database")
        let backupCount = try DatabaseQueue(path: backupURL.path).read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transactions") ?? 0
        }
        #expect(backupCount == 1)
        let backupMigrations = try DatabaseQueue(path: backupURL.path).read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations")
        }
        #expect(!backupMigrations.contains { $0.hasPrefix("v10-") }, "the copy is the pre-upgrade schema")
        let facts = try store.pool.read { db -> (Int, String?, String?, Int, Int) in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transactions") ?? 0
            let row = try Row.fetchOne(db, sql: "SELECT category_id, imported_description, cleared FROM transactions WHERE id = ?", arguments: [transactionID])
            let membership = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM reconciliation_membership WHERE transaction_id = ?", arguments: [transactionID]) ?? 0
            let fkList = try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(transactions)")
            // One composite foreign key spans two columns; count distinct FK ids.
            let selfRefs = Set(fkList.filter { ($0["table"] as String?) == "transactions" }.map { $0["id"] as Int }).count
            return (count, row?["category_id"], row?["imported_description"], membership, selfRefs)
        }
        #expect(facts.0 == 1)
        #expect(facts.1 == categoryID)
        #expect(facts.2 == "TARGET 123", "imported description backfilled from the payee display name")
        #expect(facts.3 == 1)
        #expect(facts.4 == 1, "the self-referential refund foreign key points at the rebuilt table")
        let archived = try store.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT archived FROM budgets WHERE id = ?", arguments: [budgetID])
        }
        #expect(archived == 0)
        // The mirror accepts a 'file' source kind after the rebuild.
        try store.pool.write { db in
            try db.execute(sql: "INSERT INTO transactions(id, budget_id, account_id, payee_id, source_kind, date, effective_at_epoch, source_order_key, memo, amount_milliunits, cleared, approved, flag_color, posting_state, stage_reason, stage_metadata, user_edited_at_epoch, category_id, transfer_pair_id, refund_of_transaction_id, kind) VALUES (?, ?, ?, ?, 'file', '2025-01-06', NULL, 'file:1:b1:r', NULL, -1000, 'uncleared', 0, NULL, 'posted', NULL, NULL, NULL, ?, NULL, NULL, 'normal')", arguments: [UUID().uuidString, budgetID, accountID, payeeID, categoryID])
        }
    }
}

/// Deterministic test PRNG (§6.1).
struct SplitTestRNG {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

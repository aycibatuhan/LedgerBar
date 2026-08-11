import Foundation
import Testing
@testable import LedgerCore

@Suite("Reconciliation — §3.9 completion flow")
struct ReconciliationTests {

    @Test("cash reconciliation: cleared membership, signed adjustment to RTA, rows marked reconciled")
    func cashReconciliation() throws {
        var ws = try makeWorkspace()
        let checking = try ws.addAccount(
            name: "Checking", type: .checking, onBudget: true,
            openingBalance: usd(250), openingDate: date("2025-01-01"), nowEpoch: testEpoch
        )
        let groceries = ws.categoryID(named: "Groceries")
        try ws.setBudgeted(categoryID: groceries, month: month("2025-01"), value: usd(100))
        // Cleared manual spend joins the cleared balance; an uncleared one
        // stays register-only for reconciliation.
        let market = try ws.addManualTransaction(
            accountID: checking, date: date("2025-01-03"), payeeName: "Market",
            categoryID: groceries, amountMilliunits: -usd(25), nowEpoch: testEpoch
        )
        try ws.setCleared(transactionID: market, cleared: .cleared, nowEpoch: testEpoch)
        _ = try ws.addManualTransaction(
            accountID: checking, date: date("2025-01-04"), payeeName: "Cafe",
            categoryID: groceries, amountMilliunits: -usd(5), nowEpoch: testEpoch
        )

        let rtaBefore = try ws.snapshot("2025-01").rtaEnd
        let outcome = try ws.completeReconciliation(
            accountID: checking,
            statementDate: date("2025-01-10"),
            statementBalanceMilliunits: usd(240),
            nowEpoch: testEpoch
        )

        // Opening (cleared by default) + cleared Market row; not the
        // uncleared Cafe row.
        #expect(outcome.clearedBalanceMilliunits == usd(225))
        #expect(outcome.differenceMilliunits == usd(15))
        #expect(outcome.adjustmentTransactionID != nil)
        // Opening + Market + generated adjustment newly reconciled.
        #expect(outcome.newlyReconciledCount == 3)

        let adjustment = ws.transactions[outcome.adjustmentTransactionID!]!
        #expect(adjustment.kind == .adjustment)
        #expect(adjustment.categoryID == ws.rtaCategoryID)
        #expect(adjustment.cleared == .reconciled)
        #expect(adjustment.payeeID == ws.systemPayeeID(.reconciliationAdjustment))

        // Signed positive RTA activity (§3.9 step 4).
        let rtaAfter = try ws.snapshot("2025-01").rtaEnd
        #expect(rtaAfter == rtaBefore + usd(15))

        // Register: 250 - 25 - 5 + 15.
        #expect(try ws.projection().registerBalances[checking] == usd(235))

        // Reconciled rows now require explicit un-reconcile before editing.
        #expect(throws: MutationError.reconciledTransaction) {
            var copy = ws
            try copy.updateAmount(transactionID: market, amountMilliunits: usd(1), nowEpoch: testEpoch)
        }
        // The conservation oracle still holds.
        let check = try ConservationCheck.compute(ws, month: month("2025-01"))
        #expect(check.holds)
    }

    @Test("credit-card reconciliation rejects a positive statement balance")
    func positiveCardStatementRejected() throws {
        var ws = try makeWorkspace()
        let card = try ws.addAccount(
            name: "Card", type: .creditCard, onBudget: true,
            openingBalance: -usd(100), openingDate: date("2025-01-01"), nowEpoch: testEpoch
        )
        let before = ws
        #expect(throws: MutationError.reconciliationInvalid) {
            var copy = ws
            _ = try copy.completeReconciliation(
                accountID: card,
                statementDate: date("2025-01-10"),
                statementBalanceMilliunits: usd(50),
                nowEpoch: testEpoch
            )
        }
        #expect(ws == before)

        // A deeper-debt statement completes as a budget-neutral adjustment.
        let outcome = try ws.completeReconciliation(
            accountID: card,
            statementDate: date("2025-01-10"),
            statementBalanceMilliunits: -usd(150),
            nowEpoch: testEpoch
        )
        #expect(outcome.differenceMilliunits == -usd(50))
        let adjustment = ws.transactions[outcome.adjustmentTransactionID!]!
        #expect(adjustment.categoryID == nil)
        #expect(adjustment.payeeID == ws.systemPayeeID(.cardDebtAdjustment))
        #expect(try ws.projection().registerBalances[card] == -usd(150))
        // Budget-neutral: no RTA/envelope event.
        #expect(try ws.snapshot("2025-01").rtaEnd == 0)
    }

    @Test("closed-month rows keep cleared state and membership but count in the cleared balance")
    func closedMonthMembershipSkipped() throws {
        var ws = try makeWorkspace(firstMonth: "2025-01", currentMonth: "2025-02")
        let checking = try ws.addAccount(
            name: "Checking", type: .checking, onBudget: true,
            openingBalance: usd(100), openingDate: date("2025-01-01"), nowEpoch: testEpoch
        )
        try ws.closeMonth(month("2025-01"), nowEpoch: testEpoch)

        let outcome = try ws.completeReconciliation(
            accountID: checking,
            statementDate: date("2025-02-05"),
            statementBalanceMilliunits: usd(100),
            nowEpoch: testEpoch
        )
        #expect(outcome.clearedBalanceMilliunits == usd(100))
        #expect(outcome.differenceMilliunits == 0)
        #expect(outcome.adjustmentTransactionID == nil)
        // The January opening stays `cleared`; §2.1 blocks membership changes
        // in a closed month.
        #expect(outcome.newlyReconciledCount == 0)
        let opening = ws.transactions.values.first { $0.kind == .openingBalance }!
        #expect(opening.cleared == .cleared)
    }
}

@Suite("Reconciliation undo — §3.9 step 7")
struct ReconciliationUndoTests {

    private func reconciledWorkspace() throws -> (BudgetWorkspace, AccountID, TransactionID) {
        var ws = try makeWorkspace()
        let checking = try ws.addAccount(
            name: "Checking", type: .checking, onBudget: true,
            openingBalance: usd(500), openingDate: date("2025-01-01"), nowEpoch: testEpoch
        )
        let groceries = ws.categoryID(named: "Groceries")
        let spend = try ws.addManualTransaction(
            accountID: checking, date: date("2025-01-03"), payeeName: "Market",
            categoryID: groceries, amountMilliunits: -usd(40), nowEpoch: testEpoch
        )
        try ws.setCleared(transactionID: spend, cleared: .cleared, nowEpoch: testEpoch)
        return (ws, checking, spend)
    }

    @Test("undo restores newly marked rows, deletes the unchanged adjustment, and conserves")
    func undoHappyPath() throws {
        var (ws, checking, spend) = try reconciledWorkspace()
        // Statement 450 vs cleared 460 → adjustment −10 to RTA.
        let outcome = try ws.completeReconciliation(
            accountID: checking, statementDate: date("2025-01-05"),
            statementBalanceMilliunits: usd(450), nowEpoch: testEpoch
        )
        #expect(outcome.differenceMilliunits == -usd(10))
        let adjustmentID = outcome.adjustmentTransactionID!
        let rtaReconciled = try ws.snapshot("2025-01").rtaEnd

        try ws.undoLastReconciliation(accountID: checking, nowEpoch: testEpoch + 60)

        // Rows revert to `cleared`, membership empties, adjustment is gone.
        #expect(ws.transactions[spend]?.cleared == .cleared)
        #expect(ws.transactions[adjustmentID] == nil)
        #expect(ws.reconciliationMembership.isEmpty)
        #expect(ws.latestCompletedReconciliation(accountID: checking) == nil)
        // The −10 RTA adjustment is reversed.
        #expect(try ws.snapshot("2025-01").rtaEnd == rtaReconciled + usd(10))
        #expect(try ws.projection().registerBalances[checking] == usd(460))
        #expect(try ConservationCheck.compute(ws, month: month("2025-01")).holds)
        // History is retained as `undone`, and a second undo is blocked.
        #expect(ws.reconciliations.values.contains { $0.status == .undone })
        #expect(throws: MutationError.reconciliationInvalid) {
            var copy = ws
            try copy.undoLastReconciliation(accountID: checking, nowEpoch: testEpoch + 120)
        }
    }

    @Test("undoing the latest reconciliation preserves earlier reconciliation history")
    func undoPreservesEarlierHistory() throws {
        var (ws, checking, firstSpend) = try reconciledWorkspace()

        // The first reconciliation has no adjustment and reconciles the
        // opening balance plus the original cleared transaction.
        _ = try ws.completeReconciliation(
            accountID: checking, statementDate: date("2025-01-05"),
            statementBalanceMilliunits: usd(460), nowEpoch: testEpoch
        )
        let firstReconciliationID = try #require(ws.reconciliations.values.first?.id)

        // A later cleared transaction belongs only to the second
        // reconciliation.
        let secondSpend = try ws.addManualTransaction(
            accountID: checking, date: date("2025-01-06"), payeeName: "Cafe",
            categoryID: ws.categoryID(named: "Groceries"),
            amountMilliunits: -usd(10), nowEpoch: testEpoch + 10
        )
        try ws.setCleared(transactionID: secondSpend, cleared: .cleared, nowEpoch: testEpoch + 10)
        _ = try ws.completeReconciliation(
            accountID: checking, statementDate: date("2025-01-10"),
            statementBalanceMilliunits: usd(450), nowEpoch: testEpoch + 60
        )

        try ws.undoLastReconciliation(accountID: checking, nowEpoch: testEpoch + 120)

        #expect(ws.reconciliations[firstReconciliationID]?.status == .completed)
        #expect(ws.transactions[firstSpend]?.cleared == .reconciled)
        #expect(ws.transactions[secondSpend]?.cleared == .cleared)
        #expect(ws.reconciliationMembership.contains(firstSpend))
        #expect(!ws.reconciliationMembership.contains(secondSpend))
        #expect(ws.latestCompletedReconciliation(accountID: checking)?.id == firstReconciliationID)
        #expect(ws.reconciliations.values.filter { $0.status == .undone }.count == 1)
    }

    @Test("undo is blocked when a newly marked row's fingerprint changed")
    func undoBlockedByFingerprintMismatch() throws {
        var (ws, checking, spend) = try reconciledWorkspace()
        _ = try ws.completeReconciliation(
            accountID: checking, statementDate: date("2025-01-05"),
            statementBalanceMilliunits: usd(460), nowEpoch: testEpoch
        )
        // Explicit un-reconcile then edit: the stored fingerprint no longer
        // matches the row, so undo must refuse.
        try ws.unreconcileTransaction(spend, nowEpoch: testEpoch + 10)
        try ws.updateAmount(transactionID: spend, amountMilliunits: -usd(45), nowEpoch: testEpoch + 20)
        let before = ws
        #expect(throws: MutationError.reconciliationUndoBlocked) {
            var copy = ws
            try copy.undoLastReconciliation(accountID: checking, nowEpoch: testEpoch + 30)
        }
        #expect(ws == before)
    }

    @Test("un-reconcile is the explicit gate for editing a reconciled row")
    func unreconcileGate() throws {
        var (ws, checking, spend) = try reconciledWorkspace()
        _ = try ws.completeReconciliation(
            accountID: checking, statementDate: date("2025-01-05"),
            statementBalanceMilliunits: usd(460), nowEpoch: testEpoch
        )
        #expect(throws: MutationError.reconciledTransaction) {
            var copy = ws
            try copy.updateAmount(transactionID: spend, amountMilliunits: -usd(45), nowEpoch: testEpoch)
        }
        try ws.unreconcileTransaction(spend, nowEpoch: testEpoch + 10)
        try ws.updateAmount(transactionID: spend, amountMilliunits: -usd(45), nowEpoch: testEpoch + 20)
        #expect(ws.transactions[spend]?.amountMilliunits == -usd(45))
        #expect(try ConservationCheck.compute(ws, month: month("2025-01")).holds)
    }

    @Test("undo history round-trips through SQLite")
    func undoHistoryPersists() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledgerbar-undo-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LedgerWorkspaceStore(databaseURL: directory.appendingPathComponent("db.sqlite"))
        var (ws, checking, _) = try reconciledWorkspace()
        _ = try ws.completeReconciliation(
            accountID: checking, statementDate: date("2025-01-05"),
            statementBalanceMilliunits: usd(450), nowEpoch: testEpoch
        )
        try store.save(ws, nowEpoch: testEpoch)
        var reloaded = try store.load(budgetID: ws.budget.id)
        #expect(reloaded.snapshot() == ws.snapshot())
        try reloaded.undoLastReconciliation(accountID: checking, nowEpoch: testEpoch + 60)
        try store.save(reloaded, nowEpoch: testEpoch + 60)
        let final = try store.load(budgetID: ws.budget.id)
        #expect(final.snapshot() == reloaded.snapshot())
        #expect(final.latestCompletedReconciliation(accountID: checking) == nil)
    }
}

@Suite("SimpleFIN connection state persistence")
struct SimpleFINStateTests {
    private func temporaryStore() throws -> (URL, LedgerWorkspaceStore) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledgerbar-sfstate-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("LedgerBar.sqlite")
        return (url, try LedgerWorkspaceStore(databaseURL: url))
    }

    @Test("connection state round-trips through the mutation service")
    func stateRoundTrip() async throws {
        let (url, store) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let service = BudgetMutationService(store: store)
        _ = try await service.createBudget(
            name: "B", currency: "USD", timeZoneIdentifier: "America/New_York",
            firstMonth: month("2025-01"), currentMonth: month("2025-01"), nowEpoch: testEpoch
        )
        #expect(try await service.simpleFINState() == nil)

        let localAccount = AccountID()
        _ = try await service.updateSimpleFINState(nowEpoch: testEpoch) { state in
            var created = SimpleFINConnectionState(
                status: .active,
                keychainItemID: "item-1",
                baseHost: "bridge.simplefin.org",
                basePort: 443,
                credentialGeneration: 1,
                createdAtEpoch: testEpoch,
                retryNotBeforeEpoch: testEpoch + 100
            )
            created.upsertLink(SimpleFINAccountLink(
                connectionKey: "org-id:demo",
                remoteAccountID: "acct-1",
                localAccountID: localAccount,
                signNormalization: .inverted,
                lastSuccessfulPostedEpoch: testEpoch
            ))
            state = created
        }

        // Cursor advance persists; disconnect keeps the tombstone.
        _ = try await service.updateSimpleFINState(nowEpoch: testEpoch + 10) { state in
            guard var updated = state else { return }
            var link = updated.links[0]
            link.lastSuccessfulPostedEpoch = testEpoch + 5
            updated.upsertLink(link)
            updated.status = .disconnected
            updated.keychainItemID = nil
            state = updated
        }

        let reloaded = try await service.simpleFINState()
        #expect(reloaded?.status == .disconnected)
        #expect(reloaded?.keychainItemID == nil)
        #expect(reloaded?.links.count == 1)
        #expect(reloaded?.links[0].lastSuccessfulPostedEpoch == testEpoch + 5)
        #expect(reloaded?.links[0].signNormalization == .inverted)
        #expect(reloaded?.credentialGeneration == 1)
        #expect(reloaded?.retryNotBeforeEpoch == testEpoch + 100)
        #expect(reloaded?.isSyncDeferred(at: testEpoch + 99) == true)
        #expect(reloaded?.isSyncDeferred(at: testEpoch + 100) == false)

        var cleared = try #require(reloaded)
        cleared.clearExpiredSyncDeferral(at: testEpoch + 100)
        #expect(cleared.retryNotBeforeEpoch == nil)
    }
}

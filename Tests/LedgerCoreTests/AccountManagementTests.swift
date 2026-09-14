import Foundation
import Testing
@testable import LedgerCore

/// Account lifecycle mutations (§2.1, §2.2): signed cash opening balances,
/// rename, and the guarded close. Physical deletion never exists.
@Suite("Account management")
struct AccountManagementTests {

    // MARK: - Opening balances

    @Test("negative on-budget cash opening is a signed RTA inflow (overdraft reduces RTA)")
    func negativeCashOpeningReducesRTA() throws {
        var ws = try makeWorkspace()
        let checking = try ws.addAccount(
            name: "Overdrawn", type: .checking, onBudget: true,
            openingBalance: -usd(300), openingDate: date("2025-01-01"), nowEpoch: testEpoch
        )
        let opening = try #require(ws.transactions.values.first { $0.accountID == checking })
        #expect(opening.kind == .openingBalance)
        #expect(opening.categoryID == ws.rtaCategoryID)
        #expect(opening.postingState == .posted)
        #expect(try ws.projection().registerBalances[checking] == -usd(300))

        let check = try ConservationCheck.compute(ws, month: month("2025-01"))
        #expect(check.cashLikeAssets == -usd(300))
        #expect(check.rta == -usd(300))
        #expect(check.holds, "oracle: -300 == -300")
    }

    @Test("mixed cash openings net into RTA and the oracle holds")
    func mixedCashOpeningsNetIntoRTA() throws {
        var ws = try makeWorkspace()
        _ = try ws.addAccount(
            name: "Checking", type: .checking, onBudget: true,
            openingBalance: usd(1000), openingDate: date("2025-01-01"), nowEpoch: testEpoch
        )
        _ = try ws.addAccount(
            name: "Line of credit", type: .savings, onBudget: true,
            openingBalance: -usd(200), openingDate: date("2025-01-01"), nowEpoch: testEpoch
        )
        let check = try ConservationCheck.compute(ws, month: month("2025-01"))
        #expect(check.cashLikeAssets == usd(800))
        #expect(check.rta == usd(800))
        #expect(check.holds)
    }

    @Test("negative off-budget cash opening stays register-only")
    func negativeOffBudgetOpeningIsRegisterOnly() throws {
        var ws = try makeWorkspace()
        let tracking = try ws.addAccount(
            name: "Tracking", type: .checking, onBudget: false,
            openingBalance: -usd(300), openingDate: date("2025-01-01"), nowEpoch: testEpoch
        )
        let opening = try #require(ws.transactions.values.first { $0.accountID == tracking })
        #expect(opening.categoryID == nil)
        #expect(try ws.projection().registerBalances[tracking] == -usd(300))
        let check = try ConservationCheck.compute(ws, month: month("2025-01"))
        #expect(check.rta == 0)
        #expect(check.holds)
    }

    @Test("positive on-budget card opening is still rejected")
    func positiveCardOpeningRejected() throws {
        var ws = try makeWorkspace()
        let before = ws.snapshot()
        #expect(throws: MutationError.positiveCardOpeningBalance) {
            try ws.addAccount(
                name: "Card", type: .creditCard, onBudget: true,
                openingBalance: usd(50), openingDate: date("2025-01-01"), nowEpoch: testEpoch
            )
        }
        #expect(ws.snapshot() == before)
    }

    // MARK: - Rename

    @Test("renameAccount trims the name and records an audit event")
    func renameTrimsAndAudits() throws {
        var ws = try makeWorkspace()
        let id = try ws.addAccount(
            name: "Checking", type: .checking, onBudget: true,
            openingBalance: usd(10), openingDate: date("2025-01-01"), nowEpoch: testEpoch
        )
        let auditCount = ws.auditEvents.count
        try ws.renameAccount(id, to: "  Main Checking \n", nowEpoch: testEpoch)
        #expect(ws.accounts[id]?.name == "Main Checking")
        #expect(ws.auditEvents.count == auditCount + 1)
        #expect(ws.auditEvents.last?.eventKind == "accountRenamed")
    }

    @Test("renameAccount rejects empty, duplicate, unknown, and closed targets")
    func renameGuards() throws {
        var ws = try makeWorkspace()
        let a = try ws.addAccount(
            name: "Checking", type: .checking, onBudget: true,
            openingBalance: 0, openingDate: date("2025-01-01"), nowEpoch: testEpoch
        )
        let b = try ws.addAccount(
            name: "Savings", type: .savings, onBudget: true,
            openingBalance: 0, openingDate: date("2025-01-01"), nowEpoch: testEpoch
        )
        #expect(throws: MutationError.nameEmpty) { try ws.renameAccount(a, to: "   ", nowEpoch: testEpoch) }
        #expect(throws: MutationError.duplicateName) { try ws.renameAccount(a, to: "savings", nowEpoch: testEpoch) }
        #expect(throws: MutationError.accountNotFound) { try ws.renameAccount(AccountID(), to: "X", nowEpoch: testEpoch) }
        // Same name with different case is allowed for the account itself.
        try ws.renameAccount(a, to: "CHECKING", nowEpoch: testEpoch)
        #expect(ws.accounts[a]?.name == "CHECKING")

        try ws.closeAccount(accountID: b, nowEpoch: testEpoch)
        #expect(throws: MutationError.accountClosed) { try ws.renameAccount(b, to: "Old Savings", nowEpoch: testEpoch) }
        // A closed account's name no longer blocks reuse by an open account.
        try ws.renameAccount(a, to: "Savings", nowEpoch: testEpoch)
        #expect(ws.accounts[a]?.name == "Savings")
    }

    @Test("renaming a credit card renames its payment category atomically")
    func renameCardRenamesPaymentCategory() throws {
        var ws = try makeWorkspace()
        let card = try ws.addAccount(
            name: "Visa", type: .creditCard, onBudget: true,
            openingBalance: -usd(100), openingDate: date("2025-01-01"), nowEpoch: testEpoch
        )
        let payment = try #require(ws.paymentCategoryID(forCard: card))
        #expect(ws.categories[payment]?.name == "Payment: Visa")
        try ws.renameAccount(card, to: "Amex", nowEpoch: testEpoch)
        #expect(ws.categories[payment]?.name == "Payment: Amex")
        #expect(ws.categories[payment]?.linkedAccountID == card)
    }

    // MARK: - Close

    @Test("closeAccount succeeds at zero balance and is rejected with activity")
    func closeGuard() throws {
        var ws = try makeWorkspace()
        let empty = try ws.addAccount(
            name: "Empty", type: .checking, onBudget: true,
            openingBalance: 0, openingDate: date("2025-01-01"), nowEpoch: testEpoch
        )
        let funded = try ws.addAccount(
            name: "Funded", type: .checking, onBudget: true,
            openingBalance: usd(100), openingDate: date("2025-01-01"), nowEpoch: testEpoch
        )
        #expect(throws: MutationError.accountHasActivity) {
            try ws.closeAccount(accountID: funded, nowEpoch: testEpoch)
        }
        try ws.closeAccount(accountID: empty, nowEpoch: testEpoch)
        #expect(ws.accounts[empty]?.closed == true)
        #expect(throws: MutationError.accountClosed) {
            try ws.closeAccount(accountID: empty, nowEpoch: testEpoch)
        }
        let check = try ConservationCheck.compute(ws, month: month("2025-01"))
        #expect(check.rta == usd(100))
        #expect(check.holds)
    }

    // MARK: - Close voiding history (duplicate / mistaken account)

    @Test("closeAccountVoidingHistory voids imported rows, removes local rows, zeroes the register, and closes")
    func closeVoidingHistory() throws {
        var ws = try makeWorkspace()
        let real = try ws.addAccount(
            name: "Checking", type: .checking, onBudget: true,
            openingBalance: usd(500), openingDate: date("2025-01-01"), nowEpoch: testEpoch
        )
        let duplicate = try ws.addAccount(
            name: "Checking (dup)", type: .checking, onBudget: true,
            openingBalance: usd(100), openingDate: date("2025-01-01"), nowEpoch: testEpoch
        )
        let manual = try ws.addManualTransaction(
            accountID: duplicate, date: date("2025-01-03"), payeeName: "Cafe",
            categoryID: ws.categoryID(named: "Dining"), amountMilliunits: -usd(20), nowEpoch: testEpoch
        )
        let imported = try ws.importPostedTransaction(
            accountID: duplicate, connectionKey: "c1", remoteAccountID: "a1", remoteTransactionID: "r1",
            postedEpoch: try ws.calendar.noonEpoch(of: date("2025-01-04")),
            payeeName: "Store", amountMilliunits: -usd(30), nowEpoch: testEpoch
        )
        #expect(ws.transactions[imported]?.postingState == .needsCategory)
        #expect(throws: MutationError.accountHasActivity) {
            try ws.closeAccount(accountID: duplicate, nowEpoch: testEpoch)
        }
        let rowCount = ws.transactions.count

        let summary = try ws.closeAccountVoidingHistory(accountID: duplicate, nowEpoch: testEpoch)
        #expect(summary == AccountCloseSummary(voidedImportedRows: 1, removedLocalRows: 2))
        #expect(ws.accounts[duplicate]?.closed == true)
        #expect(ws.transactions[manual] == nil)
        let voided = try #require(ws.transactions[imported])
        #expect(voided.postingState == .voided)
        #expect(voided.sourceKind == .simplefin)
        #expect(voided.stageReason == nil)
        #expect(ws.transactions.count == rowCount - 2)
        #expect((try ws.projection().registerBalances[duplicate] ?? 0) == 0)
        #expect(ws.auditEvents.last?.eventKind == "accountClosedVoidingHistory")

        // The duplicate's opening no longer funds RTA; the real account is untouched.
        let check = try ConservationCheck.compute(ws, month: month("2025-01"))
        #expect(check.rta == usd(500))
        #expect(check.cashLikeAssets == usd(500))
        #expect(check.holds)
        #expect(try ws.projection().registerBalances[real] == usd(500))

        // The import identity survives: re-importing the same remote row is a no-op.
        let again = try ws.importPostedTransaction(
            accountID: duplicate, connectionKey: "c1", remoteAccountID: "a1", remoteTransactionID: "r1",
            postedEpoch: try ws.calendar.noonEpoch(of: date("2025-01-04")),
            payeeName: "Store", amountMilliunits: -usd(30), nowEpoch: testEpoch
        )
        #expect(again == imported)
        #expect(ws.transactions[imported]?.postingState == .voided)
        #expect(ws.transactions.count == rowCount - 2)
    }

    @Test("closeAccountVoidingHistory is blocked by closed months, transfer pairs, and an already closed account")
    func closeVoidingHistoryGuards() throws {
        var ws = try makeWorkspace(firstMonth: "2025-01", currentMonth: "2025-02")
        let a = try ws.addAccount(
            name: "A", type: .checking, onBudget: true,
            openingBalance: usd(100), openingDate: date("2025-01-01"), nowEpoch: testEpoch
        )
        let b = try ws.addAccount(
            name: "B", type: .checking, onBudget: true,
            openingBalance: usd(100), openingDate: date("2025-02-01"), nowEpoch: testEpoch
        )
        _ = try ws.createManualTransferPair(
            sourceAccountID: a, destinationAccountID: b, amount: usd(10),
            date: date("2025-02-02"), nowEpoch: testEpoch
        )
        let before = ws.snapshot()
        #expect(throws: MutationError.accountHasTransferPairs) {
            try ws.closeAccountVoidingHistory(accountID: b, nowEpoch: testEpoch)
        }
        #expect(ws.snapshot() == before)

        let january = try ws.addAccount(
            name: "January only", type: .cash, onBudget: true,
            openingBalance: usd(5), openingDate: date("2025-01-05"), nowEpoch: testEpoch
        )
        try ws.closeMonth(month("2025-01"), nowEpoch: testEpoch)
        #expect(throws: MutationError.closedMonth) {
            try ws.closeAccountVoidingHistory(accountID: january, nowEpoch: testEpoch)
        }
        try ws.reopenMonth(month("2025-01"), nowEpoch: testEpoch)
        _ = try ws.closeAccountVoidingHistory(accountID: january, nowEpoch: testEpoch)
        #expect(ws.accounts[january]?.closed == true)

        let empty = try ws.addAccount(
            name: "Empty", type: .savings, onBudget: true,
            openingBalance: 0, openingDate: date("2025-02-01"), nowEpoch: testEpoch
        )
        try ws.closeAccount(accountID: empty, nowEpoch: testEpoch)
        #expect(throws: MutationError.accountClosed) {
            try ws.closeAccountVoidingHistory(accountID: empty, nowEpoch: testEpoch)
        }
    }
}

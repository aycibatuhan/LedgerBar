import Foundation
import Testing
@testable import LedgerCore

/// M5.2: the per-account sync engine — §4.2 window filtering and cursor
/// derivation, §4.3 changed/disappeared-row conflicts and pause states, and
/// the §4.4 snapshot comparison over the pair-pulled as-of register balance.
/// All fixtures are synthetic; the budget time zone is UTC so `day(n)` maps to
/// midnight of January n+1, 2025.
@Suite("SimpleFIN sync engine — window, conflicts, discrepancies, pauses")
struct SimpleFINSyncEngineTests {
    private func day(_ n: Int64) -> Int64 { testEpoch + n * 86_400 }

    private func makeFixture(
        currentMonth: String = "2025-01",
        accountType: AccountType = .checking,
        openingBalance: Milliunits = usd(100),
        signNormalization: SimpleFINSignNormalization = .normal,
        cursor: Int64? = nil
    ) throws -> (workspace: BudgetWorkspace, link: SimpleFINAccountLink, accountID: AccountID) {
        var workspace = try makeWorkspace(currentMonth: currentMonth, timeZone: "UTC")
        let accountID = try workspace.addAccount(
            name: "Linked", type: accountType, onBudget: true,
            openingBalance: openingBalance, openingDate: date("2025-01-01"), nowEpoch: testEpoch
        )
        let link = SimpleFINAccountLink(
            connectionKey: "conn:c1", remoteAccountID: "acct-1", localAccountID: accountID,
            signNormalization: signNormalization, lastSuccessfulPostedEpoch: cursor
        )
        return (workspace, link, accountID)
    }

    private func remoteTransaction(
        _ id: String?, amount: String, posted: Int64,
        transacted: Int64? = nil, payee: String? = "Payee",
        description: String? = nil, pending: Bool = false
    ) -> SimpleFINRemoteTransaction {
        SimpleFINRemoteTransaction(
            id: id, amount: amount, postedEpoch: posted,
            transactedAtEpoch: transacted,
            description: description, payee: payee, pending: pending
        )
    }

    private func makeResponse(
        _ transactions: [SimpleFINRemoteTransaction],
        balance: String = "0.00",
        balanceDate: Int64? = nil,
        errors: [String] = [],
        currency: String = "USD"
    ) throws -> SimpleFINAccountsResponse {
        try SimpleFINAccountsResponse(
            accounts: [SimpleFINRemoteAccount(
                id: "acct-1", name: "Remote", currency: currency, balance: balance,
                balanceDateEpoch: balanceDate, connectionID: "c1", transactions: transactions
            )],
            errors: errors
        )
    }

    // MARK: - §4.2 window filtering and cursor derivation

    @Test func windowFilteringAndCursorDerivation() throws {
        var (workspace, link, _) = try makeFixture(cursor: day(10))
        let response = try makeResponse([
            remoteTransaction("t-a", amount: "-1.00", posted: day(4)),
            remoteTransaction("t-b", amount: "-2.00", posted: day(5)),
            remoteTransaction("t-c", amount: "-3.00", posted: day(8)),
            remoteTransaction("t-d", amount: "-4.00", posted: day(12)),
            remoteTransaction("t-e", amount: "-5.00", posted: day(9), pending: true)
        ])
        let outcome = try SimpleFINSyncEngine.applyAccountSync(
            response: response, link: &link,
            window: .recurring(requestStartEpoch: day(5)),
            workspace: &workspace, nowEpoch: day(15)
        )
        // `start < posted <= new_upper_bound`: day(4) and the exact-start
        // day(5) row are ignored; new_upper_bound is the max valid posted.
        #expect(outcome.importedTransactionIDs.count == 2)
        #expect(outcome.ignoredOutOfWindowCount == 2)
        #expect(outcome.skippedPendingCount == 1)
        #expect(outcome.newCursor == day(12))
        #expect(link.lastSuccessfulPostedEpoch == day(12))
        #expect(link.status == .active)
        #expect(outcome.conflictIDs.isEmpty)
        #expect(workspace.simpleFINImportRecord(
            connectionKey: "conn:c1", remoteAccountID: "acct-1", remoteTransactionID: "t-c"
        ) != nil)
        #expect(workspace.simpleFINImportRecord(
            connectionKey: "conn:c1", remoteAccountID: "acct-1", remoteTransactionID: "t-b"
        ) == nil)
    }

    @Test func staleOnlyResponseDoesNotRegressCursorAndEmptyKeepsIt() throws {
        var (workspace, link, _) = try makeFixture(cursor: day(10))
        // Stale-only: the single valid row is below the prior cursor; it still
        // imports (inside the overlap window) but the cursor never regresses.
        let stale = try makeResponse([remoteTransaction("t-x", amount: "-1.00", posted: day(6))])
        let staleOutcome = try SimpleFINSyncEngine.applyAccountSync(
            response: stale, link: &link,
            window: .recurring(requestStartEpoch: day(5)),
            workspace: &workspace, nowEpoch: day(15)
        )
        #expect(staleOutcome.importedTransactionIDs.count == 1)
        #expect(staleOutcome.newCursor == day(10))
        #expect(link.lastSuccessfulPostedEpoch == day(10))

        // Empty successful response: new_upper_bound falls back to the prior
        // cursor, nothing imports, the cursor stays — and the previously
        // imported in-overlap row is now genuinely absent from a successful
        // response covering (start, prior], so it becomes a disappearance
        // conflict rather than a silent void.
        let empty = try makeResponse([])
        let emptyOutcome = try SimpleFINSyncEngine.applyAccountSync(
            response: empty, link: &link,
            window: .recurring(requestStartEpoch: day(5)),
            workspace: &workspace, nowEpoch: day(16)
        )
        #expect(emptyOutcome.importedTransactionIDs.isEmpty)
        #expect(emptyOutcome.newCursor == day(10))
        #expect(link.lastSuccessfulPostedEpoch == day(10))
        #expect(emptyOutcome.conflictIDs.count == 1)
        let conflict = workspace.syncConflicts[emptyOutcome.conflictIDs[0]]
        #expect(conflict?.eventKind == .remoteDisappeared)
        #expect(conflict?.status == .open)
    }

    @Test("description is the imported payee fallback and missing names use system Unknown Payee")
    func importedPayeeFallbackAndUnknownSystemPayee() throws {
        var (workspace, link, _) = try makeFixture(cursor: day(10))
        let response = try makeResponse([
            remoteTransaction(
                "description-only", amount: "-1.00", posted: day(8),
                payee: nil, description: "Legacy Merchant"
            ),
            remoteTransaction(
                "missing-name", amount: "-2.00", posted: day(9),
                payee: nil, description: nil
            )
        ])

        let outcome = try SimpleFINSyncEngine.applyAccountSync(
            response: response, link: &link,
            window: .recurring(requestStartEpoch: day(5)),
            workspace: &workspace, nowEpoch: day(15)
        )

        #expect(outcome.importedTransactionIDs.count == 2)
        let descriptionOnly = try #require(workspace.transactions.values.first {
            workspace.simpleFINImports[$0.id]?.remoteTransactionID == "description-only"
        })
        let missingName = try #require(workspace.transactions.values.first {
            workspace.simpleFINImports[$0.id]?.remoteTransactionID == "missing-name"
        })
        let descriptionOnlyPayeeID = try #require(descriptionOnly.payeeID)
        let missingNamePayeeID = try #require(missingName.payeeID)
        #expect(workspace.payees[descriptionOnlyPayeeID]?.displayName == "Legacy Merchant")
        #expect(workspace.payees[descriptionOnlyPayeeID]?.namespace == .user)
        #expect(workspace.payees[missingNamePayeeID]?.systemKind == .unknown)
        #expect(workspace.payees[missingNamePayeeID]?.namespace == .system)
    }

    @Test("a new import creates a manual duplicate conflict without merging rows")
    func newImportCreatesManualPotentialDuplicateConflict() throws {
        var (workspace, link, accountID) = try makeFixture(cursor: day(5))
        let manualID = try workspace.addManualTransaction(
            accountID: accountID,
            date: date("2025-01-09"),
            payeeName: "Manual Merchant",
            categoryID: workspace.categoryID(named: "Groceries"),
            amountMilliunits: -usd(12),
            nowEpoch: day(8)
        )
        let response = try makeResponse([
            remoteTransaction("remote-duplicate", amount: "-12.00", posted: day(8), payee: "Imported Merchant")
        ])

        let outcome = try SimpleFINSyncEngine.applyAccountSync(
            response: response,
            link: &link,
            window: .recurring(requestStartEpoch: day(5)),
            workspace: &workspace,
            nowEpoch: day(10)
        )

        let importedID = try #require(outcome.importedTransactionIDs.first)
        let importRecord = try #require(workspace.simpleFINImports[importedID])
        #expect(workspace.transactions.count == 3) // opening balance + manual + imported
        #expect(outcome.conflictIDs.count == 1)
        let conflict = try #require(workspace.syncConflicts[outcome.conflictIDs[0]])
        #expect(conflict.eventKind == .manualPotentialDuplicate)
        #expect(conflict.status == .open)
        #expect(conflict.transactionID == manualID)
        #expect(conflict.simpleFINImportID == importRecord.id)
        #expect(conflict.oldMetadata.amountDecimalString == "-12")
        #expect(conflict.oldMetadata.date == "2025-01-09")
        #expect(conflict.newMetadata.amountDecimalString == "-12.00")
        #expect(conflict.newMetadata.date == "2025-01-09")
        #expect(workspace.transactions[manualID]?.sourceKind == .manual)
        #expect(workspace.transactions[importedID]?.sourceKind == .simplefin)
    }

    @Test("a later matching manual row is discovered on the next successful sighting")
    func laterManualRowIsDiscoveredWithoutConflictSpam() throws {
        var (workspace, link, accountID) = try makeFixture(cursor: day(5))
        let response = try makeResponse([
            remoteTransaction("remote-later-manual", amount: "-12.00", posted: day(8))
        ])
        let first = try SimpleFINSyncEngine.applyAccountSync(
            response: response,
            link: &link,
            window: .recurring(requestStartEpoch: day(5)),
            workspace: &workspace,
            nowEpoch: day(10)
        )
        #expect(first.importedTransactionIDs.count == 1)
        #expect(first.conflictIDs.isEmpty)
        let importedID = try #require(first.importedTransactionIDs.first)

        let manualID = try workspace.addManualTransaction(
            accountID: accountID,
            date: date("2025-01-09"),
            payeeName: "Manual Merchant",
            categoryID: workspace.categoryID(named: "Groceries"),
            amountMilliunits: -usd(12),
            nowEpoch: day(11)
        )
        let second = try SimpleFINSyncEngine.applyAccountSync(
            response: response,
            link: &link,
            window: .recurring(requestStartEpoch: day(5)),
            workspace: &workspace,
            nowEpoch: day(12)
        )
        #expect(second.conflictIDs.count == 1)
        let conflict = try #require(workspace.syncConflicts[second.conflictIDs[0]])
        #expect(conflict.eventKind == .manualPotentialDuplicate)
        #expect(conflict.transactionID == manualID)
        #expect(workspace.transactions[importedID]?.sourceKind == .simplefin)

        let repeated = try SimpleFINSyncEngine.applyAccountSync(
            response: response,
            link: &link,
            window: .recurring(requestStartEpoch: day(5)),
            workspace: &workspace,
            nowEpoch: day(13)
        )
        #expect(repeated.conflictIDs.isEmpty)
        #expect(workspace.syncConflicts.values.filter {
            $0.eventKind == .manualPotentialDuplicate && $0.status == .open
        }.count == 1)
    }

    // MARK: - §4.3 step 0 and protocol pauses

    @Test func futureBudgetDatePausesButLaterSameDayEpochImports() throws {
        // A later epoch on the *same budget date* is not a future posted date.
        var (workspace, link, _) = try makeFixture(cursor: day(10))
        let sameDay = try makeResponse([remoteTransaction("t-1", amount: "-1.00", posted: day(10) + 3_600)])
        let sameDayOutcome = try SimpleFINSyncEngine.applyAccountSync(
            response: sameDay, link: &link,
            window: .recurring(requestStartEpoch: day(5)),
            workspace: &workspace, nowEpoch: day(10)
        )
        #expect(sameDayOutcome.pause == nil)
        #expect(sameDayOutcome.importedTransactionIDs.count == 1)

        // A row on tomorrow's budget date pauses the link with no insert and
        // no cursor movement; the workspace is untouched.
        var (workspace2, link2, _) = try makeFixture(cursor: day(10))
        let before = workspace2
        let future = try makeResponse([
            remoteTransaction("t-ok", amount: "-1.00", posted: day(9)),
            remoteTransaction("t-future", amount: "-2.00", posted: day(11))
        ])
        let futureOutcome = try SimpleFINSyncEngine.applyAccountSync(
            response: future, link: &link2,
            window: .recurring(requestStartEpoch: day(5)),
            workspace: &workspace2, nowEpoch: day(10)
        )
        #expect(futureOutcome.pause == .futurePostedEpoch)
        #expect(futureOutcome.importedTransactionIDs.isEmpty)
        #expect(futureOutcome.newCursor == nil)
        #expect(link2.status == .paused)
        #expect(link2.pauseReason == .futurePostedEpoch)
        #expect(link2.lastSuccessfulPostedEpoch == day(10))
        #expect(workspace2 == before)

        // A paused link is a no-op for subsequent passes.
        let pausedOutcome = try SimpleFINSyncEngine.applyAccountSync(
            response: sameDay, link: &link2,
            window: .recurring(requestStartEpoch: day(5)),
            workspace: &workspace2, nowEpoch: day(12)
        )
        #expect(pausedOutcome.pause == .futurePostedEpoch)
        #expect(pausedOutcome.importedTransactionIDs.isEmpty)
        #expect(workspace2 == before)
    }

    @Test func missingRemoteTransactionIDPausesWithoutPartialImport() throws {
        var (workspace, link, _) = try makeFixture(cursor: day(10))
        let before = workspace
        let response = try makeResponse([
            remoteTransaction("t-ok", amount: "-1.00", posted: day(8)),
            remoteTransaction(nil, amount: "-2.00", posted: day(9))
        ])
        let outcome = try SimpleFINSyncEngine.applyAccountSync(
            response: response, link: &link,
            window: .recurring(requestStartEpoch: day(5)),
            workspace: &workspace, nowEpoch: day(15)
        )
        #expect(outcome.pause == .protocolError)
        #expect(outcome.importedTransactionIDs.isEmpty)
        #expect(outcome.newCursor == nil)
        #expect(link.status == .paused)
        #expect(link.pauseReason == .protocolError)
        #expect(workspace == before)
    }

    @Test func duplicateRemoteTransactionIDPausesWithoutPartialImport() throws {
        var (workspace, link, _) = try makeFixture(cursor: day(10))
        let before = workspace
        let response = try makeResponse([
            remoteTransaction("duplicate", amount: "-1.00", posted: day(8)),
            remoteTransaction("duplicate", amount: "-2.00", posted: day(9))
        ])
        let outcome = try SimpleFINSyncEngine.applyAccountSync(
            response: response, link: &link,
            window: .recurring(requestStartEpoch: day(5)),
            workspace: &workspace, nowEpoch: day(15)
        )
        #expect(outcome.pause == .duplicateRemoteIdentity)
        #expect(outcome.importedTransactionIDs.isEmpty)
        #expect(outcome.newCursor == nil)
        #expect(link.status == .paused)
        #expect(link.pauseReason == .duplicateRemoteIdentity)
        #expect(workspace == before)
    }

    @Test func syncRevisionOverflowLeavesLinkUntouched() throws {
        var (workspace, link, _) = try makeFixture(cursor: day(10))
        var snapshot = workspace.snapshot()
        snapshot.budget.revision = Int64.max
        workspace = try BudgetWorkspace(snapshot: snapshot)
        let beforeWorkspace = workspace
        let beforeLink = link
        let response = try makeResponse([
            remoteTransaction("overflow", amount: "-1.00", posted: day(11))
        ])

        #expect(throws: ArithmeticOverflowError.self) {
            try SimpleFINSyncEngine.applyAccountSync(
                response: response, link: &link,
                window: .recurring(requestStartEpoch: day(5)),
                workspace: &workspace, nowEpoch: day(15)
            )
        }
        #expect(workspace == beforeWorkspace)
        #expect(link == beforeLink)
    }

    @Test func currencyChangePausesButBudgetMismatchImportsOffBudget() throws {
        // Remote-vs-local currency change after linking → pause.
        var (workspace, link, _) = try makeFixture(cursor: day(10))
        let before = workspace
        let changed = try makeResponse(
            [remoteTransaction("t-1", amount: "-1.00", posted: day(8))],
            currency: "EUR"
        )
        let changedOutcome = try SimpleFINSyncEngine.applyAccountSync(
            response: changed, link: &link,
            window: .recurring(requestStartEpoch: day(5)),
            workspace: &workspace, nowEpoch: day(15)
        )
        #expect(changedOutcome.pause == .currencyMismatch)
        #expect(link.status == .paused)
        #expect(workspace == before)

        // Budget-vs-account mismatch is §4.3 step 1, not a pause: the account
        // was linked as EUR against a USD budget, rows import register-only.
        var mismatchWorkspace = try makeWorkspace(timeZone: "UTC")
        let euroAccount = try mismatchWorkspace.addAccount(
            name: "Euro", type: .checking, onBudget: true, currency: "EUR",
            openingBalance: 0, openingDate: date("2025-01-01"), nowEpoch: testEpoch
        )
        var euroLink = SimpleFINAccountLink(
            connectionKey: "conn:c1", remoteAccountID: "acct-1",
            localAccountID: euroAccount, lastSuccessfulPostedEpoch: day(10)
        )
        let euroResponse = try makeResponse(
            [remoteTransaction("t-1", amount: "-1.00", posted: day(8))],
            currency: "EUR"
        )
        let euroOutcome = try SimpleFINSyncEngine.applyAccountSync(
            response: euroResponse, link: &euroLink,
            window: .recurring(requestStartEpoch: day(5)),
            workspace: &mismatchWorkspace, nowEpoch: day(15)
        )
        #expect(euroOutcome.pause == nil)
        #expect(euroOutcome.importedTransactionIDs.count == 1)
        let imported = mismatchWorkspace.transactions[euroOutcome.importedTransactionIDs[0]]
        #expect(imported?.categoryID == nil)
        #expect(euroLink.status == .active)
    }

    @Test func defensiveIdentityPauses() throws {
        // The validated response type normally rejects these shapes at
        // construction; the engine still guards against them (defense in
        // depth), so build a valid response and mutate its accounts.
        var (workspace, link, _) = try makeFixture(cursor: day(10))
        let before = workspace

        var missingKey = try makeResponse([])
        missingKey.accounts = [SimpleFINRemoteAccount(
            id: "acct-1", currency: "USD", balance: "0.00",
            organization: SimpleFINRemoteOrganization(name: "Name Only"),
            transactions: []
        )]
        let missingKeyOutcome = try SimpleFINSyncEngine.applyAccountSync(
            response: missingKey, link: &link,
            window: .recurring(requestStartEpoch: day(5)),
            workspace: &workspace, nowEpoch: day(15)
        )
        #expect(missingKeyOutcome.pause == .missingStableConnectionKey)
        #expect(link.status == .paused)
        #expect(workspace == before)

        var (workspace2, link2, _) = try makeFixture(cursor: day(10))
        var duplicate = try makeResponse([])
        let block = SimpleFINRemoteAccount(
            id: "acct-1", currency: "USD", balance: "0.00", connectionID: "c1", transactions: []
        )
        duplicate.accounts = [block, block]
        let duplicateOutcome = try SimpleFINSyncEngine.applyAccountSync(
            response: duplicate, link: &link2,
            window: .recurring(requestStartEpoch: day(5)),
            workspace: &workspace2, nowEpoch: day(15)
        )
        #expect(duplicateOutcome.pause == .duplicateRemoteIdentity)
        #expect(link2.status == .paused)
    }

    // MARK: - §4.3 changed rows

    @Test func changedUntouchedRowUpdatesInPlaceIncludingSignFlip() throws {
        var (workspace, link, accountID) = try makeFixture(cursor: day(10))
        let first = try makeResponse([
            remoteTransaction("t-1", amount: "-12.00", posted: day(6), payee: "CAFE")
        ])
        let firstOutcome = try SimpleFINSyncEngine.applyAccountSync(
            response: first, link: &link,
            window: .recurring(requestStartEpoch: day(5)),
            workspace: &workspace, nowEpoch: day(15)
        )
        let transactionID = firstOutcome.importedTransactionIDs[0]
        #expect(workspace.transactions[transactionID]?.postingState == .needsCategory)
        let originalHash = workspace.simpleFINImports[transactionID]?.remotePayloadHash

        // Amount, date, and payee change on an untouched needsCategory row:
        // silent in-place update, replay re-run, record refreshed, no conflict.
        let changed = try makeResponse([
            remoteTransaction("t-1", amount: "-15.00", posted: day(7), payee: "CAFE EXPANDED")
        ])
        let changedOutcome = try SimpleFINSyncEngine.applyAccountSync(
            response: changed, link: &link,
            window: .recurring(requestStartEpoch: day(5)),
            workspace: &workspace, nowEpoch: day(16)
        )
        #expect(changedOutcome.updatedInPlaceTransactionIDs == [transactionID])
        #expect(changedOutcome.conflictIDs.isEmpty)
        let updated = workspace.transactions[transactionID]
        #expect(updated?.amountMilliunits == usd(-15))
        #expect(updated?.date == date("2025-01-08"))
        #expect(updated?.effectiveAtEpoch == day(7))
        #expect(updated?.postingState == .needsCategory)
        let record = workspace.simpleFINImports[transactionID]
        #expect(record?.remoteAmountDecimalString == "-15.00")
        #expect(record?.remotePostedEpoch == day(7))
        #expect(record?.remotePayloadHash != originalHash)

        // Sign flip re-runs the §4.3 step 5/6 classification: the positive
        // amount defaults to RTA and posts.
        let flipped = try makeResponse([
            remoteTransaction("t-1", amount: "5.00", posted: day(7), payee: "CAFE EXPANDED")
        ])
        let flippedOutcome = try SimpleFINSyncEngine.applyAccountSync(
            response: flipped, link: &link,
            window: .recurring(requestStartEpoch: day(5)),
            workspace: &workspace, nowEpoch: day(17)
        )
        #expect(flippedOutcome.updatedInPlaceTransactionIDs == [transactionID])
        let posted = workspace.transactions[transactionID]
        #expect(posted?.amountMilliunits == usd(5))
        #expect(posted?.categoryID == workspace.rtaCategoryID)
        #expect(posted?.postingState == .posted)
        #expect(posted?.approved == false)
        _ = accountID
    }

    @Test func changedTouchedRowBecomesConflictAndDedupes() throws {
        var (workspace, link, _) = try makeFixture(cursor: day(10))
        let first = try makeResponse([
            remoteTransaction("t-1", amount: "-12.00", posted: day(6), payee: "CAFE")
        ])
        let firstOutcome = try SimpleFINSyncEngine.applyAccountSync(
            response: first, link: &link,
            window: .recurring(requestStartEpoch: day(5)),
            workspace: &workspace, nowEpoch: day(15)
        )
        let transactionID = firstOutcome.importedTransactionIDs[0]

        // The user categorizes the row; it is now user-owned.
        let groceries = workspace.categoryID(named: "Groceries")
        try workspace.categorize(transactionID: transactionID, categoryID: groceries, nowEpoch: day(15))
        let ownedRow = workspace.transactions[transactionID]

        let changed = try makeResponse([
            remoteTransaction(
                "t-1", amount: "-99.00", posted: day(6),
                transacted: day(5), payee: "CAFE"
            )
        ])
        let changedOutcome = try SimpleFINSyncEngine.applyAccountSync(
            response: changed, link: &link,
            window: .recurring(requestStartEpoch: day(5)),
            workspace: &workspace, nowEpoch: day(16)
        )
        #expect(changedOutcome.updatedInPlaceTransactionIDs.isEmpty)
        #expect(changedOutcome.conflictIDs.count == 1)
        // Local row retains every user-owned value.
        #expect(workspace.transactions[transactionID] == ownedRow)
        let conflict = workspace.syncConflicts[changedOutcome.conflictIDs[0]]
        #expect(conflict?.eventKind == .remoteChanged)
        #expect(conflict?.status == .open)
        #expect(conflict?.oldMetadata.amountDecimalString == "-12.00")
        #expect(conflict?.newMetadata.amountDecimalString == "-99.00")
        #expect(conflict?.oldMetadata.transactedEpoch == nil)
        #expect(conflict?.newMetadata.transactedEpoch == day(5))
        // The stored baseline hash stays as-imported until the user resolves.
        #expect(workspace.simpleFINImports[transactionID]?.remotePayloadHash == conflict?.oldMetadata.payloadHash)

        // The identical response again: no duplicate conflict.
        let repeated = try SimpleFINSyncEngine.applyAccountSync(
            response: changed, link: &link,
            window: .recurring(requestStartEpoch: day(5)),
            workspace: &workspace, nowEpoch: day(17)
        )
        #expect(repeated.conflictIDs.isEmpty)
        #expect(workspace.syncConflicts.count == 1)

        // A different change is a new open conflict (new payload hash).
        let changedAgain = try makeResponse([
            remoteTransaction("t-1", amount: "-77.00", posted: day(6), payee: "CAFE")
        ])
        let secondOutcome = try SimpleFINSyncEngine.applyAccountSync(
            response: changedAgain, link: &link,
            window: .recurring(requestStartEpoch: day(5)),
            workspace: &workspace, nowEpoch: day(18)
        )
        #expect(secondOutcome.conflictIDs.count == 1)
        #expect(workspace.syncConflicts.count == 2)
        #expect(workspace.syncConflicts[changedOutcome.conflictIDs[0]]?.status == .dismissed)
        #expect(workspace.syncConflicts[changedOutcome.conflictIDs[0]]?.resolvedAtEpoch == day(18))
        #expect(workspace.syncConflicts[secondOutcome.conflictIDs[0]]?.status == .open)
    }

    @Test func resolvedRemoteChangeBaselineDoesNotReopenIdenticalPayload() throws {
        var (workspace, link, _) = try makeFixture(cursor: day(10))
        let original = try makeResponse([
            remoteTransaction("t-1", amount: "-12.00", posted: day(6), payee: "CAFE")
        ])
        let imported = try SimpleFINSyncEngine.applyAccountSync(
            response: original, link: &link,
            window: .recurring(requestStartEpoch: day(5)),
            workspace: &workspace, nowEpoch: day(15)
        )
        let transactionID = try #require(imported.importedTransactionIDs.first)
        try workspace.categorize(
            transactionID: transactionID,
            categoryID: workspace.categoryID(named: "Groceries"),
            nowEpoch: day(15)
        )
        let localBefore = workspace.transactions[transactionID]
        let changed = try makeResponse([
            remoteTransaction(
                "t-1", amount: "-13.00", posted: day(7),
                transacted: day(6), payee: "CAFE UPDATED"
            )
        ])
        let firstChanged = try SimpleFINSyncEngine.applyAccountSync(
            response: changed, link: &link,
            window: .recurring(requestStartEpoch: day(5)),
            workspace: &workspace, nowEpoch: day(16)
        )
        let conflictID = try #require(firstChanged.conflictIDs.first)

        _ = try workspace.resolveSyncConflict(
            SyncConflictResolutionCommand(
                budgetID: workspace.budget.id,
                conflictID: conflictID,
                expectedBudgetRevision: workspace.budget.revision,
                choice: .remoteChanged(.keepLocal)
            ),
            simpleFINState: nil,
            nowEpoch: day(17)
        )
        #expect(workspace.transactions[transactionID] == localBefore)
        #expect(workspace.syncConflicts[conflictID]?.status == .resolved)
        #expect(
            workspace.simpleFINImports[transactionID]?.remotePayloadHash
                == workspace.syncConflicts[conflictID]?.newMetadata.payloadHash
        )

        let repeated = try SimpleFINSyncEngine.applyAccountSync(
            response: changed, link: &link,
            window: .recurring(requestStartEpoch: day(5)),
            workspace: &workspace, nowEpoch: day(18)
        )
        #expect(repeated.conflictIDs.isEmpty)
        #expect(repeated.updatedInPlaceTransactionIDs.isEmpty)
        #expect(workspace.syncConflicts.count == 1)
        #expect(workspace.syncConflicts[conflictID]?.status == .resolved)
        #expect(workspace.transactions[transactionID] == localBefore)
    }

    @Test func changedRowInClosedMonthBecomesConflict() throws {
        var (workspace, link, _) = try makeFixture(currentMonth: "2025-02", cursor: day(10))
        let first = try makeResponse([
            remoteTransaction("t-1", amount: "-12.00", posted: day(6), payee: "CAFE")
        ])
        let firstOutcome = try SimpleFINSyncEngine.applyAccountSync(
            response: first, link: &link,
            window: .recurring(requestStartEpoch: day(5)),
            workspace: &workspace, nowEpoch: day(15)
        )
        let transactionID = firstOutcome.importedTransactionIDs[0]
        #expect(workspace.transactions[transactionID]?.postingState == .needsCategory)
        try workspace.closeMonth(month("2025-01"), nowEpoch: day(35))

        // Even an untouched needsCategory row is not silently rewritten once
        // its month is closed.
        let changed = try makeResponse([
            remoteTransaction("t-1", amount: "-15.00", posted: day(6), payee: "CAFE")
        ])
        let outcome = try SimpleFINSyncEngine.applyAccountSync(
            response: changed, link: &link,
            window: .recurring(requestStartEpoch: day(5)),
            workspace: &workspace, nowEpoch: day(36)
        )
        #expect(outcome.updatedInPlaceTransactionIDs.isEmpty)
        #expect(outcome.conflictIDs.count == 1)
        #expect(workspace.transactions[transactionID]?.amountMilliunits == usd(-12))

        // Reopening restores ordinary mutation eligibility. Accepting the
        // same provider payload in place must also dismiss the now-obsolete
        // conflict, even though its incoming hash matches this sighting.
        let conflictID = try #require(outcome.conflictIDs.first)
        try workspace.reopenMonth(month("2025-01"), nowEpoch: day(37))
        let acceptedAfterReopen = try SimpleFINSyncEngine.applyAccountSync(
            response: changed, link: &link,
            window: .recurring(requestStartEpoch: day(5)),
            workspace: &workspace, nowEpoch: day(38)
        )
        #expect(acceptedAfterReopen.updatedInPlaceTransactionIDs == [transactionID])
        #expect(acceptedAfterReopen.conflictIDs.isEmpty)
        #expect(workspace.transactions[transactionID]?.amountMilliunits == usd(-15))
        #expect(workspace.syncConflicts[conflictID]?.status == .dismissed)
        #expect(workspace.syncConflicts[conflictID]?.resolvedAtEpoch == day(38))
    }

    // MARK: - §4.3 disappeared rows

    @Test func disappearedRowDetectionWindowErrorsAndDedup() throws {
        var (workspace, link, _) = try makeFixture(cursor: day(10))
        let both = try makeResponse([
            remoteTransaction("t-1", amount: "-1.00", posted: day(6)),
            remoteTransaction("t-2", amount: "-2.00", posted: day(8))
        ])
        let seeded = try SimpleFINSyncEngine.applyAccountSync(
            response: both, link: &link,
            window: .recurring(requestStartEpoch: day(5)),
            workspace: &workspace, nowEpoch: day(15)
        )
        #expect(seeded.importedTransactionIDs.count == 2)
        let firstID = seeded.importedTransactionIDs[0]

        // A provider-error response is partial: absence is NOT disappearance.
        let flaky = try makeResponse(
            [remoteTransaction("t-2", amount: "-2.00", posted: day(8))],
            errors: ["ERROR: institution balances may be incomplete"]
        )
        let flakyOutcome = try SimpleFINSyncEngine.applyAccountSync(
            response: flaky, link: &link,
            window: .recurring(requestStartEpoch: day(5)),
            workspace: &workspace, nowEpoch: day(16)
        )
        #expect(flakyOutcome.conflictIDs.isEmpty)
        #expect(workspace.syncConflicts.isEmpty)

        // A successful response missing t-1 inside (start, new_upper_bound]
        // creates one open remoteDisappeared conflict; the local row is
        // retained, never auto-voided.
        let missing = try makeResponse([remoteTransaction("t-2", amount: "-2.00", posted: day(8))])
        let missingOutcome = try SimpleFINSyncEngine.applyAccountSync(
            response: missing, link: &link,
            window: .recurring(requestStartEpoch: day(5)),
            workspace: &workspace, nowEpoch: day(17)
        )
        #expect(missingOutcome.conflictIDs.count == 1)
        let conflict = workspace.syncConflicts[missingOutcome.conflictIDs[0]]
        #expect(conflict?.eventKind == .remoteDisappeared)
        #expect(conflict?.transactionID == firstID)
        #expect(workspace.transactions[firstID]?.postingState == .needsCategory)

        // Re-applying the same response never duplicates the open conflict.
        let repeated = try SimpleFINSyncEngine.applyAccountSync(
            response: missing, link: &link,
            window: .recurring(requestStartEpoch: day(5)),
            workspace: &workspace, nowEpoch: day(18)
        )
        #expect(repeated.conflictIDs.isEmpty)
        #expect(workspace.syncConflicts.count == 1)

        // Absence outside the requested overlap is not disappearance: with the
        // window starting after t-1's posted epoch, no new conflict appears
        // even though t-1 is still absent.
        var (workspace2, link2, _) = try makeFixture(cursor: day(10))
        _ = try SimpleFINSyncEngine.applyAccountSync(
            response: both, link: &link2,
            window: .recurring(requestStartEpoch: day(5)),
            workspace: &workspace2, nowEpoch: day(15)
        )
        let narrow = try SimpleFINSyncEngine.applyAccountSync(
            response: missing, link: &link2,
            window: .recurring(requestStartEpoch: day(7)),
            workspace: &workspace2, nowEpoch: day(16)
        )
        #expect(narrow.conflictIDs.isEmpty)
        #expect(workspace2.syncConflicts.isEmpty)

        // A voided local row is settled; its absence is not re-reported.
        var (workspace3, link3, _) = try makeFixture(cursor: day(10))
        let seeded3 = try SimpleFINSyncEngine.applyAccountSync(
            response: both, link: &link3,
            window: .recurring(requestStartEpoch: day(5)),
            workspace: &workspace3, nowEpoch: day(15)
        )
        try workspace3.deleteTransaction(seeded3.importedTransactionIDs[0], nowEpoch: day(15))
        #expect(workspace3.transactions[seeded3.importedTransactionIDs[0]]?.postingState == .voided)
        let afterVoid = try SimpleFINSyncEngine.applyAccountSync(
            response: missing, link: &link3,
            window: .recurring(requestStartEpoch: day(5)),
            workspace: &workspace3, nowEpoch: day(16)
        )
        #expect(afterVoid.conflictIDs.isEmpty)
    }

    @Test func acknowledgedDisappearanceRequiresReappearanceBeforeNewConflict() throws {
        var (workspace, link, _) = try makeFixture(cursor: day(10))
        let both = try makeResponse([
            remoteTransaction("t-1", amount: "-1.00", posted: day(6)),
            remoteTransaction("t-2", amount: "-2.00", posted: day(8))
        ])
        _ = try SimpleFINSyncEngine.applyAccountSync(
            response: both, link: &link,
            window: .recurring(requestStartEpoch: day(5)),
            workspace: &workspace, nowEpoch: day(15)
        )
        let missing = try makeResponse([
            remoteTransaction("t-2", amount: "-2.00", posted: day(8))
        ])
        let firstMissing = try SimpleFINSyncEngine.applyAccountSync(
            response: missing, link: &link,
            window: .recurring(requestStartEpoch: day(5)),
            workspace: &workspace, nowEpoch: day(16)
        )
        let firstConflictID = try #require(firstMissing.conflictIDs.first)
        _ = try workspace.resolveSyncConflict(
            SyncConflictResolutionCommand(
                budgetID: workspace.budget.id,
                conflictID: firstConflictID,
                expectedBudgetRevision: workspace.budget.revision,
                choice: .remoteDisappeared(.keepLocal)
            ),
            simpleFINState: nil,
            nowEpoch: day(17)
        )
        let transactionID = try #require(workspace.syncConflicts[firstConflictID]?.transactionID)
        #expect(workspace.simpleFINImports[transactionID]?.remoteDisappearanceAcknowledged == true)

        let stillMissing = try SimpleFINSyncEngine.applyAccountSync(
            response: missing, link: &link,
            window: .recurring(requestStartEpoch: day(5)),
            workspace: &workspace, nowEpoch: day(18)
        )
        #expect(stillMissing.conflictIDs.isEmpty)
        #expect(workspace.syncConflicts.count == 1)

        _ = try SimpleFINSyncEngine.applyAccountSync(
            response: both, link: &link,
            window: .recurring(requestStartEpoch: day(5)),
            workspace: &workspace, nowEpoch: day(19)
        )
        #expect(workspace.simpleFINImports[transactionID]?.remoteDisappearanceAcknowledged == false)

        let missingAgain = try SimpleFINSyncEngine.applyAccountSync(
            response: missing, link: &link,
            window: .recurring(requestStartEpoch: day(5)),
            workspace: &workspace, nowEpoch: day(20)
        )
        #expect(missingAgain.conflictIDs.count == 1)
        #expect(workspace.syncConflicts.count == 2)
        #expect(workspace.syncConflicts[firstConflictID]?.status == .resolved)
        #expect(workspace.syncConflicts[missingAgain.conflictIDs[0]]?.status == .open)
    }

    @Test func newestDisappearanceUsesPriorCursorCoverageBound() throws {
        var (workspace, link, _) = try makeFixture(cursor: day(10))
        let seeded = try SimpleFINSyncEngine.applyAccountSync(
            response: try makeResponse([
                remoteTransaction("t-1", amount: "-1.00", posted: day(6)),
                remoteTransaction("t-2", amount: "-2.00", posted: day(8))
            ]),
            link: &link,
            window: .recurring(requestStartEpoch: day(5)),
            workspace: &workspace,
            nowEpoch: day(15)
        )
        let remaining = try makeResponse([
            remoteTransaction("t-1", amount: "-1.00", posted: day(6))
        ])

        let outcome = try SimpleFINSyncEngine.applyAccountSync(
            response: remaining,
            link: &link,
            window: .recurring(requestStartEpoch: day(5)),
            workspace: &workspace,
            nowEpoch: day(16)
        )

        let conflictID = try #require(outcome.conflictIDs.first)
        #expect(workspace.syncConflicts[conflictID]?.eventKind == .remoteDisappeared)
        #expect(workspace.syncConflicts[conflictID]?.transactionID == seeded.importedTransactionIDs[1])
    }

    // MARK: - §4.4 snapshot comparison

    @Test func snapshotComparisonCreatesRefreshesAndNeverResolves() throws {
        var (workspace, link, accountID) = try makeFixture(cursor: day(10))
        let spend = try makeResponse(
            [remoteTransaction("t-1", amount: "-10.00", posted: day(6))],
            balance: "90.00", balanceDate: day(7)
        )
        let matched = try SimpleFINSyncEngine.applyAccountSync(
            response: spend, link: &link,
            window: .recurring(requestStartEpoch: day(5)),
            workspace: &workspace, nowEpoch: day(15)
        )
        // Opening 100 - 10 = 90 == snapshot: no discrepancy.
        #expect(matched.discrepancyID == nil)
        #expect(workspace.snapshotDiscrepancies.isEmpty)

        // A mismatched snapshot opens exactly one discrepancy…
        let low = try makeResponse([], balance: "85.00", balanceDate: day(8))
        let lowOutcome = try SimpleFINSyncEngine.applyAccountSync(
            response: low, link: &link,
            window: .recurring(requestStartEpoch: day(5)),
            workspace: &workspace, nowEpoch: day(16)
        )
        let discrepancyID = try #require(lowOutcome.discrepancyID)
        #expect(lowOutcome.pause == .snapshotDiscrepancy)
        #expect(link.status == .paused)
        #expect(link.pauseReason == .snapshotDiscrepancy)
        let opened = try #require(workspace.snapshotDiscrepancies[discrepancyID])
        #expect(opened.remoteBalanceMilliunits == usd(85))
        #expect(opened.localRegisterMilliunits == usd(90))
        #expect(opened.differenceMilliunits == usd(-5))
        #expect(opened.simpleFINLinkIdentity == link.identity)
        #expect(opened.status == .open)

        // …a later still-mismatched snapshot refreshes that same record…
        link.resume()
        let lower = try makeResponse([], balance: "84.00", balanceDate: day(9))
        let lowerOutcome = try SimpleFINSyncEngine.applyAccountSync(
            response: lower, link: &link,
            window: .recurring(requestStartEpoch: day(5)),
            workspace: &workspace, nowEpoch: day(17)
        )
        #expect(lowerOutcome.discrepancyID == discrepancyID)
        #expect(workspace.snapshotDiscrepancies.count == 1)
        #expect(workspace.snapshotDiscrepancies[discrepancyID]?.differenceMilliunits == usd(-6))
        #expect(workspace.snapshotDiscrepancies[discrepancyID]?.observedEpoch == day(9))

        // …and a matching snapshot leaves the open record untouched: the sync
        // engine never guesses a resolution.
        let match = try makeResponse([], balance: "90.00", balanceDate: day(10))
        let matchOutcome = try SimpleFINSyncEngine.applyAccountSync(
            response: match, link: &link,
            window: .recurring(requestStartEpoch: day(5)),
            workspace: &workspace, nowEpoch: day(18)
        )
        #expect(matchOutcome.discrepancyID == nil)
        let untouched = try #require(workspace.snapshotDiscrepancies[discrepancyID])
        #expect(untouched.status == .open)
        #expect(untouched.differenceMilliunits == usd(-6))
        #expect(untouched.observedEpoch == day(9))

        // The as-of cutoff: a balance dated before the imported row excludes
        // it, so the comparison uses only the opening balance.
        var (cutoffWorkspace, cutoffLink, _) = try makeFixture(cursor: day(10))
        _ = accountID
        let seeded = try makeResponse([remoteTransaction("t-1", amount: "-10.00", posted: day(6))])
        _ = try SimpleFINSyncEngine.applyAccountSync(
            response: seeded, link: &cutoffLink,
            window: .recurring(requestStartEpoch: day(5)),
            workspace: &cutoffWorkspace, nowEpoch: day(15)
        )
        let earlySnapshot = try makeResponse(
            [remoteTransaction("t-1", amount: "-10.00", posted: day(6))],
            balance: "100.00", balanceDate: day(4)
        )
        let earlyOutcome = try SimpleFINSyncEngine.applyAccountSync(
            response: earlySnapshot, link: &cutoffLink,
            window: .recurring(requestStartEpoch: day(5)),
            workspace: &cutoffWorkspace, nowEpoch: day(16)
        )
        #expect(earlyOutcome.discrepancyID == nil)
        #expect(cutoffWorkspace.snapshotDiscrepancies.isEmpty)
    }

    @Test func invertedProviderSnapshotIsSignNormalized() throws {
        // Card with -50 pre-existing debt; the inverted provider reports the
        // debt as a positive "50.00". Normalization must flip it before
        // comparing, so this is a match — the audit bug regression.
        var (workspace, link, _) = try makeFixture(
            accountType: .creditCard, openingBalance: usd(-50),
            signNormalization: .inverted, cursor: day(10)
        )
        let match = try makeResponse([], balance: "50.00", balanceDate: day(3))
        let matchOutcome = try SimpleFINSyncEngine.applyAccountSync(
            response: match, link: &link,
            window: .recurring(requestStartEpoch: day(5)),
            workspace: &workspace, nowEpoch: day(15)
        )
        #expect(matchOutcome.discrepancyID == nil)
        #expect(workspace.snapshotDiscrepancies.isEmpty)

        let mismatch = try makeResponse([], balance: "55.00", balanceDate: day(4))
        let mismatchOutcome = try SimpleFINSyncEngine.applyAccountSync(
            response: mismatch, link: &link,
            window: .recurring(requestStartEpoch: day(5)),
            workspace: &workspace, nowEpoch: day(16)
        )
        let discrepancyID = try #require(mismatchOutcome.discrepancyID)
        #expect(workspace.snapshotDiscrepancies[discrepancyID]?.remoteBalanceMilliunits == usd(-55))
        #expect(workspace.snapshotDiscrepancies[discrepancyID]?.differenceMilliunits == usd(-5))
    }

    // MARK: - registerBalanceAsOf

    @Test func registerBalanceAsOfCutoffStatesAndNoon() throws {
        var (workspace, link, accountID) = try makeFixture(cursor: day(10))
        // Manual row dated 2025-01-06 uses budget-timezone date-noon.
        let groceries = workspace.categoryID(named: "Groceries")
        _ = try workspace.addManualTransaction(
            accountID: accountID, date: date("2025-01-06"), payeeName: "Market",
            categoryID: groceries, amountMilliunits: usd(-20), nowEpoch: day(15)
        )
        let noonJan6 = day(5) + 43_200
        #expect(try workspace.registerBalanceAsOf(accountID: accountID, epoch: noonJan6 - 1) == usd(100))
        #expect(try workspace.registerBalanceAsOf(accountID: accountID, epoch: noonJan6) == usd(80))

        // An imported row uses effective_at_epoch exactly.
        let imported = try makeResponse([remoteTransaction("t-1", amount: "-10.00", posted: day(8))])
        let outcome = try SimpleFINSyncEngine.applyAccountSync(
            response: imported, link: &link,
            window: .recurring(requestStartEpoch: day(5)),
            workspace: &workspace, nowEpoch: day(15)
        )
        #expect(try workspace.registerBalanceAsOf(accountID: accountID, epoch: day(8) - 1) == usd(80))
        #expect(try workspace.registerBalanceAsOf(accountID: accountID, epoch: day(8)) == usd(70))

        // A voided row is excluded everywhere.
        try workspace.deleteTransaction(outcome.importedTransactionIDs[0], nowEpoch: day(16))
        #expect(try workspace.registerBalanceAsOf(accountID: accountID, epoch: day(9)) == usd(80))

        // A staged card row is included in the register balance even though it
        // is excluded from the envelope projection.
        var (cardWorkspace, cardLink, cardAccountID) = try makeFixture(
            accountType: .creditCard, openingBalance: usd(-50), cursor: day(10)
        )
        let inflow = try makeResponse([remoteTransaction("t-in", amount: "30.00", posted: day(6))])
        let cardOutcome = try SimpleFINSyncEngine.applyAccountSync(
            response: inflow, link: &cardLink,
            window: .recurring(requestStartEpoch: day(5)),
            workspace: &cardWorkspace, nowEpoch: day(15)
        )
        #expect(cardWorkspace.transactions[cardOutcome.importedTransactionIDs[0]]?.postingState == .staged)
        #expect(try cardWorkspace.registerBalanceAsOf(accountID: cardAccountID, epoch: day(7)) == usd(-20))
    }

    @Test func registerBalanceAsOfPullsCompleteTransferPairs() throws {
        var workspace = try makeWorkspace(timeZone: "UTC")
        let checking = try workspace.addAccount(
            name: "Checking", type: .checking, onBudget: true,
            openingBalance: usd(100), openingDate: date("2025-01-01"), nowEpoch: testEpoch
        )
        let savings = try workspace.addAccount(
            name: "Savings", type: .savings, onBudget: true,
            openingBalance: usd(100), openingDate: date("2025-01-01"), nowEpoch: testEpoch
        )
        let groceries = workspace.categoryID(named: "Groceries")
        let outLeg = try workspace.addManualTransaction(
            accountID: checking, date: date("2025-01-10"), payeeName: "Move",
            categoryID: groceries, amountMilliunits: usd(-50), nowEpoch: day(15)
        )
        let inLeg = try workspace.addManualTransaction(
            accountID: savings, date: date("2025-01-04"), payeeName: "Move",
            categoryID: workspace.rtaCategoryID, amountMilliunits: usd(50), nowEpoch: day(15)
        )
        _ = try workspace.pairExistingTransactions(outLeg, inLeg, nowEpoch: day(15))

        // Jan 6 sits between the two leg dates. The §3.2 pair-pulled cutoff
        // includes the checking leg (dated Jan 10) because the pair's earlier
        // leg (Jan 4) is inside the prefix — no cutoff exposes half a pair.
        let jan6 = day(5) + 43_200
        #expect(try workspace.registerBalanceAsOf(accountID: checking, epoch: jan6) == usd(50))
        #expect(try workspace.registerBalanceAsOf(accountID: savings, epoch: jan6) == usd(150))

        // Before either leg, neither side is included.
        let jan2 = day(1) + 43_200
        #expect(try workspace.registerBalanceAsOf(accountID: checking, epoch: jan2) == usd(100))
        #expect(try workspace.registerBalanceAsOf(accountID: savings, epoch: jan2) == usd(100))
    }

    // MARK: - closedMonthImportPending informational badge

    @Test func closedMonthImportBadgeLifecycle() throws {
        var (workspace, link, _) = try makeFixture(currentMonth: "2025-02", cursor: day(10))
        try workspace.closeMonth(month("2025-01"), nowEpoch: day(35))

        let response = try makeResponse([
            remoteTransaction("t-1", amount: "-8.00", posted: day(19))
        ])
        let outcome = try SimpleFINSyncEngine.applyAccountSync(
            response: response, link: &link,
            window: .recurring(requestStartEpoch: day(5)),
            workspace: &workspace, nowEpoch: day(36)
        )
        // Append-only closed-month import: staged row, cursor advances, and
        // the link keeps syncing with the informational badge set.
        #expect(outcome.closedMonthAppendCount == 1)
        #expect(outcome.newCursor == day(19))
        #expect(link.status == .active)
        #expect(link.pauseReason == .closedMonthImportPending)
        let transactionID = outcome.importedTransactionIDs[0]
        #expect(workspace.transactions[transactionID]?.stageReason == .closedMonthImport)

        // Reopening the month lets the normal replay workflow rehabilitate the
        // row; the badge clears on the next pass.
        try workspace.reopenMonth(month("2025-01"), nowEpoch: day(37))
        #expect(workspace.transactions[transactionID]?.stageReason != .closedMonthImport)
        let second = try SimpleFINSyncEngine.applyAccountSync(
            response: response, link: &link,
            window: .recurring(requestStartEpoch: day(14)),
            workspace: &workspace, nowEpoch: day(38)
        )
        #expect(second.pause == nil)
        #expect(link.status == .active)
        #expect(link.pauseReason == nil)
    }

    @Test func snapshotDiscrepancyPauseWinsOverClosedMonthInformationalBadge() throws {
        var (workspace, link, _) = try makeFixture(currentMonth: "2025-02", cursor: day(10))
        try workspace.closeMonth(month("2025-01"), nowEpoch: day(35))

        let response = try makeResponse(
            [remoteTransaction("t-1", amount: "-8.00", posted: day(19))],
            balance: "80.00",
            balanceDate: day(19)
        )
        let outcome = try SimpleFINSyncEngine.applyAccountSync(
            response: response,
            link: &link,
            window: .recurring(requestStartEpoch: day(5)),
            workspace: &workspace,
            nowEpoch: day(36)
        )

        #expect(outcome.discrepancyID != nil)
        #expect(outcome.pause == .snapshotDiscrepancy)
        #expect(link.status == .paused)
        #expect(link.pauseReason == .snapshotDiscrepancy)
    }

    // MARK: - §4.4 initial link

    @Test func initialLinkCalculationNormalizesSnapshotAndUsesHalfOpenInterval() throws {
        // Inverted provider: raw "50.00" snapshot means $50 of debt, raw
        // "12.00"/"3.00" are purchases. The audit bug mixed a raw-sign
        // snapshot with normalized history; both must be normalized.
        let calculation = try SimpleFINSynchronizer.initialLinkCalculation(
            snapshotBalanceDecimalString: "50.00",
            history: [
                remoteTransaction("t-at-start", amount: "5.00", posted: day(5)),
                remoteTransaction("t-mid", amount: "12.00", posted: day(7)),
                remoteTransaction("t-at-end", amount: "3.00", posted: day(10))
            ],
            accountType: .creditCard,
            signNormalization: .inverted,
            startEpoch: day(5),
            balanceDateEpoch: day(10)
        )
        // (S,T] is half-open: the posted == S row is excluded, posted == T
        // included. opening = -50 - (-12 - 3) = -35.
        #expect(calculation.importedTransactionIDs == ["t-mid", "t-at-end"])
        #expect(calculation.normalizedHistoryTotalDecimalString == "-15")
        #expect(calculation.openingBalanceDecimalString == "-35")

        // Normal-sign regression: the snapshot passes through unchanged.
        let normal = try SimpleFINSynchronizer.initialLinkCalculation(
            snapshotBalanceDecimalString: "90.00",
            history: [remoteTransaction("t-1", amount: "-10.00", posted: day(7))],
            accountType: .checking,
            signNormalization: .normal,
            startEpoch: day(5),
            balanceDateEpoch: day(10)
        )
        #expect(normal.openingBalanceDecimalString == "100")
    }

    @Test func initialLinkWindowImportsExactlyBoundedIntervalAndSetsCursorToT() throws {
        var (workspace, link, accountID) = try makeFixture()
        let response = try makeResponse([
            remoteTransaction("t-at-start", amount: "-1.00", posted: day(5)),
            remoteTransaction("t-in", amount: "-2.00", posted: day(7)),
            remoteTransaction("t-at-end", amount: "-3.00", posted: day(10)),
            remoteTransaction("t-beyond", amount: "-4.00", posted: day(12))
        ])
        let outcome = try SimpleFINSyncEngine.applyAccountSync(
            response: response, link: &link,
            window: .initialLink(startEpoch: day(5), balanceDateEpoch: day(10)),
            workspace: &workspace, nowEpoch: day(15)
        )
        #expect(outcome.importedTransactionIDs.count == 2)
        #expect(outcome.ignoredOutOfWindowCount == 2)
        #expect(outcome.newCursor == day(10))
        #expect(link.lastSuccessfulPostedEpoch == day(10))
        #expect(workspace.simpleFINImportRecord(
            connectionKey: "conn:c1", remoteAccountID: "acct-1", remoteTransactionID: "t-beyond"
        ) == nil)
        _ = accountID
    }

    @Test func initialLinkMismatchedRegisterCreatesDiscrepancyInSameCommit() throws {
        // §4.4 option (a): a user-entered opening that does not reproduce the
        // snapshot leaves the discrepancy record in the same commit as the
        // import. The engine's comparison covers this automatically because
        // the opening (100) plus in-window history (-3) differs from B (90).
        var (workspace, link, _) = try makeFixture()
        let response = try makeResponse(
            [remoteTransaction("t-1", amount: "-3.00", posted: day(7))],
            balance: "90.00", balanceDate: day(10)
        )
        let outcome = try SimpleFINSyncEngine.applyAccountSync(
            response: response, link: &link,
            window: .initialLink(startEpoch: day(5), balanceDateEpoch: day(10)),
            workspace: &workspace, nowEpoch: day(15)
        )
        let discrepancyID = try #require(outcome.discrepancyID)
        let discrepancy = try #require(workspace.snapshotDiscrepancies[discrepancyID])
        #expect(discrepancy.remoteBalanceMilliunits == usd(90))
        #expect(discrepancy.localRegisterMilliunits == usd(97))
        #expect(discrepancy.status == .open)
        #expect(discrepancy.simpleFINLinkIdentity == link.identity)
        #expect(outcome.pause == .snapshotDiscrepancy)
        #expect(link.status == .paused)
        #expect(link.pauseReason == .snapshotDiscrepancy)
        #expect(outcome.newCursor == day(10))
    }

    @Test func initialLinkUsesDiscoverySnapshotWhenHistoryResponseMovesForward() throws {
        var (workspace, link, accountID) = try makeFixture()
        let response = try makeResponse(
            [remoteTransaction("t-1", amount: "-3.00", posted: day(7))],
            // The history response arrived after the discovery snapshot and
            // reports a later balance. The initial-link comparison must still
            // use discovery B/T, not this later B'/T'.
            balance: "120.00", balanceDate: day(11)
        )
        let outcome = try SimpleFINSyncEngine.applyAccountSync(
            response: response,
            link: &link,
            window: .initialLinkWithSnapshot(
                startEpoch: day(5),
                balanceDateEpoch: day(10),
                snapshotBalanceMilliunits: usd(97)
            ),
            workspace: &workspace,
            nowEpoch: day(15)
        )

        #expect(outcome.discrepancyID == nil)
        #expect(outcome.pause == nil)
        #expect(outcome.newCursor == day(10))
        #expect(link.lastSuccessfulPostedEpoch == day(10))
        #expect(try workspace.registerBalanceAsOf(accountID: accountID, epoch: day(10)) == usd(97))
    }

    // MARK: - link state Codable compatibility

    @Test func linkStateBackwardCompatibleDecoding() throws {
        // A pre-pause-state blob has no status/pauseReason keys.
        let old = Data("""
        {"connectionKey":"conn:c1","remoteAccountID":"acct-1",
         "localAccountID":"\(AccountID())","signNormalization":1,
         "lastSuccessfulPostedEpoch":123}
        """.utf8)
        let decoded = try JSONDecoder().decode(SimpleFINAccountLink.self, from: old)
        #expect(decoded.status == .active)
        #expect(decoded.pauseReason == nil)
        #expect(decoded.lastSuccessfulPostedEpoch == 123)

        // Paused state round-trips.
        var link = decoded
        link.pause(reason: .authRevoked, message: "Access revoked; a new Setup Token is required.")
        let reencoded = try JSONDecoder().decode(
            SimpleFINAccountLink.self,
            from: JSONEncoder().encode(link)
        )
        #expect(reencoded.status == .paused)
        #expect(reencoded.pauseReason == .authRevoked)
        #expect(reencoded.lastErrorRedacted == "Access revoked; a new Setup Token is required.")
        link.resume()
        #expect(link.status == .active)
        #expect(link.pauseReason == nil)
        #expect(link.lastErrorRedacted == nil)
    }
}

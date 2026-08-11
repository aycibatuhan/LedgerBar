import Foundation
import Testing
@testable import LedgerCore

/// M5.5 audit fixes: every initial-link rejection happens BEFORE any account
/// creation or cursor advancement, provider errors are never discarded, and a
/// positive computed card opening persists as an account-less
/// `positiveCardSnapshot` pause. UTC budget; `day(n)` = midnight of
/// January n+1, 2025.
@Suite("SimpleFIN initial-link validation and account-less pause")
struct SimpleFINInitialLinkValidationTests {
    private func day(_ n: Int64) -> Int64 { testEpoch + n * 86_400 }
    private var utcCalendar: BudgetCalendar { try! BudgetCalendar(timeZoneIdentifier: "UTC") }

    private func remoteTransaction(
        _ id: String?, amount: String, posted: Int64,
        payee: String? = "Payee", pending: Bool = false
    ) -> SimpleFINRemoteTransaction {
        SimpleFINRemoteTransaction(id: id, amount: amount, postedEpoch: posted, payee: payee, pending: pending)
    }

    private func makeResponse(
        _ transactions: [SimpleFINRemoteTransaction],
        balance: String = "0.00",
        balanceDate: Int64? = nil,
        errors: [String] = [],
        accountID: String = "acct-1"
    ) throws -> SimpleFINAccountsResponse {
        try SimpleFINAccountsResponse(
            accounts: [SimpleFINRemoteAccount(
                id: accountID, name: "Remote", currency: "USD", balance: balance,
                balanceDateEpoch: balanceDate, connectionID: "c1", transactions: transactions
            )],
            errors: errors
        )
    }

    private func validate(
        _ response: SimpleFINAccountsResponse,
        accountType: AccountType = .checking,
        sign: SimpleFINSignNormalization = .normal,
        nowEpoch: Int64
    ) throws -> SimpleFINRemoteAccount {
        try SimpleFINSynchronizer.validateInitialLinkResponse(
            response: response,
            connectionKey: "conn:c1",
            remoteAccountID: "acct-1",
            accountType: accountType,
            signNormalization: sign,
            calendar: utcCalendar,
            nowEpoch: nowEpoch
        )
    }

    private func expectValidationError(
        _ response: SimpleFINAccountsResponse,
        accountType: AccountType = .checking,
        sign: SimpleFINSignNormalization = .normal,
        nowEpoch: Int64,
        equals expected: SimpleFINProtocolError,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        do {
            _ = try validate(
                response,
                accountType: accountType,
                sign: sign,
                nowEpoch: nowEpoch
            )
            Issue.record("expected \(expected), got success", sourceLocation: sourceLocation)
        } catch let error as SimpleFINProtocolError {
            #expect(error == expected, sourceLocation: sourceLocation)
        } catch {
            Issue.record("expected \(expected), got \(error)", sourceLocation: sourceLocation)
        }
    }

    // MARK: - Validator rejections (all pre-mutation)

    @Test func providerErrorsRejectWithExactPayload() throws {
        let response = try makeResponse(
            [remoteTransaction("t-1", amount: "-1.00", posted: day(6))],
            errors: ["ERROR: Connection unavailable", "ERROR: Balances may be stale"]
        )
        expectValidationError(
            response, nowEpoch: day(10),
            equals: .providerReportedErrors(["ERROR: Connection unavailable", "ERROR: Balances may be stale"])
        )
    }

    @Test func missingRequestedAccountBlockRejects() throws {
        // Wrong account id entirely.
        let otherAccount = try makeResponse([], accountID: "acct-other")
        expectValidationError(otherAccount, nowEpoch: day(10), equals: .missingRequestedAccount)

        // Same id under a different connection key is not our account either.
        let foreignConnection = try SimpleFINAccountsResponse(accounts: [
            SimpleFINRemoteAccount(
                id: "acct-1", currency: "USD", balance: "0.00",
                connectionID: "someone-else", transactions: []
            )
        ])
        expectValidationError(foreignConnection, nowEpoch: day(10), equals: .missingRequestedAccount)
    }

    @Test func blockClaimingOurIDWithoutStableKeyRejects() throws {
        // The validated response type rejects this at construction; mutate a
        // valid response to simulate the defensive path.
        var response = try makeResponse([])
        response.accounts = [SimpleFINRemoteAccount(
            id: "acct-1", currency: "USD", balance: "0.00",
            organization: SimpleFINRemoteOrganization(name: "Name Only"),
            transactions: []
        )]
        expectValidationError(response, nowEpoch: day(10), equals: .missingStableRemoteIdentity)
    }

    @Test func missingOrEmptyRemoteTransactionIDRejects() throws {
        let nilID = try makeResponse([remoteTransaction(nil, amount: "-1.00", posted: day(6))])
        expectValidationError(nilID, nowEpoch: day(10), equals: .missingRemoteTransactionID)

        let emptyID = try makeResponse([remoteTransaction("", amount: "-1.00", posted: day(6))])
        expectValidationError(emptyID, nowEpoch: day(10), equals: .missingRemoteTransactionID)
    }

    @Test func malformedAmountAndBalanceReject() throws {
        let badAmount = try makeResponse([remoteTransaction("t-1", amount: "12.3.4", posted: day(6))])
        expectValidationError(badAmount, nowEpoch: day(10), equals: .invalidResponse("malformed posted amount"))

        // A malformed balance matters exactly when a balance-date announces a
        // snapshot comparison…
        let badBalance = try makeResponse(
            [remoteTransaction("t-1", amount: "-1.00", posted: day(6))],
            balance: "not-a-number", balanceDate: day(9)
        )
        expectValidationError(badBalance, nowEpoch: day(10), equals: .invalidResponse("malformed balance"))

        // …and is ignored when no balance-date is present.
        let noDate = try makeResponse(
            [remoteTransaction("t-1", amount: "-1.00", posted: day(6))],
            balance: "not-a-number"
        )
        #expect(try validate(noDate, nowEpoch: day(10)).id == "acct-1")
    }

    @Test func futureBudgetDateRejectsButLaterSameDayEpochPasses() throws {
        let future = try makeResponse([remoteTransaction("t-1", amount: "-1.00", posted: day(11))])
        expectValidationError(future, nowEpoch: day(10), equals: .futurePostedEpoch)

        // A later epoch on the same budget date is not a future posted date.
        let sameDay = try makeResponse([remoteTransaction("t-1", amount: "-1.00", posted: day(10) + 3_600)])
        #expect(try validate(sameDay, nowEpoch: day(10)).id == "acct-1")
    }

    @Test func pendingAndPostedZeroRowsAreSkippedNotValidated() throws {
        // §4.4 step 2 artifacts: pending and posted-0 rows are excluded by
        // design — even a missing id there must not reject the link.
        let response = try makeResponse([
            remoteTransaction(nil, amount: "-1.00", posted: day(6), pending: true),
            remoteTransaction(nil, amount: "not-a-number", posted: 0),
            remoteTransaction("t-1", amount: "-2.00", posted: day(7))
        ])
        let block = try validate(response, nowEpoch: day(10))
        #expect(block.transactions.count == 3)
    }

    @Test func invertedSignOverflowRejects() throws {
        // Int64.min milliunits negated overflows; the .userOpening branch
        // never runs initialLinkCalculation, so the validator must catch it.
        let response = try makeResponse([
            remoteTransaction("t-1", amount: "-9223372036854775.808", posted: day(6))
        ])
        expectValidationError(
            response,
            accountType: .creditCard,
            sign: .inverted,
            nowEpoch: day(10),
            equals: .arithmeticOverflow
        )
    }

    @Test func invalidRowsInNonMatchingBlocksAreIgnored() throws {
        let response = try SimpleFINAccountsResponse(accounts: [
            SimpleFINRemoteAccount(
                id: "acct-1", currency: "USD", balance: "0.00",
                connectionID: "c1",
                transactions: [remoteTransaction("t-1", amount: "-1.00", posted: day(6))]
            ),
            SimpleFINRemoteAccount(
                id: "acct-other", currency: "USD", balance: "0.00",
                connectionID: "c1",
                transactions: [remoteTransaction(nil, amount: "garbage", posted: day(6))]
            )
        ])
        let block = try validate(response, nowEpoch: day(10))
        #expect(block.id == "acct-1")
        #expect(block.transactions.count == 1)
    }

    // MARK: - Empty / stale / zero-posted history

    @Test func emptyHistoryBlockIsValidAndEngineCommitsCursorT() throws {
        let response = try makeResponse([], balance: "100.00", balanceDate: day(10))
        let block = try validate(response, nowEpoch: day(15))
        #expect(block.transactions.isEmpty)

        // Engine pass over the same untouched response: nothing imports, the
        // cursor commits at exactly T, register stays the opening (= B).
        var workspace = try makeWorkspace(timeZone: "UTC")
        let accountID = try workspace.addAccount(
            name: "Quiet", type: .savings, onBudget: true,
            openingBalance: usd(100), openingDate: date("2025-01-01"), nowEpoch: testEpoch
        )
        var link = SimpleFINAccountLink(
            connectionKey: "conn:c1", remoteAccountID: "acct-1", localAccountID: accountID
        )
        let outcome = try SimpleFINSyncEngine.applyAccountSync(
            response: response, link: &link,
            window: .initialLink(startEpoch: day(5), balanceDateEpoch: day(10)),
            workspace: &workspace, nowEpoch: day(15)
        )
        #expect(outcome.importedTransactionIDs.isEmpty)
        #expect(outcome.newCursor == day(10))
        #expect(link.lastSuccessfulPostedEpoch == day(10))
        #expect(outcome.discrepancyID == nil)
    }

    @Test func postedZeroExcludedFromCalculationAndEngineWindow() throws {
        let calculation = try SimpleFINSynchronizer.initialLinkCalculation(
            snapshotBalanceDecimalString: "97.00",
            history: [
                remoteTransaction("t-zero", amount: "-5.00", posted: 0),
                remoteTransaction("t-in", amount: "-3.00", posted: day(7))
            ],
            accountType: .checking,
            signNormalization: .normal,
            startEpoch: day(5),
            balanceDateEpoch: day(10)
        )
        #expect(calculation.normalizedHistoryTotalDecimalString == "-3")
        #expect(calculation.importedTransactionIDs == ["t-in"])
        #expect(calculation.openingBalanceDecimalString == "100")

        var workspace = try makeWorkspace(timeZone: "UTC")
        let accountID = try workspace.addAccount(
            name: "Linked", type: .checking, onBudget: true,
            openingBalance: usd(100), openingDate: date("2025-01-01"), nowEpoch: testEpoch
        )
        var link = SimpleFINAccountLink(
            connectionKey: "conn:c1", remoteAccountID: "acct-1", localAccountID: accountID
        )
        let response = try makeResponse([
            remoteTransaction("t-zero", amount: "-5.00", posted: 0),
            remoteTransaction("t-in", amount: "-3.00", posted: day(7))
        ])
        let outcome = try SimpleFINSyncEngine.applyAccountSync(
            response: response, link: &link,
            window: .initialLink(startEpoch: day(5), balanceDateEpoch: day(10)),
            workspace: &workspace, nowEpoch: day(15)
        )
        #expect(outcome.importedTransactionIDs.count == 1)
        #expect(outcome.ignoredOutOfWindowCount == 1)
    }

    @Test func initialLinkCalculationSkipsPendingRows() throws {
        // §4.4 step 2 "Exclude remote-pending rows": skipped, no longer fatal.
        let calculation = try SimpleFINSynchronizer.initialLinkCalculation(
            snapshotBalanceDecimalString: "90.00",
            history: [
                remoteTransaction("t-pending", amount: "-50.00", posted: day(6), pending: true),
                remoteTransaction("t-posted", amount: "-10.00", posted: day(7))
            ],
            accountType: .checking,
            signNormalization: .normal,
            startEpoch: day(5),
            balanceDateEpoch: day(10)
        )
        #expect(calculation.normalizedHistoryTotalDecimalString == "-10")
        #expect(calculation.importedTransactionIDs == ["t-posted"])
    }

    // MARK: - Account-less link (§4.4 step 6)

    @Test func accountlessLinkCodableRoundTripAndLegacyShapes() throws {
        var accountless = SimpleFINAccountLink(
            connectionKey: "conn:c1", remoteAccountID: "acct-1", localAccountID: nil
        )
        accountless.pause(
            reason: .positiveCardSnapshot,
            message: "The computed card opening is positive after normalization; the link is paused with no local account."
        )
        let encoded = try JSONEncoder().encode(accountless)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("localAccountID"))
        let decoded = try JSONDecoder().decode(SimpleFINAccountLink.self, from: encoded)
        #expect(decoded == accountless)
        #expect(decoded.localAccountID == nil)
        #expect(decoded.status == .paused)
        #expect(decoded.pauseReason == .positiveCardSnapshot)
        #expect(decoded.lastSuccessfulPostedEpoch == nil)

        // Legacy blob with a bound account still decodes bound.
        let bound = AccountID()
        let legacy = Data("""
        {"connectionKey":"conn:c1","remoteAccountID":"acct-1",
         "localAccountID":"\(bound)","signNormalization":1}
        """.utf8)
        let legacyDecoded = try JSONDecoder().decode(SimpleFINAccountLink.self, from: legacy)
        #expect(legacyDecoded.localAccountID == bound)
        #expect(legacyDecoded.status == .active)
    }

    @Test func engineIsNoOpForAccountlessLinks() throws {
        var workspace = try makeWorkspace(timeZone: "UTC")
        let before = workspace
        let response = try makeResponse(
            [remoteTransaction("t-1", amount: "-1.00", posted: day(6))],
            balance: "50.00", balanceDate: day(10)
        )

        // Paused account-less link: untouched, pause reason echoed.
        var paused = SimpleFINAccountLink(
            connectionKey: "conn:c1", remoteAccountID: "acct-1", localAccountID: nil
        )
        paused.pause(reason: .positiveCardSnapshot)
        let pausedOutcome = try SimpleFINSyncEngine.applyAccountSync(
            response: response, link: &paused,
            window: .recurring(requestStartEpoch: day(5)),
            workspace: &workspace, nowEpoch: day(15)
        )
        #expect(pausedOutcome.pause == .positiveCardSnapshot)
        #expect(pausedOutcome.importedTransactionIDs.isEmpty)
        #expect(workspace == before)

        // Resumed-but-unbound link (reachable via an explicit resume): still
        // inert — no import, no cursor, no pause mutation.
        var resumed = SimpleFINAccountLink(
            connectionKey: "conn:c1", remoteAccountID: "acct-1", localAccountID: nil
        )
        let resumedOutcome = try SimpleFINSyncEngine.applyAccountSync(
            response: response, link: &resumed,
            window: .recurring(requestStartEpoch: day(5)),
            workspace: &workspace, nowEpoch: day(15)
        )
        #expect(resumedOutcome.importedTransactionIDs.isEmpty)
        #expect(resumedOutcome.newCursor == nil)
        #expect(resumed.status == .active)
        #expect(resumed.lastSuccessfulPostedEpoch == nil)
        #expect(workspace == before)
    }

    @Test func accountlessPausedLinkPersistsAndColdReloads() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledgerbar-accountless-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("LedgerBar.sqlite")
        let store = try LedgerWorkspaceStore(databaseURL: databaseURL)
        let service = BudgetMutationService(store: store)
        _ = try await service.createBudget(
            name: "Test", currency: "USD", timeZoneIdentifier: "UTC",
            firstMonth: month("2025-01"), currentMonth: month("2025-01"), nowEpoch: testEpoch
        )
        _ = try await service.updateSimpleFINState(nowEpoch: testEpoch) { state in
            var created = SimpleFINConnectionState(
                status: .active, keychainItemID: "item", baseHost: "bridge.simplefin.org",
                basePort: 443, credentialGeneration: 1, createdAtEpoch: testEpoch
            )
            var link = SimpleFINAccountLink(
                connectionKey: "conn:c1", remoteAccountID: "card-1", localAccountID: nil
            )
            link.pause(
                reason: .positiveCardSnapshot,
                message: "The computed card opening is positive after normalization; the link is paused with no local account."
            )
            created.upsertLink(link)
            state = created
        }

        let coldStore = try LedgerWorkspaceStore(databaseURL: databaseURL)
        let coldService = BudgetMutationService(store: coldStore)
        _ = try await coldService.loadFirst()
        let reloaded = try await coldService.simpleFINState()
        let identity = SimpleFINAccountLink.identity(connectionKey: "conn:c1", remoteAccountID: "card-1")
        let link = try #require(reloaded?.link(identity: identity))
        #expect(link.localAccountID == nil)
        #expect(link.status == .paused)
        #expect(link.pauseReason == .positiveCardSnapshot)
        #expect(link.lastSuccessfulPostedEpoch == nil)

        // Re-linking the same identity binds an account via the identity
        // upsert, replacing the pause wholesale.
        let boundID = AccountID()
        _ = try await coldService.updateSimpleFINState(nowEpoch: testEpoch) { state in
            guard var updated = state else { return }
            updated.upsertLink(SimpleFINAccountLink(
                connectionKey: "conn:c1", remoteAccountID: "card-1",
                localAccountID: boundID, lastSuccessfulPostedEpoch: day(10)
            ))
            state = updated
        }
        let rebound = try await coldService.simpleFINState()?.link(identity: identity)
        #expect(rebound?.localAccountID == boundID)
        #expect(rebound?.status == .active)
        #expect(rebound?.pauseReason == nil)
    }

    // MARK: - Positive-card gate

    @Test func positiveCardOpeningGateDecisionMatrix() {
        func gate(
            _ type: AccountType, onBudget: Bool = true,
            currency: String = "USD", opening: Milliunits
        ) -> Bool {
            SimpleFINSynchronizer.positiveCardOpeningRequiresAccountlessPause(
                accountType: type, onBudget: onBudget,
                accountCurrency: currency, budgetCurrency: "USD",
                openingMilliunits: opening
            )
        }
        // Pauses: on-budget same-currency card with any positive opening
        // (identical for computed and user-entered values).
        #expect(gate(.creditCard, opening: usd(50)))
        #expect(gate(.creditCard, opening: 1))
        // Proceeds: zero or negative opening (pre-existing debt), off-budget
        // card, currency-mismatched card (register-only), cash-like types.
        #expect(!gate(.creditCard, opening: 0))
        #expect(!gate(.creditCard, opening: usd(-200)))
        #expect(!gate(.creditCard, onBudget: false, opening: usd(50)))
        #expect(!gate(.creditCard, currency: "EUR", opening: usd(50)))
        #expect(!gate(.checking, opening: usd(50)))
        #expect(!gate(.savings, opening: usd(50)))
        #expect(!gate(.cash, opening: usd(50)))
    }

    @Test func positiveSnapshotWithLegalOpeningStillImportsAndCommitsCursor() throws {
        // B > 0 but opening = B − Σ ≤ 0 (§4.4 step 7): the account exists with
        // legal debt, the refund stages under the card guard, register lands
        // at B via staged rows, and the cursor commits at T. The engine never
        // pauses for this; the app layer pauses the *bound* link afterwards.
        var workspace = try makeWorkspace(timeZone: "UTC")
        let cardID = try workspace.addAccount(
            name: "Card", type: .creditCard, onBudget: true,
            openingBalance: usd(-200), openingDate: date("2025-01-01"), nowEpoch: testEpoch
        )
        var link = SimpleFINAccountLink(
            connectionKey: "conn:c1", remoteAccountID: "acct-1", localAccountID: cardID
        )
        let response = try makeResponse(
            [remoteTransaction("t-refund", amount: "250.00", posted: day(7))],
            balance: "50.00", balanceDate: day(10)
        )
        let outcome = try SimpleFINSyncEngine.applyAccountSync(
            response: response, link: &link,
            window: .initialLink(startEpoch: day(5), balanceDateEpoch: day(10)),
            workspace: &workspace, nowEpoch: day(15)
        )
        #expect(outcome.pause == nil)
        #expect(outcome.importedTransactionIDs.count == 1)
        #expect(outcome.newCursor == day(10))
        let imported = workspace.transactions[outcome.importedTransactionIDs[0]]
        #expect(imported?.postingState == .staged)
        #expect(try workspace.registerBalanceAsOf(accountID: cardID, epoch: day(10)) == usd(50))
        #expect(outcome.discrepancyID == nil)
    }
}

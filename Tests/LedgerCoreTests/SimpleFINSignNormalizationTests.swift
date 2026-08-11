import Foundation
import Testing
@testable import LedgerCore

@Suite("SimpleFIN sign-normalization policy")
struct SimpleFINSignNormalizationTests {
    private func expectInvertedCashLikeRejection(
        _ accountType: AccountType,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(
            throws: SimpleFINSignNormalizationError.invertedCashLikeAccount,
            sourceLocation: sourceLocation
        ) {
            try SimpleFINSynchronizer.validateSignNormalization(
                accountType: accountType,
                signNormalization: .inverted
            )
        }
    }

    private func makeResponse() throws -> SimpleFINAccountsResponse {
        try SimpleFINAccountsResponse(accounts: [
            SimpleFINRemoteAccount(
                id: "synthetic-account",
                name: "Synthetic account",
                currency: "USD",
                balance: "10.00",
                balanceDateEpoch: testEpoch + 2 * 86_400,
                connectionID: "synthetic-connection",
                transactions: [
                    SimpleFINRemoteTransaction(
                        id: "synthetic-transaction",
                        amount: "-1.00",
                        postedEpoch: testEpoch + 86_400,
                        payee: "Synthetic payee"
                    )
                ]
            )
        ])
    }

    @Test func invertedCheckingIsRejected() {
        expectInvertedCashLikeRejection(.checking)
    }

    @Test func invertedSavingsIsRejected() {
        expectInvertedCashLikeRejection(.savings)
    }

    @Test func invertedCashIsRejected() {
        expectInvertedCashLikeRejection(.cash)
    }

    @Test func normalCashLikeAccountsRemainValid() throws {
        for accountType in [AccountType.checking, .savings, .cash] {
            try SimpleFINSynchronizer.validateSignNormalization(
                accountType: accountType,
                signNormalization: .normal
            )
            let calculation = try SimpleFINSynchronizer.initialLinkCalculation(
                snapshotBalanceDecimalString: "10.00",
                history: [],
                accountType: accountType,
                signNormalization: .normal,
                startEpoch: testEpoch,
                balanceDateEpoch: testEpoch + 86_400
            )
            #expect(calculation.openingBalanceDecimalString == "10")
        }
    }

    @Test func creditCardNormalAndInvertedRemainValid() throws {
        try SimpleFINSynchronizer.validateSignNormalization(
            accountType: .creditCard,
            signNormalization: .normal
        )
        try SimpleFINSynchronizer.validateSignNormalization(
            accountType: .creditCard,
            signNormalization: .inverted
        )

        let normal = try SimpleFINSynchronizer.initialLinkCalculation(
            snapshotBalanceDecimalString: "-10.00",
            history: [],
            accountType: .creditCard,
            signNormalization: .normal,
            startEpoch: testEpoch,
            balanceDateEpoch: testEpoch + 86_400
        )
        let inverted = try SimpleFINSynchronizer.initialLinkCalculation(
            snapshotBalanceDecimalString: "10.00",
            history: [],
            accountType: .creditCard,
            signNormalization: .inverted,
            startEpoch: testEpoch,
            balanceDateEpoch: testEpoch + 86_400
        )
        #expect(normal.openingBalanceDecimalString == "-10")
        #expect(inverted.openingBalanceDecimalString == "-10")
    }

    @Test func directInitialLinkAPIsCannotBypassPolicy() throws {
        let response = try makeResponse()
        let calendar = try BudgetCalendar(timeZoneIdentifier: "UTC")

        #expect(throws: SimpleFINSignNormalizationError.invertedCashLikeAccount) {
            _ = try SimpleFINSynchronizer.validateInitialLinkResponse(
                response: response,
                connectionKey: "conn:synthetic-connection",
                remoteAccountID: "synthetic-account",
                accountType: .checking,
                signNormalization: .inverted,
                calendar: calendar,
                nowEpoch: testEpoch + 3 * 86_400
            )
        }
        #expect(throws: SimpleFINSignNormalizationError.invertedCashLikeAccount) {
            _ = try SimpleFINSynchronizer.initialLinkCalculation(
                snapshotBalanceDecimalString: "10.00",
                history: response.accounts[0].transactions,
                accountType: .checking,
                signNormalization: .inverted,
                startEpoch: testEpoch,
                balanceDateEpoch: testEpoch + 2 * 86_400
            )
        }
    }

    @Test func directSyncEngineInvocationRejectsBeforeMutation() throws {
        var workspace = try makeWorkspace(timeZone: "UTC")
        let accountID = try workspace.addAccount(
            name: "Checking",
            type: .checking,
            onBudget: true,
            openingBalance: usd(10),
            openingDate: date("2025-01-01"),
            nowEpoch: testEpoch
        )
        var link = SimpleFINAccountLink(
            connectionKey: "conn:synthetic-connection",
            remoteAccountID: "synthetic-account",
            localAccountID: accountID,
            signNormalization: .inverted
        )
        let workspaceBefore = workspace
        let linkBefore = link

        #expect(throws: SimpleFINSignNormalizationError.invertedCashLikeAccount) {
            _ = try SimpleFINSyncEngine.applyAccountSync(
                response: makeResponse(),
                link: &link,
                window: .initialLink(
                    startEpoch: testEpoch,
                    balanceDateEpoch: testEpoch + 2 * 86_400
                ),
                workspace: &workspace,
                nowEpoch: testEpoch + 3 * 86_400
            )
        }
        #expect(workspace == workspaceBefore)
        #expect(link == linkBefore)
    }

    @Test func stateOnlyMutationCannotPersistInvertedCheckingLink() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledgerbar-sign-state-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LedgerWorkspaceStore(databaseURL: directory.appendingPathComponent("LedgerBar.sqlite"))
        let service = BudgetMutationService(store: store)
        _ = try await service.createBudget(
            name: "Sign policy",
            currency: "USD",
            timeZoneIdentifier: "UTC",
            firstMonth: month("2025-01"),
            currentMonth: month("2025-01"),
            nowEpoch: testEpoch
        )
        let accountID = try await service.transact(nowEpoch: testEpoch) { workspace in
            try workspace.addAccount(
                name: "Checking",
                type: .checking,
                onBudget: true,
                openingDate: date("2025-01-01"),
                nowEpoch: testEpoch
            )
        }

        await #expect(throws: SimpleFINSignNormalizationError.invertedCashLikeAccount) {
            _ = try await service.updateSimpleFINState(nowEpoch: testEpoch + 1) { state in
                var connection = SimpleFINConnectionState(
                    status: .active,
                    keychainItemID: "synthetic-item-reference",
                    baseHost: "bridge.simplefin.org",
                    basePort: 443,
                    credentialGeneration: 1,
                    createdAtEpoch: testEpoch
                )
                connection.upsertLink(SimpleFINAccountLink(
                    connectionKey: "conn:synthetic-connection",
                    remoteAccountID: "synthetic-account",
                    localAccountID: accountID,
                    signNormalization: .inverted
                ))
                state = connection
            }
        }
        #expect(try await service.simpleFINState() == nil)
    }

    @Test func rejectedAtomicLinkLeavesNoPartialLedgerOrLinkState() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledgerbar-sign-atomic-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("LedgerBar.sqlite")
        let store = try LedgerWorkspaceStore(databaseURL: databaseURL)
        let service = BudgetMutationService(store: store)
        _ = try await service.createBudget(
            name: "Sign policy",
            currency: "USD",
            timeZoneIdentifier: "UTC",
            firstMonth: month("2025-01"),
            currentMonth: month("2025-01"),
            nowEpoch: testEpoch
        )
        let before = try #require(await service.currentSnapshot())

        await #expect(throws: SimpleFINSignNormalizationError.invertedCashLikeAccount) {
            _ = try await service.syncTransact(nowEpoch: testEpoch + 2 * 86_400) { workspace, state in
                let accountID = try workspace.addAccount(
                    name: "Checking",
                    type: .checking,
                    onBudget: true,
                    openingDate: date("2025-01-01"),
                    nowEpoch: testEpoch
                )
                _ = try workspace.importPostedTransaction(
                    accountID: accountID,
                    connectionKey: "conn:synthetic-connection",
                    remoteAccountID: "synthetic-account",
                    remoteTransactionID: "synthetic-transaction",
                    postedEpoch: testEpoch + 86_400,
                    payeeName: "Synthetic payee",
                    amountMilliunits: usd(-1),
                    nowEpoch: testEpoch + 2 * 86_400
                )
                var connection = SimpleFINConnectionState(
                    status: .active,
                    keychainItemID: "synthetic-item-reference",
                    baseHost: "bridge.simplefin.org",
                    basePort: 443,
                    credentialGeneration: 1,
                    createdAtEpoch: testEpoch
                )
                connection.upsertLink(SimpleFINAccountLink(
                    connectionKey: "conn:synthetic-connection",
                    remoteAccountID: "synthetic-account",
                    localAccountID: accountID,
                    signNormalization: .inverted,
                    lastSuccessfulPostedEpoch: testEpoch + 86_400
                ))
                state = connection
            }
        }

        let after = try #require(await service.currentSnapshot())
        #expect(after == before)
        #expect(after.accounts.isEmpty)
        #expect(after.transactions.isEmpty)
        #expect(after.simpleFINImports.isEmpty)
        #expect(try await service.simpleFINState() == nil)

        let coldStore = try LedgerWorkspaceStore(databaseURL: databaseURL)
        #expect(try coldStore.loadFirstWorkspace().snapshot() == before)
        #expect(try coldStore.loadSimpleFINState(budgetID: before.budget.id) == nil)
    }
}

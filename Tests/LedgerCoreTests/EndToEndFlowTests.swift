import Foundation
import Testing
@testable import LedgerCore

/// Drives the exact chain the app uses at runtime: `BudgetMutationService`
/// over a real SQLite store → synthetic SimpleFIN response through
/// `SimpleFINSyncEngine` inside one `syncTransact` per pass (network stays
/// outside the write and imports+cursors commit atomically, §6.4) →
/// staged-row resolution → reconciliation → verified backup → cold reload
/// from disk. All fixture identifiers are synthetic; no credential material
/// appears anywhere.
@Suite("End-to-end app flow — service, sync, resolution, reconcile, backup, reload")
struct EndToEndFlowTests {
    private enum SyncFixtureError: Error { case missingState }

    private func day(_ n: Int64) -> Int64 { testEpoch + n * 86_400 }

    @Test("full flow preserves conservation, dedup, registers, and cold-reload equality")
    func fullFlow() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledgerbar-e2e-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("LedgerBar.sqlite")
        let store = try LedgerWorkspaceStore(databaseURL: databaseURL)
        let service = BudgetMutationService(store: store)
        let now = day(20)

        // 1. Onboarding-equivalent budget creation.
        _ = try await service.createBudget(
            name: "E2E", currency: "USD", timeZoneIdentifier: "America/New_York",
            firstMonth: month("2025-01"), currentMonth: month("2025-01"), nowEpoch: now
        )

        // 2. Local accounts: checking +$1,000 → RTA; card -$200 pre-existing debt.
        let (checking, card) = try await service.transact(nowEpoch: now) { workspace in
            let checking = try workspace.addAccount(
                name: "Checking", type: .checking, onBudget: true,
                openingBalance: usd(1_000), openingDate: date("2025-01-02"), nowEpoch: testEpoch
            )
            let card = try workspace.addAccount(
                name: "Card", type: .creditCard, onBudget: true,
                openingBalance: -usd(200), openingDate: date("2025-01-02"), nowEpoch: testEpoch
            )
            return (checking, card)
        }
        _ = try await service.transact(nowEpoch: now) { workspace in
            try workspace.setBudgeted(
                categoryID: workspace.categoryID(named: "Dining"),
                month: month("2025-01"), value: usd(300)
            )
        }

        // 3. Synthetic SimpleFIN response. The card provider uses the inverted
        //    sign convention (§4.2): raw "+40" is a purchase, raw "-50" a credit.
        let response = try SimpleFINAccountsResponse(accounts: [
            SimpleFINRemoteAccount(
                id: "chk-1", name: "Remote Checking", currency: "USD", balance: "900.00",
                balanceDateEpoch: day(15), connectionID: "conn-e2e",
                transactions: [
                    SimpleFINRemoteTransaction(
                        id: "t-1", amount: "-100.00", postedEpoch: day(5),
                        description: "coffee", payee: "Coffee Shop"
                    ),
                    SimpleFINRemoteTransaction(
                        id: "t-2", amount: "-5.00", postedEpoch: day(6),
                        payee: "Pending Vendor", pending: true
                    )
                ]
            ),
            SimpleFINRemoteAccount(
                id: "card-1", name: "Remote Card", currency: "USD", balance: "190.00",
                balanceDateEpoch: day(15), connectionID: "conn-e2e",
                transactions: [
                    SimpleFINRemoteTransaction(
                        id: "t-3", amount: "40.00", postedEpoch: day(6), payee: "Bistro"
                    ),
                    SimpleFINRemoteTransaction(
                        id: "t-4", amount: "-50.00", postedEpoch: day(8), payee: "Card Credit"
                    )
                ]
            )
        ])
        let connectionKey = "conn:conn-e2e"
        var links: [String: SimpleFINAccountLink] = [:]
        for link in [
            SimpleFINAccountLink(
                connectionKey: connectionKey, remoteAccountID: "chk-1",
                localAccountID: checking, signNormalization: .normal,
                lastSuccessfulPostedEpoch: day(1)
            ),
            SimpleFINAccountLink(
                connectionKey: connectionKey, remoteAccountID: "card-1",
                localAccountID: card, signNormalization: .inverted,
                lastSuccessfulPostedEpoch: day(1)
            )
        ] {
            links[link.identity] = link
        }
        let frozenLinks = links
        _ = try await service.updateSimpleFINState(nowEpoch: now) { state in
            var created = SimpleFINConnectionState(
                status: .active, keychainItemID: "test-item",
                baseHost: "bridge.simplefin.org", basePort: 443,
                credentialGeneration: 1, createdAtEpoch: now
            )
            for link in frozenLinks.values { created.upsertLink(link) }
            state = created
        }

        // 4. Per-account engine passes inside ONE syncTransact each
        //    (SyncCoordinator shape): imports and that link's cursor commit in
        //    the same database transaction.
        let overlap = Int64(5) * 86_400
        let outcomes = try await service.syncTransact(nowEpoch: now) { workspace, state in
            guard var updated = state else { throw SyncFixtureError.missingState }
            var collected: [SimpleFINAccountSyncOutcome] = []
            for identity in frozenLinks.keys.sorted() {
                guard var link = updated.link(identity: identity),
                      let cursor = link.lastSuccessfulPostedEpoch else { continue }
                let outcome = try SimpleFINSyncEngine.applyAccountSync(
                    response: response, link: &link,
                    window: .recurring(requestStartEpoch: cursor - overlap),
                    workspace: &workspace, nowEpoch: now
                )
                updated.upsertLink(link)
                collected.append(outcome)
            }
            updated.lastSuccessfulSyncAtEpoch = now
            state = updated
            return collected
        }
        #expect(outcomes.flatMap(\.importedTransactionIDs).count == 3)
        #expect(outcomes.map(\.skippedPendingCount).reduce(0, +) == 1)
        #expect(outcomes.allSatisfy { $0.pause == nil && $0.conflictIDs.isEmpty && $0.discrepancyID == nil })

        var workspace = try BudgetWorkspace(snapshot: await service.currentSnapshot()!)
        #expect(workspace.simpleFINImports.count == 3)
        let stagedCredit = workspace.importedTransactionID(
            connectionKey: connectionKey, remoteAccountID: "card-1", remoteTransactionID: "t-4"
        )!
        let importedCoffee = workspace.importedTransactionID(
            connectionKey: connectionKey, remoteAccountID: "chk-1", remoteTransactionID: "t-1"
        )!

        // Classification: inverted-sign card credit is staged unlinkedCardInflow;
        // register includes it, projection excludes it (§3.7).
        #expect(workspace.transactions[stagedCredit]?.postingState == .staged)
        #expect(workspace.transactions[stagedCredit]?.stageReason == .unlinkedCardInflow)
        #expect(workspace.transactions[stagedCredit]?.amountMilliunits == usd(50))
        #expect(workspace.transactions[importedCoffee]?.postingState == .needsCategory)
        var projection = try workspace.projection()
        #expect(projection.registerBalances[checking] == usd(900))
        #expect(projection.registerBalances[card] == -usd(190))
        #expect(projection.projectionBalances[card] == -usd(240))
        #expect(try ConservationCheck.compute(workspace, month: month("2025-01")).holds)

        // 5. Resolve the staged credit as a budget-neutral Card Debt Adjustment:
        //    projection reclassifies, register balance is unchanged (§3.7).
        _ = try await service.transact(nowEpoch: now) { workspace in
            try workspace.resolveStagedAsCardDebtAdjustment(stagedCredit, nowEpoch: now)
        }
        workspace = try BudgetWorkspace(snapshot: await service.currentSnapshot()!)
        projection = try workspace.projection()
        #expect(projection.registerBalances[card] == -usd(190))
        #expect(projection.projectionBalances[card] == -usd(190))
        #expect(try ConservationCheck.compute(workspace, month: month("2025-01")).holds)

        // 6. Reconcile checking: clear the imported row, statement matches, no
        //    adjustment; opening + cleared import newly reconciled.
        _ = try await service.transact(nowEpoch: now) { workspace in
            try workspace.setCleared(transactionID: importedCoffee, cleared: .cleared, nowEpoch: now)
        }
        let outcome = try await service.transact(nowEpoch: now) { workspace in
            try workspace.completeReconciliation(
                accountID: checking, statementDate: date("2025-01-16"),
                statementBalanceMilliunits: usd(900), nowEpoch: now
            )
        }
        #expect(outcome.clearedBalanceMilliunits == usd(900))
        #expect(outcome.differenceMilliunits == 0)
        #expect(outcome.adjustmentTransactionID == nil)
        #expect(outcome.newlyReconciledCount == 2)

        // 7. Dedup: re-applying the identical response through the engine adds
        //    no rows, raises no conflicts or discrepancies (the resolved and
        //    reconciled rows are unchanged remotely), and only refreshes the
        //    import records' last-seen state.
        let countBefore = await service.currentSnapshot()!.transactions.count
        let reapplied = try await service.syncTransact(nowEpoch: now) { workspace, state in
            guard var updated = state else { throw SyncFixtureError.missingState }
            var collected: [SimpleFINAccountSyncOutcome] = []
            for identity in frozenLinks.keys.sorted() {
                guard var link = updated.link(identity: identity),
                      let cursor = link.lastSuccessfulPostedEpoch else { continue }
                let outcome = try SimpleFINSyncEngine.applyAccountSync(
                    response: response, link: &link,
                    window: .recurring(requestStartEpoch: cursor - overlap),
                    workspace: &workspace, nowEpoch: now
                )
                updated.upsertLink(link)
                collected.append(outcome)
            }
            state = updated
            return collected
        }
        let countAfter = await service.currentSnapshot()!.transactions.count
        #expect(countBefore == countAfter)
        #expect(reapplied.flatMap(\.importedTransactionIDs).isEmpty)
        #expect(reapplied.allSatisfy { $0.conflictIDs.isEmpty && $0.discrepancyID == nil })
        let recordsAfterReapply = await service.currentSnapshot()!.simpleFINImports
        #expect(recordsAfterReapply.count == 3)

        // 8. Verified backup exists and is readable as an independent store.
        let backupURL = directory.appendingPathComponent("backup.sqlite")
        try await service.backup(to: backupURL)
        #expect(FileManager.default.fileExists(atPath: backupURL.path))
        let liveSnapshot = await service.currentSnapshot()!
        let restoredStore = try LedgerWorkspaceStore(databaseURL: backupURL)
        let restored = try restoredStore.loadFirstWorkspace()
        #expect(restored.snapshot() == liveSnapshot)

        // 9. Cold reload: a fresh store+service on the same file reproduces the
        //    exact state, the SimpleFIN cursors, and the oracle.
        let coldStore = try LedgerWorkspaceStore(databaseURL: databaseURL)
        let coldService = BudgetMutationService(store: coldStore)
        let coldSnapshot = try await coldService.loadFirst()
        #expect(coldSnapshot == liveSnapshot)
        let coldState = try await coldService.simpleFINState()
        #expect(coldState?.link(identity: SimpleFINAccountLink.identity(connectionKey: connectionKey, remoteAccountID: "chk-1"))?.lastSuccessfulPostedEpoch == day(5))
        #expect(coldState?.link(identity: SimpleFINAccountLink.identity(connectionKey: connectionKey, remoteAccountID: "card-1"))?.lastSuccessfulPostedEpoch == day(8))
        let coldWorkspace = try BudgetWorkspace(snapshot: coldSnapshot)
        #expect(try ConservationCheck.compute(coldWorkspace, month: month("2025-01")).holds)
        let rta = try coldWorkspace.snapshot("2025-01").rtaEnd
        #expect(rta == usd(700)) // +1,000 opening inflow − 300 assigned
    }
}

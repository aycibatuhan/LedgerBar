import Foundation
import GRDB
import Testing
@testable import LedgerCore

@Suite("M5.9 snapshot-discrepancy resolution")
struct SnapshotDiscrepancyResolutionTests {
    private enum FixtureError: Error {
        case expectedStagedRow
        case expectedAdjustment
        case missingWorkspacePayload
    }

    private struct Harness {
        let directory: URL
        let store: LedgerWorkspaceStore
        let service: BudgetMutationService
        let budgetID: BudgetID
    }

    private struct DiscrepancyFixture: Sendable {
        let accountID: AccountID
        let discrepancyID: SnapshotDiscrepancyID
        let version: SnapshotDiscrepancyVersion
        let observedEpoch: Int64
        let localBalance: Milliunits
        let remoteBalance: Milliunits
    }

    private func makeHarness() async throws -> Harness {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledgerbar-m59-discrepancy-\(UUID().uuidString)", isDirectory: true)
        let store = try LedgerWorkspaceStore(
            databaseURL: directory.appendingPathComponent("LedgerBar.sqlite")
        )
        let service = BudgetMutationService(store: store)
        let created = try await service.createBudget(
            name: "M5.9",
            currency: "USD",
            timeZoneIdentifier: "UTC",
            firstMonth: month("2025-01"),
            currentMonth: month("2025-01"),
            nowEpoch: testEpoch
        )
        return Harness(
            directory: directory,
            store: store,
            service: service,
            budgetID: created.budget.id
        )
    }

    private func withHarness(
        _ body: (Harness) async throws -> Void
    ) async throws {
        let harness = try await makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        try await body(harness)
    }

    private func seedDiscrepancy(
        in harness: Harness,
        accountType: AccountType,
        openingBalance: Milliunits,
        difference: Milliunits,
        observedDate: BudgetDate = date("2025-01-10"),
        storedDifference: Milliunits? = nil,
        rowBudgetID: BudgetID? = nil,
        closed: Bool = false,
        onBudget: Bool = true,
        closedObservedMonth: Bool = false
    ) async throws -> DiscrepancyFixture {
        try await harness.service.transact(nowEpoch: testEpoch) { workspace in
            let accountID = try workspace.addAccount(
                name: "Synthetic Account",
                type: accountType,
                onBudget: onBudget,
                openingBalance: openingBalance,
                openingDate: date("2025-01-02"),
                nowEpoch: testEpoch
            )
            if closed {
                var account = try #require(workspace.accounts[accountID])
                account.closed = true
                workspace.setAccount(account)
            }
            if closedObservedMonth {
                workspace.setClosedMonth(ClosedMonthRow(
                    budgetID: workspace.budget.id,
                    month: observedDate.budgetMonth,
                    status: .closed,
                    closedAtEpoch: testEpoch
                ))
            }
            let observedEpoch = try workspace.calendar.noonEpoch(of: observedDate)
            let localBalance = try workspace.registerBalanceAsOf(
                accountID: accountID,
                epoch: observedEpoch
            )
            let sum = localBalance.addingReportingOverflow(difference)
            guard !sum.overflow else { throw MutationError.arithmeticOverflow }
            let discrepancy = SnapshotDiscrepancyRow(
                budgetID: rowBudgetID ?? workspace.budget.id,
                accountID: accountID,
                observedEpoch: observedEpoch,
                remoteBalanceMilliunits: sum.partialValue,
                localRegisterMilliunits: localBalance,
                differenceMilliunits: storedDifference ?? difference,
                createdAtEpoch: testEpoch
            )
            workspace.setSnapshotDiscrepancy(discrepancy)
            return DiscrepancyFixture(
                accountID: accountID,
                discrepancyID: discrepancy.id,
                version: SnapshotDiscrepancyVersion(discrepancy: discrepancy),
                observedEpoch: observedEpoch,
                localBalance: localBalance,
                remoteBalance: sum.partialValue
            )
        }
    }

    private func command(
        harness: Harness,
        fixture: DiscrepancyFixture,
        choice: SnapshotDiscrepancyResolutionChoice
    ) -> SnapshotDiscrepancyResolutionCommand {
        SnapshotDiscrepancyResolutionCommand(
            budgetID: harness.budgetID,
            discrepancyID: fixture.discrepancyID,
            expectedVersion: fixture.version,
            choice: choice
        )
    }

    private func sortedSnapshotData(_ snapshot: BudgetWorkspaceSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(snapshot)
    }

    private func requireAdjustmentID(
        _ result: SnapshotDiscrepancyResolutionResult
    ) throws -> TransactionID {
        guard case .adjustment(let transactionID) = result.artifact else {
            throw FixtureError.expectedAdjustment
        }
        return transactionID
    }

    private func assertResolvedAdjustment(
        harness: Harness,
        fixture: DiscrepancyFixture,
        result: SnapshotDiscrepancyResolutionResult,
        accountType: AccountType,
        expectedAmount: Milliunits
    ) throws {
        let adjustmentID = try requireAdjustmentID(result)
        let workspace = try harness.store.load(budgetID: harness.budgetID)
        let discrepancy = try #require(workspace.snapshotDiscrepancies[fixture.discrepancyID])
        let adjustment = try #require(workspace.transactions[adjustmentID])
        let payeeID = try #require(adjustment.payeeID)
        let audit = try #require(workspace.auditEvents.last)

        #expect(result.reason == .adjustment)
        #expect(discrepancy.status == .resolved)
        #expect(discrepancy.resolutionReason == .adjustment)
        #expect(discrepancy.adjustmentTransactionID == adjustmentID)
        #expect(discrepancy.resolvedAtEpoch != nil)
        #expect(adjustment.accountID == fixture.accountID)
        #expect(adjustment.sourceKind == .system)
        #expect(adjustment.kind == .adjustment)
        #expect(adjustment.amountMilliunits == expectedAmount)
        #expect(adjustment.effectiveAtEpoch == fixture.observedEpoch)
        #expect(adjustment.postingState == .posted)
        #expect(adjustment.cleared == .cleared)
        #expect(adjustment.approved)
        #expect(
            workspace.payees[payeeID]?.systemKind
                == (accountType == .creditCard ? .cardDebtAdjustment : .reconciliationAdjustment)
        )
        #expect(adjustment.categoryID == (accountType == .creditCard ? nil : workspace.rtaCategoryID))
        #expect(audit.entityType == "snapshotDiscrepancy")
        #expect(audit.entityID == fixture.discrepancyID.description)
        #expect(audit.eventKind == "snapshotDiscrepancyResolved")
        #expect(audit.metadata == ["reason": "adjustment", "artifact": "adjustment"])
        #expect(
            try workspace.registerBalanceAsOf(
                accountID: fixture.accountID,
                epoch: fixture.observedEpoch
            ) == fixture.remoteBalance
        )
        #expect(try ConservationCheck.compute(workspace, month: month("2025-01")).holds)
    }

    @Test("checking, savings, and cash use the signed difference in both directions")
    func cashLikePositiveAndNegativeAdjustmentsUseSignedDifferenceAndRTA() async throws {
        for accountType in [AccountType.checking, .savings, .cash] {
            for difference in [usd(25), -usd(25)] {
                try await withHarness { harness in
                    let fixture = try await seedDiscrepancy(
                        in: harness,
                        accountType: accountType,
                        openingBalance: usd(100),
                        difference: difference
                    )
                    let before = try harness.store.load(budgetID: harness.budgetID)
                    let beforeMonth = try #require(before.projection().month(month("2025-01")))

                    let result = try await harness.service.resolveSnapshotDiscrepancy(
                        command(harness: harness, fixture: fixture, choice: .adjustment),
                        nowEpoch: try before.calendar.noonEpoch(of: date("2025-01-31"))
                    )
                    try assertResolvedAdjustment(
                        harness: harness,
                        fixture: fixture,
                        result: result,
                        accountType: accountType,
                        expectedAmount: difference
                    )

                    let after = try harness.store.load(budgetID: harness.budgetID)
                    let afterMonth = try #require(after.projection().month(month("2025-01")))
                    #expect(afterMonth.rtaActivity == beforeMonth.rtaActivity + difference)
                    #expect(afterMonth.rtaEnd == beforeMonth.rtaEnd + difference)
                    #expect(after.allocations == before.allocations)
                }
            }
        }
    }

    @Test("credit-card adjustments at or below zero remain budget neutral")
    func creditCardAdjustmentAtOrBelowZeroIsBudgetNeutral() async throws {
        for difference in [usd(50), usd(100)] {
            try await withHarness { harness in
                let fixture = try await seedDiscrepancy(
                    in: harness,
                    accountType: .creditCard,
                    openingBalance: -usd(100),
                    difference: difference
                )
                let before = try harness.store.load(budgetID: harness.budgetID)
                let beforeMonth = try #require(before.projection().month(month("2025-01")))

                let result = try await harness.service.resolveSnapshotDiscrepancy(
                    command(harness: harness, fixture: fixture, choice: .adjustment),
                    nowEpoch: try before.calendar.noonEpoch(of: date("2025-01-31"))
                )
                try assertResolvedAdjustment(
                    harness: harness,
                    fixture: fixture,
                    result: result,
                    accountType: .creditCard,
                    expectedAmount: difference
                )

                let after = try harness.store.load(budgetID: harness.budgetID)
                let afterProjection = try after.projection()
                let afterMonth = try #require(afterProjection.month(month("2025-01")))
                #expect(afterProjection.projectionBalances[fixture.accountID] == fixture.remoteBalance)
                #expect(afterMonth.rtaStart == beforeMonth.rtaStart)
                #expect(afterMonth.rtaActivity == beforeMonth.rtaActivity)
                #expect(afterMonth.rtaEnd == beforeMonth.rtaEnd)
                #expect(afterMonth.categories == beforeMonth.categories)
                #expect(afterMonth.payments == beforeMonth.payments)
                #expect(after.allocations == before.allocations)
            }
        }
    }

    @Test("a credit-card adjustment that would become positive rejects byte-for-byte")
    func creditCardAdjustmentCrossingPositiveIsRejectedWithoutMutation() async throws {
        try await withHarness { harness in
            let fixture = try await seedDiscrepancy(
                in: harness,
                accountType: .creditCard,
                openingBalance: -usd(100),
                difference: usd(101)
            )
            let before = try #require(await harness.service.currentSnapshot())
            let beforeBytes = try sortedSnapshotData(before)
            let workspace = try harness.store.load(budgetID: harness.budgetID)

            await #expect(throws: MutationError.cardBalanceWouldBecomePositive) {
                try await harness.service.resolveSnapshotDiscrepancy(
                    command(harness: harness, fixture: fixture, choice: .adjustment),
                    nowEpoch: try workspace.calendar.noonEpoch(of: date("2025-01-31"))
                )
            }

            let after = try #require(await harness.service.currentSnapshot())
            #expect(after == before)
            #expect(try sortedSnapshotData(after) == beforeBytes)
            #expect(try harness.store.load(budgetID: harness.budgetID).snapshot() == before)
        }
    }

    @Test("the observed prefix excludes later rows and includes stable staged rows")
    func adjustmentUsesExactObservedCutoffAndIncludesNonVoidedStagedRows() async throws {
        try await withHarness { harness in
            let seeded = try await harness.service.transact(nowEpoch: testEpoch) { workspace in
                let checking = try workspace.addAccount(
                    name: "Checking",
                    type: .checking,
                    onBudget: true,
                    openingBalance: usd(100),
                    openingDate: date("2025-01-02"),
                    nowEpoch: testEpoch
                )
                let card = try workspace.addAccount(
                    name: "Card",
                    type: .creditCard,
                    onBudget: true,
                    openingBalance: 0,
                    openingDate: date("2025-01-02"),
                    nowEpoch: testEpoch
                )
                let dining = workspace.categoryID(named: "Dining")
                _ = try workspace.addManualTransaction(
                    accountID: card,
                    date: date("2025-01-03"),
                    payeeName: "Purchase",
                    categoryID: dining,
                    amountMilliunits: -usd(10),
                    nowEpoch: testEpoch
                )

                let stagedID = TransactionID()
                let stagedEpoch = try workspace.calendar.noonEpoch(of: date("2025-01-05"))
                let sequence = try workspace.allocateSourceSequence()
                workspace.setTransaction(TransactionRow(
                    id: stagedID,
                    budgetID: workspace.budget.id,
                    accountID: checking,
                    payeeID: nil,
                    sourceKind: .manual,
                    date: date("2025-01-05"),
                    effectiveAtEpoch: stagedEpoch,
                    sourceOrderKey: .manual(sequence: sequence),
                    amountMilliunits: usd(5),
                    approved: true,
                    postingState: .staged,
                    stageReason: .cashInflowWithCreditDebt,
                    stageMetadata: StageMetadata(proposedCategoryID: dining),
                    categoryID: dining,
                    kind: .refund
                ))
                _ = try workspace.runReplayAndApplyDecisions()
                guard workspace.transactions[stagedID]?.postingState == .staged,
                      workspace.transactions[stagedID]?.stageReason == .cashInflowWithCreditDebt else {
                    throw FixtureError.expectedStagedRow
                }

                _ = try workspace.addManualTransaction(
                    accountID: checking,
                    date: date("2025-01-20"),
                    payeeName: "Later",
                    categoryID: dining,
                    amountMilliunits: -usd(30),
                    nowEpoch: testEpoch
                )
                let observedEpoch = try workspace.calendar.noonEpoch(of: date("2025-01-10"))
                let local = try workspace.registerBalanceAsOf(accountID: checking, epoch: observedEpoch)
                let discrepancy = SnapshotDiscrepancyRow(
                    budgetID: workspace.budget.id,
                    accountID: checking,
                    observedEpoch: observedEpoch,
                    remoteBalanceMilliunits: local + usd(5),
                    localRegisterMilliunits: local,
                    differenceMilliunits: usd(5),
                    createdAtEpoch: testEpoch
                )
                workspace.setSnapshotDiscrepancy(discrepancy)
                return (
                    fixture: DiscrepancyFixture(
                        accountID: checking,
                        discrepancyID: discrepancy.id,
                        version: SnapshotDiscrepancyVersion(discrepancy: discrepancy),
                        observedEpoch: observedEpoch,
                        localBalance: local,
                        remoteBalance: local + usd(5)
                    ),
                    stagedID: stagedID
                )
            }
            #expect(seeded.fixture.localBalance == usd(105))

            let workspace = try harness.store.load(budgetID: harness.budgetID)
            let result = try await harness.service.resolveSnapshotDiscrepancy(
                command(harness: harness, fixture: seeded.fixture, choice: .adjustment),
                nowEpoch: try workspace.calendar.noonEpoch(of: date("2025-01-31"))
            )
            try assertResolvedAdjustment(
                harness: harness,
                fixture: seeded.fixture,
                result: result,
                accountType: .checking,
                expectedAmount: usd(5)
            )

            let after = try harness.store.load(budgetID: harness.budgetID)
            #expect(after.transactions[seeded.stagedID]?.postingState == .staged)
            #expect(after.transactions[seeded.stagedID]?.stageReason == .cashInflowWithCreditDebt)
            #expect(try after.projection().registerBalances[seeded.fixture.accountID] == usd(80))
            let adjustmentID = try requireAdjustmentID(result)
            #expect(after.transactions[adjustmentID]?.effectiveAtEpoch == seeded.fixture.observedEpoch)
        }
    }

    @Test("the observed register cutoff pulls both legs of a complete transfer pair")
    func adjustmentUsesPairPulledTransferCutoff() async throws {
        try await withHarness { harness in
            let fixture = try await harness.service.transact(nowEpoch: testEpoch) { workspace in
                let checking = try workspace.addAccount(
                    name: "Checking",
                    type: .checking,
                    onBudget: true,
                    openingBalance: usd(100),
                    openingDate: date("2025-01-01"),
                    nowEpoch: testEpoch
                )
                let savings = try workspace.addAccount(
                    name: "Savings",
                    type: .savings,
                    onBudget: true,
                    openingBalance: usd(100),
                    openingDate: date("2025-01-01"),
                    nowEpoch: testEpoch
                )
                let outLeg = try workspace.addManualTransaction(
                    accountID: checking,
                    date: date("2025-01-10"),
                    payeeName: "Transfer",
                    categoryID: workspace.categoryID(named: "Groceries"),
                    amountMilliunits: -usd(50),
                    nowEpoch: testEpoch
                )
                let inLeg = try workspace.addManualTransaction(
                    accountID: savings,
                    date: date("2025-01-04"),
                    payeeName: "Transfer",
                    categoryID: workspace.rtaCategoryID,
                    amountMilliunits: usd(50),
                    nowEpoch: testEpoch
                )
                _ = try workspace.pairExistingTransactions(outLeg, inLeg, nowEpoch: testEpoch)

                let observedEpoch = try workspace.calendar.noonEpoch(of: date("2025-01-06"))
                let local = try workspace.registerBalanceAsOf(
                    accountID: checking,
                    epoch: observedEpoch
                )
                let discrepancy = SnapshotDiscrepancyRow(
                    budgetID: workspace.budget.id,
                    accountID: checking,
                    observedEpoch: observedEpoch,
                    remoteBalanceMilliunits: local + usd(5),
                    localRegisterMilliunits: local,
                    differenceMilliunits: usd(5),
                    createdAtEpoch: testEpoch
                )
                workspace.setSnapshotDiscrepancy(discrepancy)
                return DiscrepancyFixture(
                    accountID: checking,
                    discrepancyID: discrepancy.id,
                    version: SnapshotDiscrepancyVersion(discrepancy: discrepancy),
                    observedEpoch: observedEpoch,
                    localBalance: local,
                    remoteBalance: local + usd(5)
                )
            }
            #expect(fixture.localBalance == usd(50))

            let before = try harness.store.load(budgetID: harness.budgetID)
            let result = try await harness.service.resolveSnapshotDiscrepancy(
                command(harness: harness, fixture: fixture, choice: .adjustment),
                nowEpoch: try before.calendar.noonEpoch(of: date("2025-01-31"))
            )
            try assertResolvedAdjustment(
                harness: harness,
                fixture: fixture,
                result: result,
                accountType: .checking,
                expectedAmount: usd(5)
            )
            let after = try harness.store.load(budgetID: harness.budgetID)
            #expect(after.transferPairs == before.transferPairs)
            #expect(after.legSnapshots == before.legSnapshots)
        }
    }

    @Test("an adjustment cannot silently rehabilitate a pre-existing staged row")
    func adjustmentRejectsWhenReplayWouldResolvePreexistingStagedRow() async throws {
        try await withHarness { harness in
            let seeded = try await harness.service.transact(nowEpoch: testEpoch) { workspace in
                let card = try workspace.addAccount(
                    name: "Card",
                    type: .creditCard,
                    onBudget: true,
                    openingBalance: -usd(10),
                    openingDate: date("2025-01-02"),
                    nowEpoch: testEpoch
                )
                let futureAdjustmentID = try workspace.insertSystemAdjustmentTransaction(
                    accountID: card,
                    date: date("2025-01-20"),
                    effectiveAtEpoch: workspace.calendar.noonEpoch(of: date("2025-01-20")),
                    amountMilliunits: usd(20)
                )
                _ = try workspace.runReplayAndApplyDecisions()
                guard workspace.transactions[futureAdjustmentID]?.postingState == .staged,
                      workspace.transactions[futureAdjustmentID]?.stageReason == .cardBalanceWouldBecomePositive else {
                    throw FixtureError.expectedStagedRow
                }

                let observedEpoch = try workspace.calendar.noonEpoch(of: date("2025-01-10"))
                let local = try workspace.registerBalanceAsOf(accountID: card, epoch: observedEpoch)
                let discrepancy = SnapshotDiscrepancyRow(
                    budgetID: workspace.budget.id,
                    accountID: card,
                    observedEpoch: observedEpoch,
                    remoteBalanceMilliunits: local - usd(20),
                    localRegisterMilliunits: local,
                    differenceMilliunits: -usd(20),
                    createdAtEpoch: testEpoch
                )
                workspace.setSnapshotDiscrepancy(discrepancy)
                return (
                    fixture: DiscrepancyFixture(
                        accountID: card,
                        discrepancyID: discrepancy.id,
                        version: SnapshotDiscrepancyVersion(discrepancy: discrepancy),
                        observedEpoch: observedEpoch,
                        localBalance: local,
                        remoteBalance: local - usd(20)
                    ),
                    stagedID: futureAdjustmentID
                )
            }
            let before = try #require(await harness.service.currentSnapshot())
            let beforeBytes = try sortedSnapshotData(before)

            await #expect(throws: SyncResolutionError.dependencyInvalid) {
                try await harness.service.resolveSnapshotDiscrepancy(
                    command(harness: harness, fixture: seeded.fixture, choice: .adjustment),
                    nowEpoch: seeded.fixture.observedEpoch
                )
            }

            let after = try #require(await harness.service.currentSnapshot())
            #expect(after == before)
            #expect(try sortedSnapshotData(after) == beforeBytes)
            #expect(after.transactions.first { $0.id == seeded.stagedID }?.postingState == .staged)
            #expect(try harness.store.load(budgetID: harness.budgetID).snapshot() == before)
        }
    }

    @Test("manual attestation mutates no accounting state and writes only fixed audit metadata")
    func manualAttestationChangesOnlyDiscrepancyAuditAndRevision() async throws {
        try await withHarness { harness in
            let fixture = try await seedDiscrepancy(
                in: harness,
                accountType: .checking,
                openingBalance: usd(100),
                difference: usd(7)
            )
            let before = try harness.store.load(budgetID: harness.budgetID)
            let beforeSnapshot = before.snapshot()
            let command = command(
                harness: harness,
                fixture: fixture,
                choice: .manualAttestation(.confirmedWithoutAccountingAdjustment)
            )

            let result = try await harness.service.resolveSnapshotDiscrepancy(
                command,
                nowEpoch: try before.calendar.noonEpoch(of: date("2025-01-31"))
            )
            let after = try harness.store.load(budgetID: harness.budgetID)
            let resolved = try #require(after.snapshotDiscrepancies[fixture.discrepancyID])
            let audit = try #require(after.auditEvents.last)

            #expect(result.reason == .manualAttestation)
            #expect(result.artifact == .none)
            #expect(resolved.status == .resolved)
            #expect(resolved.resolutionReason == .manualAttestation)
            #expect(resolved.adjustmentTransactionID == nil)
            #expect(after.transactions == before.transactions)
            #expect(after.allocations == before.allocations)
            #expect(after.accounts == before.accounts)
            #expect(after.transferPairs == before.transferPairs)
            #expect(after.simpleFINImports == before.simpleFINImports)
            #expect(after.syncConflicts == before.syncConflicts)
            #expect(after.budget.nextLocalSourceSequence == before.budget.nextLocalSourceSequence)
            #expect(after.budget.revision == before.budget.revision + 1)
            #expect(after.auditEvents.count == beforeSnapshot.auditEvents.count + 1)
            #expect(audit.entityType == "snapshotDiscrepancy")
            #expect(audit.entityID == fixture.discrepancyID.description)
            #expect(audit.eventKind == "snapshotDiscrepancyResolved")
            #expect(audit.metadata == ["reason": "manualAttestation", "artifact": "none"])
            #expect(try ConservationCheck.compute(after, month: month("2025-01")).holds)
        }
    }

    @Test func successfulManualAttestationClearsMatchingLinkPauseAtomically() async throws {
        try await withHarness { harness in
            let fixture = try await seedDiscrepancy(
                in: harness,
                accountType: .checking,
                openingBalance: usd(100),
                difference: usd(-5)
            )
            let link = SimpleFINAccountLink(
                connectionKey: "conn:synthetic-connection",
                remoteAccountID: "remote-account",
                localAccountID: fixture.accountID,
                status: .paused,
                pauseReason: .snapshotDiscrepancy
            )
            let linkIdentity = link.identity
            try await harness.service.transact(nowEpoch: testEpoch) { workspace in
                var discrepancy = try #require(workspace.snapshotDiscrepancies[fixture.discrepancyID])
                discrepancy.simpleFINLinkIdentity = linkIdentity
                workspace.setSnapshotDiscrepancy(discrepancy)
            }
            _ = try await harness.service.updateSimpleFINState(nowEpoch: testEpoch) { state in
                var connection = SimpleFINConnectionState(
                    status: .active,
                    keychainItemID: "synthetic-item-reference",
                    baseHost: "bridge.simplefin.org",
                    basePort: 443,
                    credentialGeneration: 1,
                    createdAtEpoch: testEpoch
                )
                connection.upsertLink(link)
                state = connection
            }

            let result = try await harness.service.resolveSnapshotDiscrepancy(
                command(
                    harness: harness,
                    fixture: fixture,
                    choice: .manualAttestation(.confirmedWithoutAccountingAdjustment)
                ),
                nowEpoch: testEpoch + 1
            )
            #expect(result.reason == .manualAttestation)

            let state = try #require(await harness.service.simpleFINState())
            let resolvedLink = try #require(state.link(identity: linkIdentity))
            #expect(resolvedLink.status == .active)
            #expect(resolvedLink.pauseReason == nil)
        }
    }

    @Test func uniqueLegacyDiscrepancyInfersLinkAndClearsMatchingPause() async throws {
        try await withHarness { harness in
            let fixture = try await seedDiscrepancy(
                in: harness,
                accountType: .checking,
                openingBalance: usd(100),
                difference: usd(5)
            )
            let link = SimpleFINAccountLink(
                connectionKey: "conn:legacy-unique",
                remoteAccountID: "remote-legacy-unique",
                localAccountID: fixture.accountID,
                status: .paused,
                pauseReason: .snapshotDiscrepancy
            )
            let linkIdentity = link.identity
            _ = try await harness.service.updateSimpleFINState(nowEpoch: testEpoch) { state in
                state = SimpleFINConnectionState(
                    status: .active,
                    keychainItemID: "synthetic-item-reference",
                    baseHost: "bridge.simplefin.org",
                    basePort: 443,
                    credentialGeneration: 1,
                    createdAtEpoch: testEpoch,
                    links: [link]
                )
            }

            _ = try await harness.service.resolveSnapshotDiscrepancy(
                command(
                    harness: harness,
                    fixture: fixture,
                    choice: .manualAttestation(.confirmedWithoutAccountingAdjustment)
                ),
                nowEpoch: testEpoch + 1
            )

            let state = try #require(await harness.service.simpleFINState())
            let resolvedLink = try #require(state.link(identity: linkIdentity))
            #expect(resolvedLink.status == .active)
            #expect(resolvedLink.pauseReason == nil)
        }
    }

    @Test func ambiguousLegacyDiscrepancyIsRejectedByTheLinkInvariant() async throws {
        try await withHarness { harness in
            let fixture = try await seedDiscrepancy(
                in: harness,
                accountType: .checking,
                openingBalance: usd(100),
                difference: usd(5)
            )
            let first = SimpleFINAccountLink(
                connectionKey: "conn:first",
                remoteAccountID: "remote-first",
                localAccountID: fixture.accountID
            )
            let second = SimpleFINAccountLink(
                connectionKey: "conn:second",
                remoteAccountID: "remote-second",
                localAccountID: fixture.accountID
            )
            let beforeState = try await harness.service.simpleFINState()

            do {
                try await harness.service.updateSimpleFINState(nowEpoch: testEpoch) { state in
                    var connection = SimpleFINConnectionState(
                        status: .active,
                        keychainItemID: "synthetic-item-reference",
                        baseHost: "bridge.simplefin.org",
                        basePort: 443,
                        credentialGeneration: 1,
                        createdAtEpoch: testEpoch,
                        links: [first]
                    )
                    try connection.upsertLinkOrThrow(second)
                    state = connection
                }
                Issue.record("the duplicate local-account binding was accepted")
            } catch let error as SimpleFINLinkInvariantError {
                #expect(error == .localAccountAlreadyLinked)
            } catch {
                Issue.record("unexpected error: \(error)")
            }

            #expect(try await harness.service.simpleFINState() == beforeState)
            _ = fixture
        }
    }

    @Test func resolutionPreservesUnrelatedPauseAndDiagnosticState() async throws {
        try await withHarness { harness in
            let fixture = try await seedDiscrepancy(
                in: harness,
                accountType: .checking,
                openingBalance: usd(100),
                difference: usd(5)
            )
            let link = SimpleFINAccountLink(
                connectionKey: "conn:synthetic-connection",
                remoteAccountID: "remote-account",
                localAccountID: fixture.accountID,
                status: .paused,
                pauseReason: .protocolError,
                lastErrorRedacted: "synthetic provider diagnostic"
            )
            let linkIdentity = link.identity
            let diagnostic = link.lastErrorRedacted
            try await harness.service.transact(nowEpoch: testEpoch) { workspace in
                var discrepancy = try #require(workspace.snapshotDiscrepancies[fixture.discrepancyID])
                discrepancy.simpleFINLinkIdentity = linkIdentity
                workspace.setSnapshotDiscrepancy(discrepancy)
            }
            _ = try await harness.service.updateSimpleFINState(nowEpoch: testEpoch) { state in
                var connection = SimpleFINConnectionState(
                    status: .active,
                    keychainItemID: "synthetic-item-reference",
                    baseHost: "bridge.simplefin.org",
                    basePort: 443,
                    credentialGeneration: 1,
                    createdAtEpoch: testEpoch
                )
                connection.upsertLink(link)
                state = connection
            }

            _ = try await harness.service.resolveSnapshotDiscrepancy(
                command(
                    harness: harness,
                    fixture: fixture,
                    choice: .manualAttestation(.confirmedWithoutAccountingAdjustment)
                ),
                nowEpoch: testEpoch + 1
            )

            let state = try #require(await harness.service.simpleFINState())
            let preserved = try #require(state.link(identity: linkIdentity))
            #expect(preserved.status == .paused)
            #expect(preserved.pauseReason == .protocolError)
            #expect(preserved.lastErrorRedacted == diagnostic)
        }
    }

    @Test func resolutionDoesNotReactivateSnapshotLinkWhileConnectionIsDisconnected() async throws {
        try await withHarness { harness in
            let fixture = try await seedDiscrepancy(
                in: harness,
                accountType: .checking,
                openingBalance: usd(100),
                difference: usd(5)
            )
            let link = SimpleFINAccountLink(
                connectionKey: "conn:synthetic-connection",
                remoteAccountID: "remote-account",
                localAccountID: fixture.accountID,
                status: .paused,
                pauseReason: .snapshotDiscrepancy
            )
            let linkIdentity = link.identity
            try await harness.service.transact(nowEpoch: testEpoch) { workspace in
                var discrepancy = try #require(workspace.snapshotDiscrepancies[fixture.discrepancyID])
                discrepancy.simpleFINLinkIdentity = linkIdentity
                workspace.setSnapshotDiscrepancy(discrepancy)
            }
            _ = try await harness.service.updateSimpleFINState(nowEpoch: testEpoch) { state in
                state = SimpleFINConnectionState(
                    status: .disconnected,
                    keychainItemID: nil,
                    baseHost: "bridge.simplefin.org",
                    basePort: 443,
                    credentialGeneration: 1,
                    createdAtEpoch: testEpoch,
                    links: [link]
                )
            }

            _ = try await harness.service.resolveSnapshotDiscrepancy(
                command(
                    harness: harness,
                    fixture: fixture,
                    choice: .manualAttestation(.confirmedWithoutAccountingAdjustment)
                ),
                nowEpoch: testEpoch + 1
            )

            let state = try #require(await harness.service.simpleFINState())
            let preserved = try #require(state.link(identity: linkIdentity))
            #expect(state.status == .disconnected)
            #expect(preserved.status == .paused)
            #expect(preserved.pauseReason == nil)
            #expect(state.disconnectPausedLinkIdentities == [linkIdentity])
        }
    }

    @Test func resolutionKeepsLinkPausedWhileAnotherOpenDiscrepancyRemains() async throws {
        try await withHarness { harness in
            let fixture = try await seedDiscrepancy(
                in: harness,
                accountType: .checking,
                openingBalance: usd(100),
                difference: usd(5)
            )
            let link = SimpleFINAccountLink(
                connectionKey: "conn:synthetic-connection",
                remoteAccountID: "remote-account",
                localAccountID: fixture.accountID,
                status: .paused,
                pauseReason: .snapshotDiscrepancy
            )
            let linkIdentity = link.identity
            let secondDiscrepancyID = try await harness.service.transact(nowEpoch: testEpoch) { workspace in
                var first = try #require(workspace.snapshotDiscrepancies[fixture.discrepancyID])
                first.simpleFINLinkIdentity = linkIdentity
                workspace.setSnapshotDiscrepancy(first)
                let second = SnapshotDiscrepancyRow(
                    budgetID: workspace.budget.id,
                    accountID: fixture.accountID,
                    simpleFINLinkIdentity: linkIdentity,
                    observedEpoch: fixture.observedEpoch + 86_400,
                    remoteBalanceMilliunits: fixture.remoteBalance + usd(1),
                    localRegisterMilliunits: fixture.localBalance,
                    differenceMilliunits: usd(1),
                    createdAtEpoch: testEpoch
                )
                workspace.setSnapshotDiscrepancy(second)
                return second.id
            }
            _ = secondDiscrepancyID
            _ = try await harness.service.updateSimpleFINState(nowEpoch: testEpoch) { state in
                var connection = SimpleFINConnectionState(
                    status: .active,
                    keychainItemID: "synthetic-item-reference",
                    baseHost: "bridge.simplefin.org",
                    basePort: 443,
                    credentialGeneration: 1,
                    createdAtEpoch: testEpoch
                )
                connection.upsertLink(link)
                state = connection
            }

            _ = try await harness.service.resolveSnapshotDiscrepancy(
                command(
                    harness: harness,
                    fixture: fixture,
                    choice: .manualAttestation(.confirmedWithoutAccountingAdjustment)
                ),
                nowEpoch: testEpoch + 1
            )

            let state = try #require(await harness.service.simpleFINState())
            let preserved = try #require(state.link(identity: linkIdentity))
            #expect(preserved.status == .paused)
            #expect(preserved.pauseReason == .snapshotDiscrepancy)
        }
    }

    @Test("manual attestation is a closed Codable confirmation")
    func manualAttestationDecoderRejectsEmptyAndUnknownConfirmation() throws {
        let decoder = JSONDecoder()
        #expect(throws: DecodingError.self) {
            try decoder.decode(
                SnapshotDiscrepancyManualAttestation.self,
                from: Data(#"""#.utf8)
            )
        }
        #expect(throws: DecodingError.self) {
            try decoder.decode(
                SnapshotDiscrepancyManualAttestation.self,
                from: Data(#""guessed""#.utf8)
            )
        }
    }

    @Test("an adjustment cannot rewrite a completed reconciliation prefix")
    func adjustmentRejectsCompletedReconciliationPrefix() async throws {
        try await withHarness { harness in
            let fixture = try await harness.service.transact(nowEpoch: testEpoch) { workspace in
                let accountID = try workspace.addAccount(
                    name: "Reconciled Checking",
                    type: .checking,
                    onBudget: true,
                    openingBalance: usd(100),
                    openingDate: date("2025-01-02"),
                    nowEpoch: testEpoch
                )
                _ = try workspace.completeReconciliation(
                    accountID: accountID,
                    statementDate: date("2025-01-15"),
                    statementBalanceMilliunits: usd(100),
                    nowEpoch: testEpoch
                )
                let observedEpoch = try workspace.calendar.noonEpoch(of: date("2025-01-10"))
                let local = try workspace.registerBalanceAsOf(
                    accountID: accountID,
                    epoch: observedEpoch
                )
                let discrepancy = SnapshotDiscrepancyRow(
                    budgetID: workspace.budget.id,
                    accountID: accountID,
                    observedEpoch: observedEpoch,
                    remoteBalanceMilliunits: local + usd(10),
                    localRegisterMilliunits: local,
                    differenceMilliunits: usd(10),
                    createdAtEpoch: testEpoch
                )
                workspace.setSnapshotDiscrepancy(discrepancy)
                return DiscrepancyFixture(
                    accountID: accountID,
                    discrepancyID: discrepancy.id,
                    version: SnapshotDiscrepancyVersion(discrepancy: discrepancy),
                    observedEpoch: observedEpoch,
                    localBalance: local,
                    remoteBalance: local + usd(10)
                )
            }
            let before = try #require(await harness.service.currentSnapshot())
            let beforeBytes = try sortedSnapshotData(before)

            await #expect(throws: MutationError.reconciledTransaction) {
                try await harness.service.resolveSnapshotDiscrepancy(
                    command(harness: harness, fixture: fixture, choice: .adjustment),
                    nowEpoch: fixture.observedEpoch
                )
            }

            let after = try #require(await harness.service.currentSnapshot())
            #expect(after == before)
            #expect(try sortedSnapshotData(after) == beforeBytes)
            #expect(try harness.store.load(budgetID: harness.budgetID).snapshot() == before)
        }
    }

    @Test("legacy reconciliation membership without a statement cutoff blocks adjustment")
    func adjustmentRejectsLegacyReconciliationPrefixWithoutCutoff() async throws {
        try await withHarness { harness in
            let fixture = try await harness.service.transact(nowEpoch: testEpoch) { workspace in
                let accountID = try workspace.addAccount(
                    name: "Legacy Reconciled Checking",
                    type: .checking,
                    onBudget: true,
                    openingBalance: usd(100),
                    openingDate: date("2025-01-02"),
                    nowEpoch: testEpoch
                )
                let openingID = try #require(
                    workspace.transactions.values.first {
                        $0.accountID == accountID && $0.kind == .openingBalance
                    }?.id
                )
                var opening = try #require(workspace.transactions[openingID])
                opening.cleared = .reconciled
                workspace.setTransaction(opening)
                workspace.insertReconciliationMembership(openingID)
                #expect(workspace.reconciliations.isEmpty)

                let observedEpoch = try workspace.calendar.noonEpoch(of: date("2025-01-20"))
                let local = try workspace.registerBalanceAsOf(
                    accountID: accountID,
                    epoch: observedEpoch
                )
                let discrepancy = SnapshotDiscrepancyRow(
                    budgetID: workspace.budget.id,
                    accountID: accountID,
                    observedEpoch: observedEpoch,
                    remoteBalanceMilliunits: local + usd(10),
                    localRegisterMilliunits: local,
                    differenceMilliunits: usd(10),
                    createdAtEpoch: testEpoch
                )
                workspace.setSnapshotDiscrepancy(discrepancy)
                return DiscrepancyFixture(
                    accountID: accountID,
                    discrepancyID: discrepancy.id,
                    version: SnapshotDiscrepancyVersion(discrepancy: discrepancy),
                    observedEpoch: observedEpoch,
                    localBalance: local,
                    remoteBalance: local + usd(10)
                )
            }
            let before = try #require(await harness.service.currentSnapshot())
            let beforeBytes = try sortedSnapshotData(before)

            await #expect(throws: MutationError.reconciledTransaction) {
                try await harness.service.resolveSnapshotDiscrepancy(
                    command(harness: harness, fixture: fixture, choice: .adjustment),
                    nowEpoch: fixture.observedEpoch
                )
            }

            let after = try #require(await harness.service.currentSnapshot())
            #expect(after == before)
            #expect(try sortedSnapshotData(after) == beforeBytes)
            #expect(try harness.store.load(budgetID: harness.budgetID).snapshot() == before)
        }
    }

    @Test("closed month, closed account, and ineligible accounts reject adjustments unchanged")
    func adjustmentRejectsClosedAndIneligibleAccountStates() async throws {
        try await withHarness { harness in
            let fixture = try await seedDiscrepancy(
                in: harness,
                accountType: .checking,
                openingBalance: usd(100),
                difference: usd(10),
                closedObservedMonth: true
            )
            let before = try #require(await harness.service.currentSnapshot())
            await #expect(throws: MutationError.closedMonth) {
                try await harness.service.resolveSnapshotDiscrepancy(
                    command(harness: harness, fixture: fixture, choice: .adjustment),
                    nowEpoch: fixture.observedEpoch
                )
            }
            #expect(await harness.service.currentSnapshot() == before)
        }

        try await withHarness { harness in
            let fixture = try await seedDiscrepancy(
                in: harness,
                accountType: .checking,
                openingBalance: usd(100),
                difference: usd(10),
                closed: true
            )
            let before = try #require(await harness.service.currentSnapshot())
            await #expect(throws: MutationError.accountClosed) {
                try await harness.service.resolveSnapshotDiscrepancy(
                    command(harness: harness, fixture: fixture, choice: .adjustment),
                    nowEpoch: fixture.observedEpoch
                )
            }
            #expect(await harness.service.currentSnapshot() == before)
        }

        for accountType in [AccountType.checking, .other] {
            try await withHarness { harness in
                let fixture = try await seedDiscrepancy(
                    in: harness,
                    accountType: accountType,
                    openingBalance: usd(100),
                    difference: usd(10),
                    onBudget: false
                )
                let before = try #require(await harness.service.currentSnapshot())
                await #expect(throws: MutationError.reconciliationInvalid) {
                    try await harness.service.resolveSnapshotDiscrepancy(
                        command(harness: harness, fixture: fixture, choice: .adjustment),
                        nowEpoch: fixture.observedEpoch
                    )
                }
                #expect(await harness.service.currentSnapshot() == before)
                #expect(try harness.store.load(budgetID: harness.budgetID).snapshot() == before)
            }
        }
    }

    @Test("a changed observed prefix and a missing account reject without partial state")
    func staleRegisterPrefixAndMissingAccountAreTypedNoOps() async throws {
        try await withHarness { harness in
            let fixture = try await seedDiscrepancy(
                in: harness,
                accountType: .checking,
                openingBalance: usd(100),
                difference: usd(10)
            )
            _ = try await harness.service.transact(nowEpoch: testEpoch) { workspace in
                try workspace.addManualTransaction(
                    accountID: fixture.accountID,
                    date: date("2025-01-05"),
                    payeeName: "Prefix Change",
                    categoryID: workspace.categoryID(named: "Groceries"),
                    amountMilliunits: -usd(1),
                    nowEpoch: testEpoch
                )
            }
            let before = try #require(await harness.service.currentSnapshot())
            let beforeBytes = try sortedSnapshotData(before)
            await #expect(throws: SyncResolutionError.staleRequest) {
                try await harness.service.resolveSnapshotDiscrepancy(
                    command(harness: harness, fixture: fixture, choice: .adjustment),
                    nowEpoch: fixture.observedEpoch
                )
            }
            let after = try #require(await harness.service.currentSnapshot())
            #expect(after == before)
            #expect(try sortedSnapshotData(after) == beforeBytes)
        }

        try await withHarness { harness in
            let loaded = try harness.store.load(budgetID: harness.budgetID)
            let observedEpoch = try loaded.calendar.noonEpoch(of: date("2025-01-10"))
            let discrepancy = SnapshotDiscrepancyRow(
                budgetID: harness.budgetID,
                accountID: AccountID(),
                observedEpoch: observedEpoch,
                remoteBalanceMilliunits: usd(1),
                localRegisterMilliunits: 0,
                differenceMilliunits: usd(1),
                createdAtEpoch: testEpoch
            )
            var corruptedSnapshot = loaded.snapshot()
            corruptedSnapshot.snapshotDiscrepancies.append(discrepancy)
            corruptedSnapshot.snapshotDiscrepancies.sort { $0.id < $1.id }
            let corruptedPayload = try sortedSnapshotData(corruptedSnapshot)
            try await harness.store.pool.write { db in
                try db.execute(
                    sql: "UPDATE workspace_states SET payload = ? WHERE budget_id = ?",
                    arguments: [corruptedPayload, harness.budgetID.description]
                )
            }

            // A malformed legacy/corrupted payload can bypass the normalized
            // foreign key. Loading must fail closed before any command can
            // reach a write instead of relying solely on SQLite integrity.
            let coldService = BudgetMutationService(store: harness.store)
            await #expect(throws: LedgerPersistenceError.invalidSnapshot) {
                _ = try await coldService.load(budgetID: harness.budgetID)
            }
            #expect(throws: LedgerPersistenceError.invalidSnapshot) {
                _ = try harness.store.load(budgetID: harness.budgetID)
            }
            let payloadAfter = try await harness.store.pool.read { db in
                try Data.fetchOne(
                    db,
                    sql: "SELECT payload FROM workspace_states WHERE budget_id = ?",
                    arguments: [harness.budgetID.description]
                )
            }
            #expect(payloadAfter == corruptedPayload)
        }
    }

    @Test("stale, cross-budget, and malformed discrepancy commands reject without mutation")
    func staleCrossBudgetAndMalformedRequestsAreTypedNoOps() async throws {
        try await withHarness { harness in
            let fixture = try await seedDiscrepancy(
                in: harness,
                accountType: .checking,
                openingBalance: usd(100),
                difference: usd(10)
            )
            let before = try #require(await harness.service.currentSnapshot())
            let beforeBytes = try sortedSnapshotData(before)

            let staleVersion = SnapshotDiscrepancyVersion(
                observedEpoch: fixture.version.observedEpoch,
                remoteBalanceMilliunits: fixture.version.remoteBalanceMilliunits,
                localRegisterMilliunits: fixture.version.localRegisterMilliunits,
                differenceMilliunits: fixture.version.differenceMilliunits + 1
            )
            await #expect(throws: SyncResolutionError.staleRequest) {
                try await harness.service.resolveSnapshotDiscrepancy(
                    SnapshotDiscrepancyResolutionCommand(
                        budgetID: harness.budgetID,
                        discrepancyID: fixture.discrepancyID,
                        expectedVersion: staleVersion,
                        choice: .adjustment
                    ),
                    nowEpoch: fixture.observedEpoch
                )
            }
            await #expect(throws: SyncResolutionError.budgetMismatch) {
                try await harness.service.resolveSnapshotDiscrepancy(
                    SnapshotDiscrepancyResolutionCommand(
                        budgetID: BudgetID(),
                        discrepancyID: fixture.discrepancyID,
                        expectedVersion: fixture.version,
                        choice: .adjustment
                    ),
                    nowEpoch: fixture.observedEpoch
                )
            }
            let after = try #require(await harness.service.currentSnapshot())
            #expect(after == before)
            #expect(try sortedSnapshotData(after) == beforeBytes)
        }

        try await withHarness { harness in
            let malformed = try await seedDiscrepancy(
                in: harness,
                accountType: .checking,
                openingBalance: usd(100),
                difference: usd(10),
                storedDifference: usd(9)
            )
            let before = try #require(await harness.service.currentSnapshot())
            await #expect(throws: SyncResolutionError.malformedDiscrepancy) {
                try await harness.service.resolveSnapshotDiscrepancy(
                    command(harness: harness, fixture: malformed, choice: .adjustment),
                    nowEpoch: malformed.observedEpoch
                )
            }
            #expect(await harness.service.currentSnapshot() == before)
        }
    }

    @Test("terminal retries are typed no-ops")
    func resolvedDiscrepancyRetryIsTypedNoOp() async throws {
        try await withHarness { harness in
            let fixture = try await seedDiscrepancy(
                in: harness,
                accountType: .checking,
                openingBalance: usd(100),
                difference: usd(10)
            )
            let command = command(
                harness: harness,
                fixture: fixture,
                choice: .manualAttestation(.confirmedWithoutAccountingAdjustment)
            )
            _ = try await harness.service.resolveSnapshotDiscrepancy(
                command,
                nowEpoch: fixture.observedEpoch
            )
            let beforeRetry = try #require(await harness.service.currentSnapshot())
            let beforeBytes = try sortedSnapshotData(beforeRetry)

            await #expect(throws: SyncResolutionError.discrepancyNotOpen) {
                try await harness.service.resolveSnapshotDiscrepancy(
                    command,
                    nowEpoch: fixture.observedEpoch + 1
                )
            }

            let afterRetry = try #require(await harness.service.currentSnapshot())
            #expect(afterRetry == beforeRetry)
            #expect(try sortedSnapshotData(afterRetry) == beforeBytes)
            #expect(try harness.store.load(budgetID: harness.budgetID).snapshot() == beforeRetry)
        }
    }

    @Test("different link identities never retarget an open discrepancy")
    func openDiscrepancyIsScopedToLinkIdentity() async throws {
        try await withHarness { harness in
            let fixture = try await seedDiscrepancy(
                in: harness,
                accountType: .checking,
                openingBalance: usd(100),
                difference: usd(10)
            )
            let firstIdentity = SimpleFINAccountLink(
                connectionKey: "conn:first",
                remoteAccountID: "remote:first",
                localAccountID: fixture.accountID
            ).identity
            let secondIdentity = SimpleFINAccountLink(
                connectionKey: "conn:second",
                remoteAccountID: "remote:second",
                localAccountID: fixture.accountID
            ).identity

            let firstID = try await harness.service.transact(nowEpoch: testEpoch) { workspace in
                try workspace.upsertOpenSnapshotDiscrepancy(
                    accountID: fixture.accountID,
                    simpleFINLinkIdentity: firstIdentity,
                    observedEpoch: fixture.observedEpoch,
                    remoteBalanceMilliunits: fixture.remoteBalance,
                    localRegisterMilliunits: fixture.localBalance,
                    nowEpoch: testEpoch
                )
            }
            let secondID = try await harness.service.transact(nowEpoch: testEpoch + 1) { workspace in
                try workspace.upsertOpenSnapshotDiscrepancy(
                    accountID: fixture.accountID,
                    simpleFINLinkIdentity: secondIdentity,
                    observedEpoch: fixture.observedEpoch,
                    remoteBalanceMilliunits: fixture.remoteBalance,
                    localRegisterMilliunits: fixture.localBalance,
                    nowEpoch: testEpoch + 1
                )
            }

            let first = try #require(firstID)
            let second = try #require(secondID)
            #expect(first != second)
            let snapshot = try #require(await harness.service.currentSnapshot())
            #expect(snapshot.snapshotDiscrepancies.first { $0.id == first }?.simpleFINLinkIdentity == firstIdentity)
            #expect(snapshot.snapshotDiscrepancies.first { $0.id == second }?.simpleFINLinkIdentity == secondIdentity)
        }
    }

    @Test("an exact resolved observation is suppressed while later facts may open a new row")
    func exactResolvedObservationIsSuppressed() async throws {
        try await withHarness { harness in
            let fixture = try await seedDiscrepancy(
                in: harness,
                accountType: .checking,
                openingBalance: usd(100),
                difference: usd(10)
            )
            _ = try await harness.service.resolveSnapshotDiscrepancy(
                command(
                    harness: harness,
                    fixture: fixture,
                    choice: .manualAttestation(.confirmedWithoutAccountingAdjustment)
                ),
                nowEpoch: fixture.observedEpoch
            )
            let resolvedSnapshot = try #require(await harness.service.currentSnapshot())

            let duplicateID = try await harness.service.transact(nowEpoch: fixture.observedEpoch + 1) { workspace in
                try workspace.upsertOpenSnapshotDiscrepancy(
                    accountID: fixture.accountID,
                    observedEpoch: fixture.observedEpoch,
                    remoteBalanceMilliunits: fixture.remoteBalance,
                    localRegisterMilliunits: fixture.localBalance,
                    nowEpoch: fixture.observedEpoch + 1
                )
            }
            #expect(duplicateID == nil)
            #expect(await harness.service.currentSnapshot() == resolvedSnapshot)

            let laterID = try await harness.service.transact(nowEpoch: fixture.observedEpoch + 2) { workspace in
                try workspace.upsertOpenSnapshotDiscrepancy(
                    accountID: fixture.accountID,
                    observedEpoch: fixture.observedEpoch + 1,
                    remoteBalanceMilliunits: fixture.remoteBalance,
                    localRegisterMilliunits: fixture.localBalance,
                    nowEpoch: fixture.observedEpoch + 2
                )
            }
            #expect(laterID != nil)
            let afterLater = try #require(await harness.service.currentSnapshot())
            #expect(afterLater.snapshotDiscrepancies.count == 2)
            #expect(afterLater.snapshotDiscrepancies.contains { $0.id == laterID && $0.status == .open })

            let revertedID = try await harness.service.transact(
                nowEpoch: fixture.observedEpoch + 3
            ) { workspace in
                try workspace.upsertOpenSnapshotDiscrepancy(
                    accountID: fixture.accountID,
                    observedEpoch: fixture.observedEpoch,
                    remoteBalanceMilliunits: fixture.remoteBalance,
                    localRegisterMilliunits: fixture.localBalance,
                    nowEpoch: fixture.observedEpoch + 3
                )
            }
            #expect(revertedID == laterID)
            let afterRevert = try #require(await harness.service.currentSnapshot())
            let currentOpen = try #require(
                afterRevert.snapshotDiscrepancies.first { $0.id == laterID }
            )
            #expect(currentOpen.status == .open)
            #expect(currentOpen.observedEpoch == fixture.observedEpoch)
            #expect(currentOpen.remoteBalanceMilliunits == fixture.remoteBalance)
            #expect(currentOpen.localRegisterMilliunits == fixture.localBalance)
        }
    }

    @Test("account-closed/off-budget resolution fails closed without its linked card state")
    func accountClosedOffBudgetRequiresLinkedCardState() async throws {
        try await withHarness { harness in
            let fixture = try await seedDiscrepancy(
                in: harness,
                accountType: .checking,
                openingBalance: usd(100),
                difference: usd(10)
            )
            let before = try #require(await harness.service.currentSnapshot())
            let beforeBytes = try sortedSnapshotData(before)

            await #expect(throws: SyncResolutionError.missingReference) {
                try await harness.service.resolveSnapshotDiscrepancy(
                    command(harness: harness, fixture: fixture, choice: .accountClosedOffBudget),
                    nowEpoch: fixture.observedEpoch
                )
            }

            let after = try #require(await harness.service.currentSnapshot())
            #expect(after == before)
            #expect(try sortedSnapshotData(after) == beforeBytes)
            #expect(try harness.store.load(budgetID: harness.budgetID).snapshot() == before)
        }
    }

    @Test("a database failure rolls back adjustment, discrepancy, audit, and actor state")
    func databaseFailureRollsBackEveryDiscrepancyMutation() async throws {
        try await withHarness { harness in
            let fixture = try await seedDiscrepancy(
                in: harness,
                accountType: .checking,
                openingBalance: usd(100),
                difference: usd(10)
            )
            let link = SimpleFINAccountLink(
                connectionKey: "conn:synthetic-connection",
                remoteAccountID: "remote-account",
                localAccountID: fixture.accountID,
                status: .paused,
                pauseReason: .snapshotDiscrepancy
            )
            try await harness.service.transact(nowEpoch: testEpoch) { workspace in
                var discrepancy = try #require(workspace.snapshotDiscrepancies[fixture.discrepancyID])
                discrepancy.simpleFINLinkIdentity = link.identity
                workspace.setSnapshotDiscrepancy(discrepancy)
            }
            _ = try await harness.service.updateSimpleFINState(nowEpoch: testEpoch) { state in
                var connection = SimpleFINConnectionState(
                    status: .active,
                    keychainItemID: "synthetic-item-reference",
                    baseHost: "bridge.simplefin.org",
                    basePort: 443,
                    credentialGeneration: 1,
                    createdAtEpoch: testEpoch
                )
                connection.upsertLink(link)
                state = connection
            }
            let before = try #require(await harness.service.currentSnapshot())
            let beforeState = try #require(await harness.service.simpleFINState())
            let beforeBytes: Data = try await harness.store.pool.read { db in
                guard let payload = try Data.fetchOne(
                    db,
                    sql: "SELECT payload FROM workspace_states WHERE budget_id = ?",
                    arguments: [harness.budgetID.description]
                ) else {
                    throw FixtureError.missingWorkspacePayload
                }
                return payload
            }
            try await harness.store.pool.write { db in
                try db.execute(sql: """
                    CREATE TRIGGER reject_snapshot_resolution_audit
                    BEFORE INSERT ON audit_events
                    WHEN NEW.event_kind = 'snapshotDiscrepancyResolved'
                    BEGIN
                        SELECT RAISE(ABORT, 'synthetic rollback');
                    END
                    """)
            }

            var sawDatabaseFailure = false
            do {
                _ = try await harness.service.resolveSnapshotDiscrepancy(
                    command(harness: harness, fixture: fixture, choice: .adjustment),
                    nowEpoch: fixture.observedEpoch
                )
                Issue.record("database trigger did not reject discrepancy resolution")
            } catch is DatabaseError {
                sawDatabaseFailure = true
            } catch {
                Issue.record("resolution failed before reaching the synthetic database trigger: \(error)")
            }

            let actorAfter = try #require(await harness.service.currentSnapshot())
            let coldAfter = try harness.store.load(budgetID: harness.budgetID).snapshot()
            let payloadAfter: Data = try await harness.store.pool.read { db in
                guard let payload = try Data.fetchOne(
                    db,
                    sql: "SELECT payload FROM workspace_states WHERE budget_id = ?",
                    arguments: [harness.budgetID.description]
                ) else {
                    throw FixtureError.missingWorkspacePayload
                }
                return payload
            }
            #expect(actorAfter == before)
            #expect(coldAfter == before)
            #expect(payloadAfter == beforeBytes)
            #expect(sawDatabaseFailure)
            #expect(coldAfter.transactions == before.transactions)
            #expect(coldAfter.snapshotDiscrepancies == before.snapshotDiscrepancies)
            #expect(coldAfter.auditEvents == before.auditEvents)
            #expect(try await harness.service.simpleFINState() == beforeState)
        }
    }

    @Test("positive card discrepancy migrates atomically to an off-budget successor")
    func positiveCardUsesOffBudgetSuccessorWorkflow() async throws {
        try await withHarness { harness in
            let fixture = try await seedDiscrepancy(
                in: harness,
                accountType: .creditCard,
                openingBalance: -usd(100),
                difference: usd(150)
            )
            let link = SimpleFINAccountLink(
                connectionKey: "institution",
                remoteAccountID: "remote-card",
                localAccountID: fixture.accountID,
                status: .paused,
                pauseReason: .positiveCardSnapshot
            )
            try await harness.service.transact(nowEpoch: testEpoch) { workspace in
                var discrepancy = try #require(workspace.snapshotDiscrepancies[fixture.discrepancyID])
                discrepancy.simpleFINLinkIdentity = link.identity
                workspace.setSnapshotDiscrepancy(discrepancy)
            }
            _ = try await harness.service.updateSimpleFINState(nowEpoch: testEpoch) { state in
                var connection = SimpleFINConnectionState(
                    status: .active,
                    keychainItemID: "synthetic-item-reference",
                    baseHost: "bridge.simplefin.org",
                    basePort: 443,
                    credentialGeneration: 1,
                    createdAtEpoch: testEpoch
                )
                connection.upsertLink(link)
                state = connection
            }

            let before = try harness.store.load(budgetID: harness.budgetID)
            let result = try await harness.service.resolveSnapshotDiscrepancy(
                command(harness: harness, fixture: fixture, choice: .accountClosedOffBudget),
                nowEpoch: try before.calendar.noonEpoch(of: date("2025-01-31"))
            )
            guard case .offBudgetSuccessor(let successorID) = result.artifact else {
                throw FixtureError.expectedAdjustment
            }

            let after = try harness.store.load(budgetID: harness.budgetID)
            let oldAccount = try #require(after.accounts[fixture.accountID])
            let successor = try #require(after.accounts[successorID])
            let anchor = try #require(after.transactions.values.first {
                $0.accountID == successorID && $0.kind == .openingBalance
            })
            let state = try #require(await harness.service.simpleFINState())
            let migratedLink = try #require(state.links.first { $0.identity == link.identity })
            let discrepancy = try #require(after.snapshotDiscrepancies[fixture.discrepancyID])

            #expect(result.reason == .accountClosedOffBudget)
            #expect(oldAccount.closed)
            #expect(oldAccount.onBudget)
            #expect(successor.onBudget == false)
            #expect(successor.type == .creditCard)
            #expect(anchor.amountMilliunits == fixture.remoteBalance)
            #expect(anchor.effectiveAtEpoch == fixture.observedEpoch)
            #expect(after.transactions.values.filter { $0.accountID == fixture.accountID }.count == 1)
            #expect(migratedLink.localAccountID == successorID)
            #expect(migratedLink.status == .active)
            #expect(migratedLink.pauseReason == nil)
            #expect(discrepancy.status == .resolved)
            #expect(discrepancy.resolutionReason == .accountClosedOffBudget)
            #expect(discrepancy.adjustmentTransactionID == nil)
        }
    }

    @Test("ordinary account close requires a settled register and no pending rows")
    func ordinaryAccountCloseUsesActivityGuard() async throws {
        try await withHarness { harness in
            let settledID = try await harness.service.transact(nowEpoch: testEpoch) { workspace in
                try workspace.addAccount(
                    name: "Settled",
                    type: .checking,
                    onBudget: true,
                    openingBalance: 0,
                    openingDate: date("2025-01-02"),
                    nowEpoch: testEpoch
                )
            }
            try await harness.service.transact(nowEpoch: testEpoch) { workspace in
                try workspace.closeAccount(accountID: settledID, nowEpoch: testEpoch)
            }
            #expect(try harness.store.load(budgetID: harness.budgetID).accounts[settledID]?.closed == true)

            let activeID = try await harness.service.transact(nowEpoch: testEpoch) { workspace in
                try workspace.addAccount(
                    name: "Active",
                    type: .checking,
                    onBudget: true,
                    openingBalance: usd(1),
                    openingDate: date("2025-01-02"),
                    nowEpoch: testEpoch
                )
            }
            await #expect(throws: MutationError.accountHasActivity) {
                try await harness.service.transact(nowEpoch: testEpoch) { workspace in
                    try workspace.closeAccount(accountID: activeID, nowEpoch: testEpoch)
                }
            }
        }
    }
}

import Foundation
import GRDB
import Testing
@testable import LedgerCore

@Suite("M5.9 sync-conflict resolution")
struct SyncConflictResolutionTests {
    private enum FixtureError: Error {
        case missingSnapshot
    }

    private enum RemoteProtection: Sendable {
        case none
        case approved
        case userEdited
        case posted
        case staged
        case reconciled
        case closedMonth
        case linkedRefund
        case dependentRefund
        case transferLinked
    }

    private enum DuplicateTarget: Sendable, Equatable {
        case manual
        case imported
    }

    private enum DestructiveProtection: Sendable, Equatable {
        case closedMonth
        case reconciled
        case refundDependent
        case transferLinked
    }

    private struct ImportedSeed: Sendable {
        var budgetID: BudgetID
        var accountID: AccountID
        var transactionID: TransactionID
        var importID: SimpleFINImportID
        var conflictID: SyncConflictID
        var revision: Int64
        var oldHash: String
        var newHash: String?
        var newAmount: Milliunits?
        var newPostedEpoch: Int64?
    }

    private struct DuplicateSeed: Sendable {
        var budgetID: BudgetID
        var manualTransactionID: TransactionID
        var importedTransactionID: TransactionID
        var importID: SimpleFINImportID
        var conflictID: SyncConflictID
        var revision: Int64
    }

    private func epoch(day offset: Int64) -> Int64 {
        testEpoch + offset * 86_400
    }

    private func makeService() async throws -> (directory: URL, service: BudgetMutationService) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledgerbar-m59-conflict-\(UUID().uuidString)", isDirectory: true)
        let store = try LedgerWorkspaceStore(
            databaseURL: directory.appendingPathComponent("LedgerBar.sqlite")
        )
        let service = BudgetMutationService(store: store)
        _ = try await service.createBudget(
            name: "Synthetic conflict budget",
            currency: "USD",
            timeZoneIdentifier: "UTC",
            firstMonth: month("2025-01"),
            currentMonth: month("2025-01"),
            nowEpoch: testEpoch
        )
        return (directory, service)
    }

    private func workspace(_ service: BudgetMutationService) async throws -> BudgetWorkspace {
        guard let snapshot = await service.currentSnapshot() else {
            throw FixtureError.missingSnapshot
        }
        return try BudgetWorkspace(snapshot: snapshot)
    }

    private func assertConservation(
        _ service: BudgetMutationService,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let current = try await workspace(service)
        #expect(
            try ConservationCheck.compute(current, month: month("2025-01")).holds,
            sourceLocation: sourceLocation
        )
    }

    private func remoteHash(
        remoteTransactionID: String,
        amount: String,
        postedEpoch: Int64,
        transactedEpoch: Int64? = nil,
        payee: String?,
        description: String?
    ) throws -> String {
        try SimpleFINPayloadHash.canonicalHash(
            remoteTransactionID: remoteTransactionID,
            transaction: SimpleFINRemoteTransaction(
                id: remoteTransactionID,
                amount: amount,
                postedEpoch: postedEpoch,
                transactedAtEpoch: transactedEpoch,
                description: description,
                payee: payee,
                pending: false
            )
        )
    }

    private func installConnectionState(
        service: BudgetMutationService,
        accountID: AccountID,
        signNormalization: SimpleFINSignNormalization = .normal
    ) async throws {
        _ = try await service.updateSimpleFINState(nowEpoch: epoch(day: 8)) { state in
            state = SimpleFINConnectionState(
                status: .active,
                keychainItemID: "synthetic-item-reference",
                baseHost: "bridge.simplefin.org",
                basePort: 443,
                credentialGeneration: 1,
                createdAtEpoch: testEpoch,
                links: [SimpleFINAccountLink(
                    connectionKey: "conn:synthetic",
                    remoteAccountID: "remote-account",
                    localAccountID: accountID,
                    signNormalization: signNormalization,
                    lastSuccessfulPostedEpoch: self.epoch(day: 7)
                )]
            )
        }
    }

    private func seedImportedConflict(
        service: BudgetMutationService,
        kind: SyncConflictKind,
        protection: RemoteProtection = .none,
        malformedImportReference: Bool = false
    ) async throws -> ImportedSeed {
        let linkedRefund = if case .linkedRefund = protection { true } else { false }
        let oldRawAmount = linkedRefund ? "10.00" : "-10.00"
        let oldAmount = linkedRefund ? usd(10) : usd(-10)
        let newRawAmount = linkedRefund ? "12.00" : "-12.00"
        let newAmount = linkedRefund ? usd(12) : usd(-12)
        let oldPosted = epoch(day: 2)
        let oldTransacted = epoch(day: 1)
        let newPosted = epoch(day: 3)
        let newTransacted = epoch(day: 2)
        let oldHash = try remoteHash(
            remoteTransactionID: "remote-transaction",
            amount: oldRawAmount,
            postedEpoch: oldPosted,
            transactedEpoch: oldTransacted,
            payee: "Original payee",
            description: "Original description"
        )
        let newHash: String? = if kind == .remoteChanged {
            try remoteHash(
                remoteTransactionID: "remote-transaction",
                amount: newRawAmount,
                postedEpoch: newPosted,
                transactedEpoch: newTransacted,
                payee: "Updated payee",
                description: "Updated description"
            )
        } else {
            nil
        }

        let seed = try await service.transact(nowEpoch: epoch(day: 8)) { workspace in
            let accountID = try workspace.addAccount(
                name: "Checking",
                type: .checking,
                onBudget: true,
                openingBalance: usd(100),
                openingDate: date("2025-01-01"),
                nowEpoch: testEpoch
            )
            let transactionID = try workspace.importPostedTransaction(
                accountID: accountID,
                connectionKey: "conn:synthetic",
                remoteAccountID: "remote-account",
                remoteTransactionID: "remote-transaction",
                postedEpoch: oldPosted,
                payeeName: "Original payee",
                amountMilliunits: oldAmount,
                memo: "Original description",
                remoteAmountDecimalString: oldRawAmount,
                remoteTransactedEpoch: oldTransacted,
                remotePayloadHash: oldHash,
                nowEpoch: self.epoch(day: 7)
            )

            switch protection {
            case .none:
                break
            case .approved:
                try workspace.setApproved(
                    transactionID: transactionID,
                    approved: true,
                    nowEpoch: self.epoch(day: 7)
                )
            case .userEdited:
                try workspace.categorize(
                    transactionID: transactionID,
                    categoryID: workspace.categoryID(named: "Groceries"),
                    nowEpoch: self.epoch(day: 7)
                )
            case .posted:
                try workspace.categorize(
                    transactionID: transactionID,
                    categoryID: workspace.categoryID(named: "Groceries"),
                    nowEpoch: self.epoch(day: 7)
                )
                var row = try #require(workspace.transactions[transactionID])
                row.userEditedAtEpoch = nil
                workspace.setTransaction(row)
            case .staged:
                var row = try #require(workspace.transactions[transactionID])
                row.postingState = .staged
                row.stageReason = .closedMonthImport
                row.stageMetadata = StageMetadata(proposedCategoryID: workspace.uncategorizedID)
                row.categoryID = nil
                workspace.setTransaction(row)
            case .reconciled:
                try workspace.categorize(
                    transactionID: transactionID,
                    categoryID: workspace.categoryID(named: "Groceries"),
                    nowEpoch: self.epoch(day: 7)
                )
                try workspace.setCleared(
                    transactionID: transactionID,
                    cleared: .cleared,
                    nowEpoch: self.epoch(day: 7)
                )
                _ = try workspace.completeReconciliation(
                    accountID: accountID,
                    statementDate: date("2025-01-03"),
                    statementBalanceMilliunits: usd(90),
                    nowEpoch: self.epoch(day: 7)
                )
            case .closedMonth:
                try workspace.advanceObservedMonth(to: month("2025-02"))
                try workspace.closeMonth(month("2025-01"), nowEpoch: self.epoch(day: 7))
            case .linkedRefund:
                let originID = try workspace.addManualTransaction(
                    accountID: accountID,
                    date: date("2025-01-02"),
                    payeeName: "Refund origin",
                    categoryID: workspace.categoryID(named: "Groceries"),
                    amountMilliunits: usd(-20),
                    nowEpoch: self.epoch(day: 7)
                )
                try workspace.classifyAsCashReimbursement(
                    transactionID,
                    categoryID: workspace.categoryID(named: "Groceries"),
                    originID: originID,
                    nowEpoch: self.epoch(day: 7)
                )
            case .dependentRefund:
                let groceries = workspace.categoryID(named: "Groceries")
                try workspace.categorize(
                    transactionID: transactionID,
                    categoryID: groceries,
                    nowEpoch: self.epoch(day: 7)
                )
                let dependentID = try workspace.addManualTransaction(
                    accountID: accountID,
                    date: date("2025-01-04"),
                    payeeName: "Dependent refund",
                    categoryID: groceries,
                    amountMilliunits: usd(5),
                    kind: .refund,
                    refundOf: transactionID,
                    nowEpoch: self.epoch(day: 7)
                )
                var dependent = try #require(workspace.transactions[dependentID])
                workspace.removeTransaction(dependentID)
                dependent.id = TransactionID(
                    UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")!
                )
                workspace.setTransaction(dependent)
                _ = try workspace.runReplayAndApplyDecisions()
            case .transferLinked:
                let destinationID = try workspace.addAccount(
                    name: "Transfer destination",
                    type: .checking,
                    onBudget: true,
                    openingBalance: 0,
                    openingDate: date("2025-01-01"),
                    nowEpoch: self.epoch(day: 7)
                )
                let counterpartID = try workspace.addManualTransaction(
                    accountID: destinationID,
                    date: date("2025-01-03"),
                    payeeName: "Transfer counterpart",
                    categoryID: workspace.rtaCategoryID,
                    amountMilliunits: usd(10),
                    nowEpoch: self.epoch(day: 7)
                )
                _ = try workspace.pairExistingTransactions(
                    transactionID,
                    counterpartID,
                    nowEpoch: self.epoch(day: 7)
                )
            }

            let record = try #require(workspace.simpleFINImports[transactionID])
            let conflictImportID: SimpleFINImportID
            if malformedImportReference {
                let unrelatedTransactionID = try workspace.importPostedTransaction(
                    accountID: accountID,
                    connectionKey: "conn:synthetic",
                    remoteAccountID: "remote-account",
                    remoteTransactionID: "unrelated-remote-transaction",
                    postedEpoch: self.epoch(day: 4),
                    payeeName: "Unrelated payee",
                    amountMilliunits: usd(-1),
                    nowEpoch: self.epoch(day: 7)
                )
                conflictImportID = try #require(
                    workspace.simpleFINImports[unrelatedTransactionID]
                ).id
            } else {
                conflictImportID = record.id
            }
            let conflict = SyncConflictRow(
                budgetID: workspace.budget.id,
                transactionID: transactionID,
                simpleFINImportID: conflictImportID,
                eventKind: kind,
                oldMetadata: SyncConflictMetadata(
                    amountDecimalString: record.remoteAmountDecimalString,
                    postedEpoch: record.remotePostedEpoch,
                    transactedEpoch: record.remoteTransactedEpoch,
                    date: "2025-01-03",
                    payeeDisplay: "Original payee",
                    descriptionText: "Original description",
                    payloadHash: record.remotePayloadHash,
                    note: "Stored baseline"
                ),
                newMetadata: kind == .remoteChanged
                    ? SyncConflictMetadata(
                        amountDecimalString: newRawAmount,
                        postedEpoch: newPosted,
                        transactedEpoch: newTransacted,
                        date: "2025-01-04",
                        payeeDisplay: "Updated payee",
                        descriptionText: "Updated description",
                        payloadHash: newHash,
                        note: "Incoming observation"
                    )
                    : SyncConflictMetadata(note: "Remote identity absent"),
                createdAtEpoch: self.epoch(day: 8)
            )
            workspace.setSyncConflict(conflict)
            return ImportedSeed(
                budgetID: workspace.budget.id,
                accountID: accountID,
                transactionID: transactionID,
                importID: record.id,
                conflictID: conflict.id,
                revision: workspace.budget.revision,
                oldHash: oldHash,
                newHash: newHash,
                newAmount: kind == .remoteChanged ? newAmount : nil,
                newPostedEpoch: kind == .remoteChanged ? newPosted : nil
            )
        }
        try await installConnectionState(service: service, accountID: seed.accountID)
        return seed
    }

    private func seedManualDuplicate(
        service: BudgetMutationService,
        protectedTarget: DuplicateTarget? = nil,
        protection: DestructiveProtection? = nil
    ) async throws -> DuplicateSeed {
        try await service.transact(nowEpoch: epoch(day: 8)) { workspace in
            let accountID = try workspace.addAccount(
                name: "Checking",
                type: .checking,
                onBudget: true,
                openingBalance: usd(100),
                openingDate: date("2025-01-01"),
                nowEpoch: testEpoch
            )
            let manualID = try workspace.addManualTransaction(
                accountID: accountID,
                date: date("2025-01-03"),
                payeeName: "Manual payee",
                categoryID: workspace.categoryID(named: "Groceries"),
                amountMilliunits: usd(-10),
                nowEpoch: self.epoch(day: 7)
            )
            let importedID = try workspace.importPostedTransaction(
                accountID: accountID,
                connectionKey: "conn:synthetic",
                remoteAccountID: "remote-account",
                remoteTransactionID: "duplicate-remote-transaction",
                postedEpoch: self.epoch(day: 2),
                payeeName: "Imported payee",
                amountMilliunits: usd(-10),
                nowEpoch: self.epoch(day: 7)
            )
            let record = try #require(workspace.simpleFINImports[importedID])
            if let protectedTarget, let protection {
                let targetID = protectedTarget == .manual ? manualID : importedID
                switch protection {
                case .closedMonth:
                    try workspace.advanceObservedMonth(to: month("2025-02"))
                    try workspace.closeMonth(month("2025-01"), nowEpoch: self.epoch(day: 7))
                case .reconciled:
                    if protectedTarget == .imported {
                        try workspace.categorize(
                            transactionID: targetID,
                            categoryID: workspace.categoryID(named: "Groceries"),
                            nowEpoch: self.epoch(day: 7)
                        )
                    }
                    try workspace.setCleared(
                        transactionID: targetID,
                        cleared: .cleared,
                        nowEpoch: self.epoch(day: 7)
                    )
                    _ = try workspace.completeReconciliation(
                        accountID: accountID,
                        statementDate: date("2025-01-03"),
                        statementBalanceMilliunits: usd(90),
                        nowEpoch: self.epoch(day: 7)
                    )
                case .refundDependent:
                    let groceries = workspace.categoryID(named: "Groceries")
                    if protectedTarget == .imported {
                        try workspace.categorize(
                            transactionID: targetID,
                            categoryID: groceries,
                            nowEpoch: self.epoch(day: 7)
                        )
                    }
                    let dependentID = try workspace.addManualTransaction(
                        accountID: accountID,
                        date: date("2025-01-04"),
                        payeeName: "Dependent refund",
                        categoryID: groceries,
                        amountMilliunits: usd(5),
                        kind: .refund,
                        refundOf: targetID,
                        nowEpoch: self.epoch(day: 7)
                    )
                    var dependent = try #require(workspace.transactions[dependentID])
                    workspace.removeTransaction(dependentID)
                    dependent.id = TransactionID(
                        UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")!
                    )
                    workspace.setTransaction(dependent)
                    _ = try workspace.runReplayAndApplyDecisions()
                case .transferLinked:
                    let destinationID = try workspace.addAccount(
                        name: "Transfer destination",
                        type: .checking,
                        onBudget: true,
                        openingBalance: 0,
                        openingDate: date("2025-01-01"),
                        nowEpoch: self.epoch(day: 7)
                    )
                    let counterpartID = try workspace.addManualTransaction(
                        accountID: destinationID,
                        date: date("2025-01-03"),
                        payeeName: "Transfer counterpart",
                        categoryID: workspace.rtaCategoryID,
                        amountMilliunits: usd(10),
                        nowEpoch: self.epoch(day: 7)
                    )
                    _ = try workspace.pairExistingTransactions(
                        targetID,
                        counterpartID,
                        nowEpoch: self.epoch(day: 7)
                    )
                }
            }
            let conflict = SyncConflictRow(
                budgetID: workspace.budget.id,
                transactionID: manualID,
                simpleFINImportID: record.id,
                eventKind: .manualPotentialDuplicate,
                oldMetadata: SyncConflictMetadata(
                    date: "2025-01-03",
                    payeeDisplay: "Manual payee",
                    note: "Manual candidate"
                ),
                newMetadata: SyncConflictMetadata(
                    amountDecimalString: record.remoteAmountDecimalString,
                    postedEpoch: record.remotePostedEpoch,
                    payloadHash: record.remotePayloadHash,
                    note: "Imported candidate"
                ),
                createdAtEpoch: self.epoch(day: 8)
            )
            workspace.setSyncConflict(conflict)
            return DuplicateSeed(
                budgetID: workspace.budget.id,
                manualTransactionID: manualID,
                importedTransactionID: importedID,
                importID: record.id,
                conflictID: conflict.id,
                revision: workspace.budget.revision
            )
        }
    }

    private func seedInvertedCardConflict(
        service: BudgetMutationService
    ) async throws -> ImportedSeed {
        let oldPosted = epoch(day: 2)
        let newPosted = epoch(day: 3)
        let oldHash = try remoteHash(
            remoteTransactionID: "card-remote-transaction",
            amount: "10.00",
            postedEpoch: oldPosted,
            payee: "Original card payee",
            description: nil
        )
        let newHash = try remoteHash(
            remoteTransactionID: "card-remote-transaction",
            amount: "12.00",
            postedEpoch: newPosted,
            payee: "Updated card payee",
            description: nil
        )
        let seed = try await service.transact(nowEpoch: epoch(day: 8)) { workspace in
            let accountID = try workspace.addAccount(
                name: "Credit card",
                type: .creditCard,
                onBudget: true,
                openingBalance: usd(-100),
                openingDate: date("2025-01-01"),
                nowEpoch: testEpoch
            )
            let transactionID = try workspace.importPostedTransaction(
                accountID: accountID,
                connectionKey: "conn:synthetic",
                remoteAccountID: "remote-account",
                remoteTransactionID: "card-remote-transaction",
                postedEpoch: oldPosted,
                payeeName: "Original card payee",
                amountMilliunits: usd(-10),
                remoteAmountDecimalString: "10.00",
                remotePayloadHash: oldHash,
                nowEpoch: self.epoch(day: 7)
            )
            let record = try #require(workspace.simpleFINImports[transactionID])
            let conflict = SyncConflictRow(
                budgetID: workspace.budget.id,
                transactionID: transactionID,
                simpleFINImportID: record.id,
                eventKind: .remoteChanged,
                oldMetadata: SyncConflictMetadata(
                    amountDecimalString: "10.00",
                    postedEpoch: oldPosted,
                    payeeDisplay: "Original card payee",
                    payloadHash: oldHash
                ),
                newMetadata: SyncConflictMetadata(
                    amountDecimalString: "12.00",
                    postedEpoch: newPosted,
                    payeeDisplay: "Updated card payee",
                    payloadHash: newHash
                ),
                createdAtEpoch: self.epoch(day: 8)
            )
            workspace.setSyncConflict(conflict)
            return ImportedSeed(
                budgetID: workspace.budget.id,
                accountID: accountID,
                transactionID: transactionID,
                importID: record.id,
                conflictID: conflict.id,
                revision: workspace.budget.revision,
                oldHash: oldHash,
                newHash: newHash,
                newAmount: usd(-12),
                newPostedEpoch: newPosted
            )
        }
        try await installConnectionState(
            service: service,
            accountID: seed.accountID,
            signNormalization: .inverted
        )
        return seed
    }

    private func command(
        _ seed: ImportedSeed,
        choice: SyncConflictResolutionChoice,
        budgetID: BudgetID? = nil,
        revision: Int64? = nil,
        expectedTransactionFingerprint: String? = nil
    ) -> SyncConflictResolutionCommand {
        SyncConflictResolutionCommand(
            budgetID: budgetID ?? seed.budgetID,
            conflictID: seed.conflictID,
            expectedBudgetRevision: revision ?? seed.revision,
            expectedTransactionFingerprint: expectedTransactionFingerprint,
            choice: choice
        )
    }

    private func command(
        _ seed: DuplicateSeed,
        choice: ManualPotentialDuplicateResolution
    ) -> SyncConflictResolutionCommand {
        SyncConflictResolutionCommand(
            budgetID: seed.budgetID,
            conflictID: seed.conflictID,
            expectedBudgetRevision: seed.revision,
            choice: .manualPotentialDuplicate(choice)
        )
    }

    @Test func remoteChangedKeepLocalPreservesOwnedRowAndAdvancesBaseline() async throws {
        let fixture = try await makeService()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let seed = try await seedImportedConflict(
            service: fixture.service,
            kind: .remoteChanged,
            protection: .userEdited
        )
        let before = try await workspace(fixture.service)
        let localBefore = try #require(before.transactions[seed.transactionID])
        let conflictBefore = try #require(before.syncConflicts[seed.conflictID])

        let result = try await fixture.service.resolveSyncConflict(
            command(seed, choice: .remoteChanged(.keepLocal)),
            nowEpoch: epoch(day: 9)
        )
        let after = try await workspace(fixture.service)
        let record = try #require(after.simpleFINImports[seed.transactionID])

        #expect(result.action == .remoteChangedKeepLocal)
        #expect(result.status == .resolved)
        #expect(result.affectedTransactionIDs.isEmpty)
        #expect(after.transactions[seed.transactionID] == localBefore)
        #expect(record.remoteAmountDecimalString == "-12.00")
        #expect(record.remotePostedEpoch == seed.newPostedEpoch)
        #expect(record.remotePayloadHash == seed.newHash)
        #expect(after.syncConflicts[seed.conflictID]?.oldMetadata == conflictBefore.oldMetadata)
        #expect(after.syncConflicts[seed.conflictID]?.newMetadata == conflictBefore.newMetadata)

        let conflictsBeforeRepeat = after.syncConflicts.count
        let repeatedResponse = try SimpleFINAccountsResponse(accounts: [
            SimpleFINRemoteAccount(
                id: "remote-account",
                name: "Synthetic account",
                currency: "USD",
                balance: "0.00",
                connectionID: "synthetic",
                transactions: [SimpleFINRemoteTransaction(
                    id: "remote-transaction",
                    amount: "-12.00",
                    postedEpoch: try #require(seed.newPostedEpoch),
                    transactedAtEpoch: epoch(day: 2),
                    description: "Updated description",
                    payee: "Updated payee"
                )]
            )
        ])
        let repeatedOutcome = try await fixture.service.syncTransact(
            nowEpoch: epoch(day: 10)
        ) { workspace, state in
            var current = try #require(state)
            var link = try #require(current.links.first)
            let outcome = try SimpleFINSyncEngine.applyAccountSync(
                response: repeatedResponse,
                link: &link,
                window: .recurring(requestStartEpoch: self.epoch(day: 1)),
                workspace: &workspace,
                nowEpoch: self.epoch(day: 10)
            )
            current.upsertLink(link)
            state = current
            return outcome
        }
        let repeated = try await workspace(fixture.service)
        #expect(repeatedOutcome.conflictIDs.isEmpty)
        #expect(repeated.syncConflicts.count == conflictsBeforeRepeat)
        #expect(repeated.transactions[seed.transactionID] == localBefore)
        try await assertConservation(fixture.service)
    }

    @Test func remoteChangedAcceptRemoteUpdatesEligibleRowAndBaseline() async throws {
        let fixture = try await makeService()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let seed = try await seedImportedConflict(service: fixture.service, kind: .remoteChanged)

        let result = try await fixture.service.resolveSyncConflict(
            command(seed, choice: .remoteChanged(.acceptRemote)),
            nowEpoch: epoch(day: 9)
        )
        let after = try await workspace(fixture.service)
        let row = try #require(after.transactions[seed.transactionID])
        let record = try #require(after.simpleFINImports[seed.transactionID])

        #expect(result.action == .remoteChangedAcceptRemote)
        #expect(result.affectedTransactionIDs == [seed.transactionID])
        #expect(row.amountMilliunits == seed.newAmount)
        #expect(row.effectiveAtEpoch == seed.newPostedEpoch)
        #expect(row.date == date("2025-01-04"))
        #expect(row.memo == "Updated description")
        #expect(row.postingState == .needsCategory)
        #expect(record.remoteAmountDecimalString == "-12.00")
        #expect(record.remotePostedEpoch == seed.newPostedEpoch)
        #expect(record.remotePayloadHash == seed.newHash)
        try await assertConservation(fixture.service)
    }

    @Test func remoteChangedAcceptRemoteHonorsStoredInvertedCardNormalization() async throws {
        let fixture = try await makeService()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let seed = try await seedInvertedCardConflict(service: fixture.service)

        _ = try await fixture.service.resolveSyncConflict(
            command(seed, choice: .remoteChanged(.acceptRemote)),
            nowEpoch: epoch(day: 9)
        )
        let after = try await workspace(fixture.service)

        #expect(after.transactions[seed.transactionID]?.amountMilliunits == usd(-12))
        #expect(after.simpleFINImports[seed.transactionID]?.remoteAmountDecimalString == "12.00")
        #expect(after.simpleFINImports[seed.transactionID]?.remotePayloadHash == seed.newHash)
        try await assertConservation(fixture.service)
    }

    @Test func remoteChangedAcceptRejectsProtectedRowsWithoutMutation() async throws {
        for protection in [
            RemoteProtection.approved,
            .userEdited,
            .posted,
            .staged,
            .reconciled,
            .closedMonth,
            .linkedRefund,
            .dependentRefund,
            .transferLinked
        ] {
            let fixture = try await makeService()
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let seed = try await seedImportedConflict(
                service: fixture.service,
                kind: .remoteChanged,
                protection: protection
            )
            let before = try #require(await fixture.service.currentSnapshot())

            do {
                _ = try await fixture.service.resolveSyncConflict(
                    command(seed, choice: .remoteChanged(.acceptRemote)),
                    nowEpoch: self.epoch(day: 9)
                )
                Issue.record("protected remote row was overwritten")
            } catch {
                switch protection {
                case .approved, .userEdited, .posted, .staged, .reconciled:
                    #expect(error as? MutationError == .transactionImmutable)
                case .closedMonth:
                    #expect(error as? MutationError == .closedMonth)
                case .linkedRefund:
                    #expect(error as? SyncResolutionError == .dependencyInvalid)
                case .dependentRefund:
                    #expect(error as? MutationError == .transactionHasDependents)
                case .transferLinked:
                    #expect(error as? MutationError == .transferLegsInvalid)
                case .none:
                    Issue.record("unprotected case entered protected-row matrix")
                }
            }
            #expect(await fixture.service.currentSnapshot() == before)
        }
    }

    @Test func remoteDisappearedKeepRetainsRowAndAcknowledgesAbsence() async throws {
        let fixture = try await makeService()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let seed = try await seedImportedConflict(service: fixture.service, kind: .remoteDisappeared)
        let before = try await workspace(fixture.service)
        let rowBefore = before.transactions[seed.transactionID]

        let result = try await fixture.service.resolveSyncConflict(
            command(seed, choice: .remoteDisappeared(.keepLocal)),
            nowEpoch: epoch(day: 9)
        )
        let after = try await workspace(fixture.service)

        #expect(result.action == .remoteDisappearedKeepLocal)
        #expect(result.affectedTransactionIDs.isEmpty)
        #expect(after.transactions[seed.transactionID] == rowBefore)
        #expect(after.simpleFINImports[seed.transactionID]?.remoteDisappearanceAcknowledged == true)
        #expect(after.syncConflicts[seed.conflictID]?.status == .resolved)
        try await assertConservation(fixture.service)
    }

    @Test func remoteDisappearedEditUsesExistingMutationRulesAtomically() async throws {
        let fixture = try await makeService()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let seed = try await seedImportedConflict(service: fixture.service, kind: .remoteDisappeared)
        let before = try await workspace(fixture.service)
        let groceries = before.categoryID(named: "Groceries")

        let result = try await fixture.service.resolveSyncConflict(
            command(
                seed,
                choice: .remoteDisappeared(.editLocal([
                    .cleared(.cleared),
                    .memo("Reviewed locally"),
                    .category(groceries),
                    .date(date("2025-01-05")),
                    .approval(true)
                ]))
            ),
            nowEpoch: epoch(day: 9)
        )
        let after = try await workspace(fixture.service)
        let row = try #require(after.transactions[seed.transactionID])

        #expect(result.action == .remoteDisappearedEditLocal)
        #expect(result.affectedTransactionIDs == [seed.transactionID])
        #expect(row.date == date("2025-01-05"))
        #expect(row.categoryID == groceries)
        #expect(row.memo == "Reviewed locally")
        #expect(row.approved)
        #expect(row.cleared == .cleared)
        #expect(row.postingState == .posted)
        #expect(after.simpleFINImports[seed.transactionID]?.remoteDisappearanceAcknowledged == true)
        try await assertConservation(fixture.service)
    }

    @Test func remoteDisappearedSoftVoidPreservesImportTombstoneAndDedupIdentity() async throws {
        let fixture = try await makeService()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let seed = try await seedImportedConflict(service: fixture.service, kind: .remoteDisappeared)

        let result = try await fixture.service.resolveSyncConflict(
            command(seed, choice: .remoteDisappeared(.softVoidImported)),
            nowEpoch: epoch(day: 9)
        )
        let after = try await workspace(fixture.service)
        let record = try #require(after.simpleFINImports[seed.transactionID])

        #expect(result.action == .remoteDisappearedSoftVoidImported)
        #expect(after.transactions[seed.transactionID]?.postingState == .voided)
        #expect(record.id == seed.importID)
        #expect(record.transactionID == seed.transactionID)
        #expect(record.remoteDisappearanceAcknowledged)
        #expect(after.importedTransactionID(
            connectionKey: record.connectionKey,
            remoteAccountID: record.remoteAccountID,
            remoteTransactionID: record.remoteTransactionID
        ) == seed.transactionID)
        try await assertConservation(fixture.service)
    }

    @Test func remoteDisappearedSoftVoidRejectsProtectedDependenciesWithoutMutation() async throws {
        for protection in [
            RemoteProtection.closedMonth,
            .reconciled,
            .linkedRefund,
            .dependentRefund,
            .transferLinked
        ] {
            let fixture = try await makeService()
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let seed = try await seedImportedConflict(
                service: fixture.service,
                kind: .remoteDisappeared,
                protection: protection
            )
            let before = try #require(await fixture.service.currentSnapshot())

            do {
                _ = try await fixture.service.resolveSyncConflict(
                    command(seed, choice: .remoteDisappeared(.softVoidImported)),
                    nowEpoch: self.epoch(day: 9)
                )
                Issue.record("protected disappeared row was voided")
            } catch {
                switch protection {
                case .closedMonth:
                    #expect(error as? MutationError == .closedMonth)
                case .reconciled:
                    #expect(error as? MutationError == .reconciledTransaction)
                case .linkedRefund:
                    #expect(error as? SyncResolutionError == .dependencyInvalid)
                case .dependentRefund:
                    #expect(error as? MutationError == .transactionHasDependents)
                case .transferLinked:
                    #expect(error as? MutationError == .transferLegsInvalid)
                default:
                    Issue.record("unexpected disappearance protection case")
                }
            }
            #expect(await fixture.service.currentSnapshot() == before)
        }
    }

    @Test func manualPotentialDuplicateKeepBothDoesNotMergeOrPair() async throws {
        let fixture = try await makeService()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let seed = try await seedManualDuplicate(service: fixture.service)

        let result = try await fixture.service.resolveSyncConflict(
            command(seed, choice: .keepBoth),
            nowEpoch: epoch(day: 9)
        )
        let after = try await workspace(fixture.service)

        #expect(result.action == .manualPotentialDuplicateKeepBoth)
        #expect(result.affectedTransactionIDs.isEmpty)
        #expect(after.transactions[seed.manualTransactionID] != nil)
        #expect(after.transactions[seed.importedTransactionID] != nil)
        #expect(seed.manualTransactionID != seed.importedTransactionID)
        #expect(after.transferPairs.isEmpty)

        let duplicateID = try await fixture.service.transact(nowEpoch: epoch(day: 10)) { workspace in
            workspace.recordSyncConflictIfNew(
                transactionID: seed.manualTransactionID,
                simpleFINImportID: seed.importID,
                eventKind: .manualPotentialDuplicate,
                oldMetadata: SyncConflictMetadata(note: "Repeated manual candidate"),
                newMetadata: SyncConflictMetadata(note: "Repeated imported candidate"),
                nowEpoch: self.epoch(day: 10)
            )
        }
        #expect(duplicateID == nil)
        let afterRepeat = try await workspace(fixture.service)
        #expect(afterRepeat.syncConflicts.count == after.syncConflicts.count)
        try await assertConservation(fixture.service)
    }

    @Test func manualPotentialDuplicateSoftVoidImportedPreservesManualAndImportIdentity() async throws {
        let fixture = try await makeService()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let seed = try await seedManualDuplicate(service: fixture.service)

        let result = try await fixture.service.resolveSyncConflict(
            command(seed, choice: .softVoidImported),
            nowEpoch: epoch(day: 9)
        )
        let after = try await workspace(fixture.service)

        #expect(result.action == .manualPotentialDuplicateSoftVoidImported)
        #expect(after.transactions[seed.manualTransactionID]?.postingState == .posted)
        #expect(after.transactions[seed.importedTransactionID]?.postingState == .voided)
        #expect(after.simpleFINImports[seed.importedTransactionID]?.id == seed.importID)
        #expect(after.transferPairs.isEmpty)
        try await assertConservation(fixture.service)
    }

    @Test func manualPotentialDuplicateDeleteManualPreservesImportedRow() async throws {
        let fixture = try await makeService()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let seed = try await seedManualDuplicate(service: fixture.service)

        let result = try await fixture.service.resolveSyncConflict(
            command(seed, choice: .deleteManual),
            nowEpoch: epoch(day: 9)
        )
        let after = try await workspace(fixture.service)

        #expect(result.action == .manualPotentialDuplicateDeleteManual)
        #expect(after.transactions[seed.manualTransactionID] == nil)
        #expect(after.transactions[seed.importedTransactionID]?.postingState == .needsCategory)
        #expect(after.simpleFINImports[seed.importedTransactionID]?.id == seed.importID)
        #expect(after.transferPairs.isEmpty)
        try await assertConservation(fixture.service)
    }

    @Test func manualPotentialDuplicateRejectsStaleCandidateAfterEitherRowWasRemoved() async throws {
        for voidImported in [true, false] {
            let fixture = try await makeService()
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let seed = try await seedManualDuplicate(service: fixture.service)
            _ = try await fixture.service.transact(nowEpoch: epoch(day: 9)) { workspace in
                try workspace.deleteTransaction(
                    voidImported ? seed.importedTransactionID : seed.manualTransactionID,
                    nowEpoch: self.epoch(day: 9)
                )
            }
            let before = try #require(await fixture.service.currentSnapshot())
            let choice: ManualPotentialDuplicateResolution = voidImported
                ? .deleteManual
                : .softVoidImported

            do {
                _ = try await fixture.service.resolveSyncConflict(
                    SyncConflictResolutionCommand(
                        budgetID: seed.budgetID,
                        conflictID: seed.conflictID,
                        expectedBudgetRevision: before.budget.revision,
                        choice: .manualPotentialDuplicate(choice)
                    ),
                    nowEpoch: self.epoch(day: 10)
                )
                Issue.record("stale duplicate candidate was destructively resolved")
            } catch {
                #expect(
                    error as? SyncResolutionError
                        == (voidImported ? .staleRequest : .missingReference)
                )
            }

            #expect(await fixture.service.currentSnapshot() == before)
            #expect(before.syncConflicts.first { $0.id == seed.conflictID }?.status == .open)
            if voidImported {
                #expect(before.transactions.first { $0.id == seed.manualTransactionID } != nil)
                #expect(
                    before.transactions.first { $0.id == seed.importedTransactionID }?.postingState
                        == .voided
                )
            } else {
                #expect(before.transactions.first { $0.id == seed.manualTransactionID } == nil)
                #expect(before.transactions.first { $0.id == seed.importedTransactionID } != nil)
            }
        }
    }

    @Test func manualPotentialDuplicateDestructiveChoicesRejectDependenciesWithoutMutation() async throws {
        for target in [DuplicateTarget.imported, .manual] {
            for protection in [
                DestructiveProtection.closedMonth,
                .reconciled,
                .refundDependent,
                .transferLinked
            ] {
                let fixture = try await makeService()
                defer { try? FileManager.default.removeItem(at: fixture.directory) }
                let seed = try await seedManualDuplicate(
                    service: fixture.service,
                    protectedTarget: target,
                    protection: protection
                )
                let before = try #require(await fixture.service.currentSnapshot())
                let choice: ManualPotentialDuplicateResolution = target == .imported
                    ? .softVoidImported
                    : .deleteManual

                do {
                    _ = try await fixture.service.resolveSyncConflict(
                        command(seed, choice: choice),
                        nowEpoch: self.epoch(day: 9)
                    )
                    Issue.record("dependency-protected duplicate row was destructively resolved")
                } catch {
                    switch protection {
                    case .closedMonth:
                        #expect(error as? MutationError == .closedMonth)
                    case .reconciled:
                        #expect(error as? MutationError == .reconciledTransaction)
                    case .refundDependent:
                        #expect(error as? MutationError == .transactionHasDependents)
                    case .transferLinked:
                        #expect(error as? MutationError == .transferLegsInvalid)
                    }
                }
                #expect(await fixture.service.currentSnapshot() == before)
            }
        }
    }

    @Test func conflictResolutionRejectsStaleCrossBudgetAndTerminalRequestsWithoutMutation() async throws {
        let fixture = try await makeService()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let seed = try await seedImportedConflict(service: fixture.service, kind: .remoteChanged)
        var before = try #require(await fixture.service.currentSnapshot())

        await #expect(throws: SyncResolutionError.staleRequest) {
            _ = try await fixture.service.resolveSyncConflict(
                command(
                    seed,
                    choice: .remoteChanged(.keepLocal),
                    revision: seed.revision - 1
                ),
                nowEpoch: self.epoch(day: 9)
            )
        }
        #expect(await fixture.service.currentSnapshot() == before)

        await #expect(throws: SyncResolutionError.budgetMismatch) {
            _ = try await fixture.service.resolveSyncConflict(
                command(
                    seed,
                    choice: .remoteChanged(.keepLocal),
                    budgetID: BudgetID()
                ),
                nowEpoch: self.epoch(day: 9)
            )
        }
        #expect(await fixture.service.currentSnapshot() == before)

        _ = try await fixture.service.resolveSyncConflict(
            command(seed, choice: .remoteChanged(.keepLocal)),
            nowEpoch: epoch(day: 9)
        )
        before = try #require(await fixture.service.currentSnapshot())
        await #expect(throws: SyncResolutionError.conflictNotOpen) {
            _ = try await fixture.service.resolveSyncConflict(
                command(seed, choice: .remoteChanged(.keepLocal)),
                nowEpoch: self.epoch(day: 10)
            )
        }
        #expect(await fixture.service.currentSnapshot() == before)
    }

    @Test func disappearedEditRejectsAnInterveningTransactionChange() async throws {
        let fixture = try await makeService()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let seed = try await seedImportedConflict(service: fixture.service, kind: .remoteDisappeared)
        let displayed = try #require(await fixture.service.currentSnapshot()?.transactions.first(where: { $0.id == seed.transactionID }))

        _ = try await fixture.service.transact(nowEpoch: epoch(day: 9)) { workspace in
            var row = try #require(workspace.transactions[seed.transactionID])
            row.memo = "Changed after review sheet opened"
            workspace.setTransaction(row)
        }
        let current = try #require(await fixture.service.currentSnapshot())

        await #expect(throws: SyncResolutionError.staleRequest) {
            _ = try await fixture.service.resolveSyncConflict(
                SyncConflictResolutionCommand(
                    budgetID: seed.budgetID,
                    conflictID: seed.conflictID,
                    expectedBudgetRevision: current.budget.revision,
                    expectedTransactionFingerprint: displayed.accountingFingerprint,
                    choice: .remoteDisappeared(.editLocal([.memo("Stale review edit")]))
                ),
                nowEpoch: self.epoch(day: 10)
            )
        }
        #expect(await fixture.service.currentSnapshot() == current)
    }

    @Test func conflictResolutionRejectsWrongKindAndInvalidEditShapesWithoutMutation() async throws {
        let changedFixture = try await makeService()
        defer { try? FileManager.default.removeItem(at: changedFixture.directory) }
        let changedSeed = try await seedImportedConflict(
            service: changedFixture.service,
            kind: .remoteChanged
        )
        let changedBefore = try #require(await changedFixture.service.currentSnapshot())
        await #expect(throws: SyncResolutionError.resolutionKindMismatch) {
            _ = try await changedFixture.service.resolveSyncConflict(
                command(changedSeed, choice: .remoteDisappeared(.keepLocal)),
                nowEpoch: self.epoch(day: 9)
            )
        }
        #expect(await changedFixture.service.currentSnapshot() == changedBefore)

        let disappearedFixture = try await makeService()
        defer { try? FileManager.default.removeItem(at: disappearedFixture.directory) }
        let disappearedSeed = try await seedImportedConflict(
            service: disappearedFixture.service,
            kind: .remoteDisappeared
        )
        let disappearedBefore = try #require(await disappearedFixture.service.currentSnapshot())
        await #expect(throws: SyncResolutionError.invalidEdit) {
            _ = try await disappearedFixture.service.resolveSyncConflict(
                command(disappearedSeed, choice: .remoteDisappeared(.editLocal([]))),
                nowEpoch: self.epoch(day: 9)
            )
        }
        await #expect(throws: SyncResolutionError.invalidEdit) {
            _ = try await disappearedFixture.service.resolveSyncConflict(
                command(
                    disappearedSeed,
                    choice: .remoteDisappeared(.editLocal([
                        .memo("First local memo"),
                        .memo("Second local memo")
                    ]))
                ),
                nowEpoch: self.epoch(day: 9)
            )
        }
        #expect(await disappearedFixture.service.currentSnapshot() == disappearedBefore)
    }

    @Test func malformedConflictReferenceIsRejectedWithoutMutation() async throws {
        let fixture = try await makeService()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let seed = try await seedImportedConflict(
            service: fixture.service,
            kind: .remoteChanged,
            malformedImportReference: true
        )
        let before = try #require(await fixture.service.currentSnapshot())

        await #expect(throws: SyncResolutionError.malformedConflict) {
            _ = try await fixture.service.resolveSyncConflict(
                command(seed, choice: .remoteChanged(.keepLocal)),
                nowEpoch: self.epoch(day: 9)
            )
        }
        #expect(await fixture.service.currentSnapshot() == before)
    }

    @Test func malformedRemoteHashAndUnverifiableLegacyTransactedEpochAreRejected() async throws {
        for removeOldTransactedEpoch in [false, true] {
            let fixture = try await makeService()
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let seed = try await seedImportedConflict(
                service: fixture.service,
                kind: .remoteChanged
            )
            _ = try await fixture.service.transact(nowEpoch: epoch(day: 8)) { workspace in
                var conflict = try #require(workspace.syncConflicts[seed.conflictID])
                if removeOldTransactedEpoch {
                    conflict.oldMetadata.transactedEpoch = nil
                } else {
                    conflict.newMetadata.payloadHash = "not-a-canonical-payload-hash"
                }
                workspace.setSyncConflict(conflict)
            }
            let before = try #require(await fixture.service.currentSnapshot())

            await #expect(throws: SyncResolutionError.malformedConflict) {
                _ = try await fixture.service.resolveSyncConflict(
                    SyncConflictResolutionCommand(
                        budgetID: seed.budgetID,
                        conflictID: seed.conflictID,
                        expectedBudgetRevision: before.budget.revision,
                        choice: .remoteChanged(.keepLocal)
                    ),
                    nowEpoch: self.epoch(day: 9)
                )
            }

            #expect(await fixture.service.currentSnapshot() == before)
        }
    }

    @Test func conflictResolutionAuditIsFixedBoundedAndSanitized() async throws {
        let fixture = try await makeService()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let seed = try await seedImportedConflict(service: fixture.service, kind: .remoteChanged)

        _ = try await fixture.service.resolveSyncConflict(
            command(seed, choice: .remoteChanged(.keepLocal)),
            nowEpoch: epoch(day: 9)
        )
        let after = try await workspace(fixture.service)
        let audit = try #require(after.auditEvents.last { $0.eventKind == "syncConflictResolved" })

        #expect(audit.entityType == "syncConflict")
        #expect(audit.entityID == seed.conflictID.description)
        #expect(audit.metadata == [
            "kind": SyncConflictKind.remoteChanged.rawValue,
            "action": SyncConflictResolutionAction.remoteChangedKeepLocal.rawValue,
            "terminalStatus": SyncConflictStatus.resolved.rawValue
        ])
        let encodedMetadata = audit.metadata
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "|")
        #expect(!encodedMetadata.contains("Original payee"))
        #expect(!encodedMetadata.contains("Incoming observation"))
        #expect(!encodedMetadata.contains(seed.oldHash))
        #expect(seed.newHash.map { !encodedMetadata.contains($0) } == true)
        try await assertConservation(fixture.service)
    }

    @Test func conflictResolutionDatabaseFailureRollsBackEveryCandidateChange() async throws {
        let fixture = try await makeService()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let seed = try await seedImportedConflict(service: fixture.service, kind: .remoteChanged)
        let before = try #require(await fixture.service.currentSnapshot())
        let stateBefore = try await fixture.service.simpleFINState()

        let databaseURL = fixture.directory.appendingPathComponent("LedgerBar.sqlite")
        let queue = try DatabaseQueue(path: databaseURL.path)
        try await queue.write { db in
            try db.execute(sql: """
                CREATE TRIGGER reject_conflict_resolution_audit
                BEFORE INSERT ON audit_events
                WHEN NEW.event_kind = 'syncConflictResolved'
                BEGIN
                    SELECT RAISE(ABORT, 'synthetic conflict rollback');
                END
                """)
        }

        do {
            _ = try await fixture.service.resolveSyncConflict(
                command(seed, choice: .remoteChanged(.acceptRemote)),
                nowEpoch: epoch(day: 9)
            )
            Issue.record("synthetic database failure did not abort conflict resolution")
        } catch {
            // Expected: the SQLite trigger aborts the service's sole write.
        }

        #expect(await fixture.service.currentSnapshot() == before)
        #expect(try await fixture.service.simpleFINState() == stateBefore)

        let coldStore = try LedgerWorkspaceStore(databaseURL: databaseURL)
        #expect(try coldStore.load(budgetID: seed.budgetID).snapshot() == before)
        #expect(try coldStore.loadSimpleFINState(budgetID: seed.budgetID) == stateBefore)
    }
}

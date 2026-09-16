import Foundation

private struct ValidatedRemoteConflictChange {
    var rawAmount: String
    var parsedAmount: Milliunits
    var postedEpoch: Int64
    var transactedEpoch: Int64?
    var payee: String?
    var description: String?
    var payloadHash: String
}

private struct PreservedStagedState {
    var reason: StageReason?
}

private enum RemoteDisappearedEditKind: Int, Comparable {
    case date
    case category
    case memo
    case approval
    case cleared

    static func < (lhs: RemoteDisappearedEditKind, rhs: RemoteDisappearedEditKind) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

extension RemoteDisappearedLocalEdit {
    fileprivate var resolutionKind: RemoteDisappearedEditKind {
        switch self {
        case .date: return .date
        case .category: return .category
        case .memo: return .memo
        case .approval: return .approval
        case .cleared: return .cleared
        }
    }
}

extension BudgetWorkspace {
    // MARK: - Sync conflicts

    /// Internal value-type implementation. Production callers reach this only
    /// through `BudgetMutationService.resolveSyncConflict`, which persists and
    /// publishes the completed candidate atomically.
    mutating func resolveSyncConflict(
        _ command: SyncConflictResolutionCommand,
        simpleFINState: SimpleFINConnectionState?,
        nowEpoch: Int64
    ) throws -> SyncConflictResolutionResult {
        guard command.budgetID == budget.id else { throw SyncResolutionError.budgetMismatch }
        guard let conflict = syncConflicts[command.conflictID] else {
            throw SyncResolutionError.conflictNotFound
        }
        guard conflict.budgetID == budget.id else { throw SyncResolutionError.budgetMismatch }
        guard conflict.status == .open else { throw SyncResolutionError.conflictNotOpen }
        guard conflict.resolvedAtEpoch == nil else { throw SyncResolutionError.malformedConflict }
        guard command.expectedBudgetRevision == budget.revision else {
            throw SyncResolutionError.staleRequest
        }
        try validateChoice(command.choice, matches: conflict.eventKind)
        if let expectedFingerprint = command.expectedTransactionFingerprint {
            guard let transactionID = conflict.transactionID,
                  let transaction = transactions[transactionID],
                  transaction.accountingFingerprint == expectedFingerprint else {
                throw SyncResolutionError.staleRequest
            }
        }

        var copy = self
        let transactionsBefore = transactions
        let startingRevision = budget.revision
        let action: SyncConflictResolutionAction

        switch command.choice {
        case .remoteChanged(let resolution):
            try copy.requireCurrentRemoteObservation(conflict)
            let context = try copy.importedConflictContext(conflict)
            try copy.validateRemoteBaseline(conflict.oldMetadata, record: context.record)
            let incoming = try copy.validatedRemoteChange(
                metadata: conflict.newMetadata,
                record: context.record,
                nowEpoch: nowEpoch
            )

            switch resolution {
            case .keepLocal:
                var updatedRecord = context.record
                copy.advanceImportBaseline(&updatedRecord, to: incoming)
                copy.setSimpleFINImport(updatedRecord)
                action = .remoteChangedKeepLocal

            case .acceptRemote:
                try copy.validateRemoteAcceptanceTarget(context.transaction)
                let normalizedAmount = try copy.normalizedAmount(
                    incoming.parsedAmount,
                    for: context,
                    state: simpleFINState
                )
                try copy.updateImportedTransactionInPlace(
                    transactionID: context.transaction.id,
                    newAmountMilliunits: normalizedAmount,
                    newPostedEpoch: incoming.postedEpoch,
                    newPayeeName: incoming.payee,
                    newMemo: incoming.description,
                    nowEpoch: nowEpoch
                )
                var updatedRecord = context.record
                copy.advanceImportBaseline(&updatedRecord, to: incoming)
                copy.setSimpleFINImport(updatedRecord)
                action = .remoteChangedAcceptRemote
            }

        case .remoteDisappeared(let resolution):
            try copy.requireCurrentRemoteObservation(conflict)
            let context = try copy.importedConflictContext(conflict)
            try copy.validateRemoteBaseline(conflict.oldMetadata, record: context.record)
            guard !context.record.remoteDisappearanceAcknowledged else {
                throw SyncResolutionError.staleRequest
            }

            switch resolution {
            case .keepLocal:
                var updatedRecord = context.record
                updatedRecord.remoteDisappearanceAcknowledged = true
                copy.setSimpleFINImport(updatedRecord)
                action = .remoteDisappearedKeepLocal

            case .editLocal(let edits):
                let orderedEdits = try copy.validatedDisappearanceEdits(
                    edits,
                    transaction: context.transaction
                )
                for edit in orderedEdits {
                    switch edit {
                    case .date(let date):
                        try copy.updateDate(
                            transactionID: context.transaction.id,
                            date: date,
                            nowEpoch: nowEpoch
                        )
                    case .category(let categoryID):
                        try copy.categorize(
                            transactionID: context.transaction.id,
                            categoryID: categoryID,
                            nowEpoch: nowEpoch
                        )
                    case .memo(let memo):
                        try copy.updateMemo(
                            transactionID: context.transaction.id,
                            memo: memo,
                            nowEpoch: nowEpoch
                        )
                    case .approval(let approved):
                        try copy.setApproved(
                            transactionID: context.transaction.id,
                            approved: approved,
                            nowEpoch: nowEpoch
                        )
                    case .cleared(let cleared):
                        try copy.setCleared(
                            transactionID: context.transaction.id,
                            cleared: cleared,
                            nowEpoch: nowEpoch
                        )
                    }
                }
                var updatedRecord = context.record
                updatedRecord.remoteDisappearanceAcknowledged = true
                copy.setSimpleFINImport(updatedRecord)
                action = .remoteDisappearedEditLocal

            case .softVoidImported:
                try copy.validateDestructiveConflictTarget(context.transaction)
                try copy.deleteTransaction(context.transaction.id, nowEpoch: nowEpoch)
                var updatedRecord = context.record
                updatedRecord.remoteDisappearanceAcknowledged = true
                copy.setSimpleFINImport(updatedRecord)
                action = .remoteDisappearedSoftVoidImported
            }

        case .manualPotentialDuplicate(let resolution):
            let context = try copy.manualDuplicateContext(conflict)
            switch resolution {
            case .keepBoth:
                action = .manualPotentialDuplicateKeepBoth

            case .softVoidImported:
                try copy.validateDestructiveConflictTarget(context.imported)
                try copy.deleteTransaction(context.imported.id, nowEpoch: nowEpoch)
                action = .manualPotentialDuplicateSoftVoidImported

            case .deleteManual:
                try copy.validateDestructiveConflictTarget(context.manual)
                try copy.deleteTransaction(context.manual.id, nowEpoch: nowEpoch)
                action = .manualPotentialDuplicateDeleteManual
            }
        }

        copy.resolveConflictAndSupersededObservations(
            conflict,
            action: action,
            nowEpoch: nowEpoch
        )
        if copy.budget.revision == startingRevision {
            try copy.bumpRevision()
        }

        let affected = Set(transactionsBefore.keys).union(copy.transactions.keys)
            .filter { transactionsBefore[$0] != copy.transactions[$0] }
            .sorted()
        let result = SyncConflictResolutionResult(
            conflictID: conflict.id,
            status: .resolved,
            action: action,
            affectedTransactionIDs: affected,
            budgetRevision: copy.budget.revision
        )
        self = copy
        return result
    }

    private func validateChoice(
        _ choice: SyncConflictResolutionChoice,
        matches kind: SyncConflictKind
    ) throws {
        let matches: Bool
        switch (choice, kind) {
        case (.remoteChanged, .remoteChanged),
             (.remoteDisappeared, .remoteDisappeared),
             (.manualPotentialDuplicate, .manualPotentialDuplicate):
            matches = true
        default:
            matches = false
        }
        guard matches else { throw SyncResolutionError.resolutionKindMismatch }
    }

    private typealias ImportedConflictContext = (
        transaction: TransactionRow,
        record: SimpleFINImportRecord
    )

    private func importedConflictContext(_ conflict: SyncConflictRow) throws -> ImportedConflictContext {
        guard let transactionID = conflict.transactionID,
              let importID = conflict.simpleFINImportID,
              let transaction = transactions[transactionID],
              let record = simpleFINImports[transactionID] else {
            throw SyncResolutionError.missingReference
        }
        guard transaction.budgetID == budget.id,
              record.budgetID == budget.id,
              transaction.sourceKind == .simplefin,
              record.id == importID,
              record.transactionID == transaction.id else {
            throw SyncResolutionError.malformedConflict
        }
        return (transaction, record)
    }

    private func requireCurrentRemoteObservation(_ conflict: SyncConflictRow) throws {
        guard let importID = conflict.simpleFINImportID else {
            throw SyncResolutionError.malformedConflict
        }
        let related = syncConflicts.values.filter {
            $0.status == .open
                && $0.simpleFINImportID == importID
                && $0.eventKind != .manualPotentialDuplicate
        }
        guard let newest = related.max(by: {
            ($0.createdAtEpoch, $0.id) < ($1.createdAtEpoch, $1.id)
        }), newest.id == conflict.id else {
            throw SyncResolutionError.staleRequest
        }
    }

    private func validateRemoteBaseline(
        _ metadata: SyncConflictMetadata,
        record: SimpleFINImportRecord
    ) throws {
        guard let amount = metadata.amountDecimalString,
              let postedEpoch = metadata.postedEpoch,
              let payloadHash = metadata.payloadHash,
              postedEpoch > 0,
              (try? MoneyParser.milliunits(fromDecimalString: amount)) != nil,
              Self.isCanonicalPayloadHash(payloadHash) else {
            throw SyncResolutionError.malformedConflict
        }
        // A pre-v5 conflict cannot prove a non-nil transacted epoch because
        // that field was absent from its persisted metadata. Treat that shape
        // as malformed instead of guessing which canonical baseline it meant.
        if metadata.transactedEpoch == nil, record.remoteTransactedEpoch != nil {
            throw SyncResolutionError.malformedConflict
        }
        guard amount == record.remoteAmountDecimalString,
              postedEpoch == record.remotePostedEpoch,
              metadata.transactedEpoch == record.remoteTransactedEpoch,
              payloadHash == record.remotePayloadHash else {
            throw SyncResolutionError.staleRequest
        }
    }

    private func validatedRemoteChange(
        metadata: SyncConflictMetadata,
        record: SimpleFINImportRecord,
        nowEpoch: Int64
    ) throws -> ValidatedRemoteConflictChange {
        guard let rawAmount = metadata.amountDecimalString,
              let postedEpoch = metadata.postedEpoch,
              let payloadHash = metadata.payloadHash,
              postedEpoch > 0,
              Self.isCanonicalPayloadHash(payloadHash),
              let date = calendar.budgetDate(fromEpoch: postedEpoch),
              let today = calendar.budgetDate(fromEpoch: nowEpoch),
              date <= today else {
            throw SyncResolutionError.malformedConflict
        }
        do {
            let parsed = try MoneyParser.milliunits(fromDecimalString: rawAmount)
            let reconstructed = SimpleFINRemoteTransaction(
                id: record.remoteTransactionID,
                amount: rawAmount,
                postedEpoch: postedEpoch,
                transactedAtEpoch: metadata.transactedEpoch,
                description: metadata.descriptionText,
                payee: metadata.payeeDisplay,
                pending: false
            )
            let canonical = try SimpleFINPayloadHash.canonicalHash(
                remoteTransactionID: record.remoteTransactionID,
                transaction: reconstructed
            )
            guard canonical == payloadHash else {
                throw SyncResolutionError.malformedConflict
            }
            return ValidatedRemoteConflictChange(
                rawAmount: rawAmount,
                parsedAmount: parsed,
                postedEpoch: postedEpoch,
                transactedEpoch: metadata.transactedEpoch,
                payee: metadata.payeeDisplay,
                description: metadata.descriptionText,
                payloadHash: payloadHash
            )
        } catch let error as SyncResolutionError {
            throw error
        } catch {
            throw SyncResolutionError.malformedConflict
        }
    }

    private func normalizedAmount(
        _ rawAmount: Milliunits,
        for context: ImportedConflictContext,
        state: SimpleFINConnectionState?
    ) throws -> Milliunits {
        guard let account = accounts[context.transaction.accountID],
              account.budgetID == budget.id else {
            throw SyncResolutionError.missingReference
        }
        let links = state?.links.filter {
            $0.connectionKey == context.record.connectionKey
                && $0.remoteAccountID == context.record.remoteAccountID
                && $0.localAccountID == context.transaction.accountID
        } ?? []
        guard links.count == 1, let link = links.first else {
            throw links.isEmpty ? SyncResolutionError.missingReference : SyncResolutionError.malformedConflict
        }
        try SimpleFINSynchronizer.validateSignNormalization(
            accountType: account.type,
            signNormalization: link.signNormalization
        )
        let normalized = rawAmount.multipliedReportingOverflow(by: Int64(link.signNormalization.rawValue))
        guard !normalized.overflow else { throw MutationError.arithmeticOverflow }
        return normalized.partialValue
    }

    private static func isCanonicalPayloadHash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private mutating func advanceImportBaseline(
        _ record: inout SimpleFINImportRecord,
        to incoming: ValidatedRemoteConflictChange
    ) {
        record.remoteAmountDecimalString = incoming.rawAmount
        record.remotePostedEpoch = incoming.postedEpoch
        record.remoteTransactedEpoch = incoming.transactedEpoch
        record.remotePayloadHash = incoming.payloadHash
        record.remoteDisappearanceAcknowledged = false
    }

    private func validateRemoteAcceptanceTarget(_ row: TransactionRow) throws {
        guard let account = accounts[row.accountID] else { throw MutationError.accountNotFound }
        guard !account.closed else { throw MutationError.accountClosed }
        if row.transferPairID != nil { throw MutationError.transferLegsInvalid }
        try validateNoRefundDependency(row)
        // `updateImportedTransactionInPlace` rechecks every remaining protected
        // state and both old/new closed-month gates immediately before mutate.
    }

    private func validatedDisappearanceEdits(
        _ edits: [RemoteDisappearedLocalEdit],
        transaction row: TransactionRow
    ) throws -> [RemoteDisappearedLocalEdit] {
        guard (1...5).contains(edits.count) else { throw SyncResolutionError.invalidEdit }
        let kinds = edits.map(\.resolutionKind)
        guard Set(kinds).count == kinds.count else { throw SyncResolutionError.invalidEdit }
        guard row.postingState != .voided else { throw MutationError.transactionNotFound }
        guard row.postingState != .staged else { throw MutationError.resolutionNotEligible }
        guard !isMonthClosed(row.date.budgetMonth) else { throw MutationError.closedMonth }
        guard row.cleared != .reconciled,
              !reconciliationMembership.contains(row.id) else {
            throw MutationError.reconciledTransaction
        }
        guard let account = accounts[row.accountID] else { throw MutationError.accountNotFound }
        guard !account.closed else { throw MutationError.accountClosed }
        if row.transferPairID != nil { throw MutationError.transferLegsInvalid }
        try validateNoRefundDependency(row)
        return edits.sorted { $0.resolutionKind < $1.resolutionKind }
    }

    private func validateDestructiveConflictTarget(_ row: TransactionRow) throws {
        guard row.postingState != .voided else { throw MutationError.transactionNotFound }
        guard !isMonthClosed(row.date.budgetMonth) else { throw MutationError.closedMonth }
        guard row.cleared != .reconciled,
              !reconciliationMembership.contains(row.id) else {
            throw MutationError.reconciledTransaction
        }
        guard let account = accounts[row.accountID] else { throw MutationError.accountNotFound }
        guard !account.closed else { throw MutationError.accountClosed }
        if row.transferPairID != nil { throw MutationError.transferLegsInvalid }
        try validateNoRefundDependency(row)
    }

    private func validateNoRefundDependency(_ row: TransactionRow) throws {
        guard row.refundOfTransactionID == nil else {
            throw SyncResolutionError.dependencyInvalid
        }
        let hasLiveDependent = transactions.values.contains {
            $0.id != row.id
                && $0.refundOfTransactionID == row.id
                && $0.postingState != .voided
        }
        guard !hasLiveDependent else { throw MutationError.transactionHasDependents }
    }

    private typealias ManualDuplicateContext = (
        manual: TransactionRow,
        imported: TransactionRow,
        record: SimpleFINImportRecord
    )

    private func manualDuplicateContext(_ conflict: SyncConflictRow) throws -> ManualDuplicateContext {
        guard let manualID = conflict.transactionID,
              let importID = conflict.simpleFINImportID,
              let manual = transactions[manualID] else {
            throw SyncResolutionError.missingReference
        }
        let records = simpleFINImports.values.filter { $0.id == importID }
        guard records.count == 1, let record = records.first,
              let imported = transactions[record.transactionID] else {
            throw SyncResolutionError.missingReference
        }
        guard manual.id != imported.id,
              manual.budgetID == budget.id,
              imported.budgetID == budget.id,
              record.budgetID == budget.id,
              manual.sourceKind == .manual || manual.sourceKind == .file,
              imported.sourceKind == .simplefin,
              simpleFINImports[manual.id] == nil,
              simpleFINImports[imported.id]?.id == record.id,
              manual.accountID == imported.accountID,
              manual.date == imported.date,
              manual.amountMilliunits == imported.amountMilliunits else {
            throw SyncResolutionError.malformedConflict
        }
        guard manual.postingState != .voided,
              imported.postingState != .voided else {
            throw SyncResolutionError.staleRequest
        }
        return (manual, imported, record)
    }

    private mutating func resolveConflictAndSupersededObservations(
        _ conflict: SyncConflictRow,
        action: SyncConflictResolutionAction,
        nowEpoch: Int64
    ) {
        if conflict.eventKind != .manualPotentialDuplicate,
           let importID = conflict.simpleFINImportID {
            for id in syncConflicts.keys.sorted() where id != conflict.id {
                guard var older = syncConflicts[id],
                      older.status == .open,
                      older.eventKind != .manualPotentialDuplicate,
                      older.simpleFINImportID == importID,
                      (older.createdAtEpoch, older.id) < (conflict.createdAtEpoch, conflict.id) else {
                    continue
                }
                older.status = .dismissed
                older.resolvedAtEpoch = nowEpoch
                setSyncConflict(older)
            }
        }
        var resolved = conflict
        resolved.status = .resolved
        resolved.resolvedAtEpoch = nowEpoch
        setSyncConflict(resolved)
        recordAudit(
            entityType: "syncConflict",
            entityID: conflict.id.description,
            eventKind: "syncConflictResolved",
            metadata: [
                "kind": conflict.eventKind.rawValue,
                "action": action.rawValue,
                "terminalStatus": SyncConflictStatus.resolved.rawValue
            ],
            nowEpoch: nowEpoch
        )
    }

    // MARK: - Snapshot discrepancies

    private mutating func createOffBudgetSuccessor(
        for account: AccountRow,
        snapshot: SnapshotDiscrepancyRow,
        observedDate: BudgetDate,
        nowEpoch: Int64
    ) throws -> AccountID {
        guard account.type == .creditCard,
              !account.closed,
              budgetEligible(account, budgetCurrency: budget.currency),
              snapshot.remoteBalanceMilliunits > 0 else {
            throw SyncResolutionError.malformedDiscrepancy
        }

        var closed = account
        closed.closed = true
        setAccount(closed)

        let successor = AccountRow(
            budgetID: budget.id,
            name: "\(account.name) (Off-Budget Successor)",
            type: account.type,
            onBudget: false,
            currency: account.currency,
            createdAtEpoch: nowEpoch
        )
        setAccount(successor)

        let sequence = try allocateSourceSequence()
        let anchor = TransactionRow(
            budgetID: budget.id,
            accountID: successor.id,
            payeeID: systemPayeeID(.openingBalance),
            sourceKind: .system,
            date: observedDate,
            effectiveAtEpoch: snapshot.observedEpoch,
            sourceOrderKey: .system(sequence: sequence, systemKind: "offBudgetMigrationOpening"),
            amountMilliunits: snapshot.remoteBalanceMilliunits,
            cleared: .cleared,
            approved: true,
            postingState: .posted,
            kind: .openingBalance
        )
        setTransaction(anchor)

        try runReplayAndApplyDecisions()
        recordAudit(
            entityType: "account",
            entityID: account.id.description,
            eventKind: "accountClosedOffBudgetSuccessorCreated",
            metadata: [
                "successorAccountID": successor.id.description,
                "migrationOpening": "snapshot"
            ],
            nowEpoch: nowEpoch
        )
        return successor.id
    }

    /// Internal value-type implementation. The actor persists its completed
    /// candidate with one store save and never publishes a rejected mutation.
    mutating func resolveSnapshotDiscrepancy(
        _ command: SnapshotDiscrepancyResolutionCommand,
        nowEpoch: Int64
    ) throws -> SnapshotDiscrepancyResolutionResult {
        guard command.budgetID == budget.id else { throw SyncResolutionError.budgetMismatch }
        guard let discrepancy = snapshotDiscrepancies[command.discrepancyID] else {
            throw SyncResolutionError.discrepancyNotFound
        }
        guard discrepancy.budgetID == budget.id else { throw SyncResolutionError.budgetMismatch }
        guard discrepancy.status == .open else { throw SyncResolutionError.discrepancyNotOpen }
        guard discrepancy.resolutionReason == nil,
              discrepancy.adjustmentTransactionID == nil,
              discrepancy.resolvedAtEpoch == nil else {
            throw SyncResolutionError.malformedDiscrepancy
        }
        guard command.expectedVersion == SnapshotDiscrepancyVersion(discrepancy: discrepancy) else {
            throw SyncResolutionError.staleRequest
        }

        let checkedDifference = discrepancy.remoteBalanceMilliunits
            .subtractingReportingOverflow(discrepancy.localRegisterMilliunits)
        guard !checkedDifference.overflow else { throw MutationError.arithmeticOverflow }
        guard checkedDifference.partialValue != 0,
              checkedDifference.partialValue == discrepancy.differenceMilliunits else {
            throw SyncResolutionError.malformedDiscrepancy
        }
        guard let account = accounts[discrepancy.accountID],
              account.budgetID == budget.id else {
            throw SyncResolutionError.missingReference
        }
        let currentPrefix = try registerBalanceAsOf(
            accountID: account.id,
            epoch: discrepancy.observedEpoch
        )
        guard currentPrefix == discrepancy.localRegisterMilliunits else {
            throw SyncResolutionError.staleRequest
        }

        var copy = self
        let reason: SnapshotDiscrepancyResolutionReason
        let artifact: SnapshotDiscrepancyResolutionArtifact

        switch command.choice {
        case .adjustment:
            guard !account.closed else { throw MutationError.accountClosed }
            guard budgetEligible(account, budgetCurrency: budget.currency),
                  account.type.isCashLike || account.type == .creditCard else {
                throw MutationError.reconciliationInvalid
            }
            guard let observedDate = calendar.budgetDate(fromEpoch: discrepancy.observedEpoch),
                  let today = calendar.budgetDate(fromEpoch: nowEpoch),
                  observedDate <= today else {
                throw SyncResolutionError.malformedDiscrepancy
            }
            // A cleared adjustment dated on or before a completed statement
            // would retroactively change that reconciliation's cleared
            // balance without becoming one of its fingerprinted members.
            // Later adjustments do not alter the completed statement prefix.
            let completedReconciliations = reconciliations.values.filter {
                $0.budgetID == budget.id
                    && $0.accountID == account.id
                    && $0.status == .completed
            }
            let crossesCompletedReconciliation = completedReconciliations.contains {
                observedDate <= $0.statementDate
            }
            guard !crossesCompletedReconciliation else {
                throw MutationError.reconciledTransaction
            }
            let coveredReconciledTransactions = Set(
                completedReconciliations.flatMap {
                    (reconciliationTransactions[$0.id] ?? []).map(\.transactionID)
                }
            )
            let hasLegacyReconciliationWithoutCutoff = transactions.values.contains { row in
                row.accountID == account.id
                    && (row.cleared == .reconciled || reconciliationMembership.contains(row.id))
                    && !coveredReconciledTransactions.contains(row.id)
            }
            // Legacy snapshots may carry reconciled membership without the
            // later ReconciliationRow/statement-date model. With no durable
            // cutoff, even an apparently later adjustment cannot be proven
            // not to rewrite the protected statement prefix.
            guard !hasLegacyReconciliationWithoutCutoff else {
                throw MutationError.reconciledTransaction
            }
            let stagedBefore: [TransactionID: PreservedStagedState] = Dictionary(
                uniqueKeysWithValues: transactions.values.compactMap { row in
                    guard row.postingState == .staged else { return nil }
                    return (row.id, PreservedStagedState(reason: row.stageReason))
                }
            )
            let adjustmentID = try copy.insertSystemAdjustmentTransaction(
                accountID: account.id,
                date: observedDate,
                effectiveAtEpoch: discrepancy.observedEpoch,
                amountMilliunits: discrepancy.differenceMilliunits
            )
            let replay = try copy.runReplayAndApplyDecisions()
            guard replay.postingDecisions[adjustmentID]?.postingState == .posted else {
                throw MutationError.cardBalanceWouldBecomePositive
            }
            for (id, priorState) in stagedBefore {
                guard let row = copy.transactions[id],
                      row.postingState == .staged,
                      row.stageReason == priorState.reason else {
                    throw SyncResolutionError.dependencyInvalid
                }
            }
            guard try copy.registerBalanceAsOf(
                accountID: account.id,
                epoch: discrepancy.observedEpoch
            ) == discrepancy.remoteBalanceMilliunits else {
                throw IntegrityError(code: .invalidRowState, month: observedDate.budgetMonth)
            }
            reason = .adjustment
            artifact = .adjustment(adjustmentID)

        case .manualAttestation(.confirmedWithoutAccountingAdjustment):
            _ = try copy.projection()
            reason = .manualAttestation
            artifact = .none

        case .accountClosedOffBudget:
            guard let observedDate = calendar.budgetDate(fromEpoch: discrepancy.observedEpoch),
                  let today = calendar.budgetDate(fromEpoch: nowEpoch),
                  observedDate <= today else {
                throw SyncResolutionError.malformedDiscrepancy
            }
            let successorID = try copy.createOffBudgetSuccessor(
                for: account,
                snapshot: discrepancy,
                observedDate: observedDate,
                nowEpoch: nowEpoch
            )
            reason = .accountClosedOffBudget
            artifact = .offBudgetSuccessor(successorID)
        }

        var resolved = discrepancy
        resolved.status = .resolved
        resolved.resolutionReason = reason
        if case .adjustment(let adjustmentID) = artifact {
            resolved.adjustmentTransactionID = adjustmentID
        }
        resolved.resolvedAtEpoch = nowEpoch
        copy.setSnapshotDiscrepancy(resolved)
        copy.recordAudit(
            entityType: "snapshotDiscrepancy",
            entityID: discrepancy.id.description,
            eventKind: "snapshotDiscrepancyResolved",
            metadata: [
                "reason": reason.rawValue,
                "artifact": artifact.auditValue
            ],
            nowEpoch: nowEpoch
        )
        try copy.bumpRevision()

        let result = SnapshotDiscrepancyResolutionResult(
            discrepancyID: discrepancy.id,
            reason: reason,
            artifact: artifact,
            budgetRevision: copy.budget.revision
        )
        self = copy
        return result
    }
}

extension SnapshotDiscrepancyResolutionArtifact {
    fileprivate var auditValue: String {
        switch self {
        case .none: return "none"
        case .adjustment: return "adjustment"
        case .offBudgetSuccessor: return "offBudgetSuccessor"
        }
    }
}

import Foundation

/// The requested interval a per-account sync response is evaluated against
/// (§4.2). A window is defined by the request, never by its own response; only
/// `new_upper_bound` — the maximum valid normalized posted epoch observed, or
/// the prior cursor when no posted rows return — derives from the response.
public enum SimpleFINSyncWindow: Sendable, Equatable {
    /// `start-date = checked(last_successful_posted_epoch - 5*86400)`, no end.
    /// Imports only `start < posted <= new_upper_bound`.
    case recurring(requestStartEpoch: Int64)
    /// The §4.4 two-request initial link: imports only `S < posted <= T` and
    /// commits the cursor at exactly `T`.
    case initialLink(startEpoch: Int64, balanceDateEpoch: Int64)
    /// The same initial-link window with the discovery request's normalized
    /// snapshot balance carried through the history commit. This prevents a
    /// later history response `(B', T')` from being compared to a register
    /// capped at the earlier discovery cutoff `T`.
    case initialLinkWithSnapshot(
        startEpoch: Int64,
        balanceDateEpoch: Int64,
        snapshotBalanceMilliunits: Milliunits
    )
}

/// Everything one per-account engine pass did, for the caller's summary and
/// tests. `newCursor == nil` means the cursor must not move. Protocol pauses,
/// no-data responses, and snapshot-discrepancy pauses after no committed rows
/// return nil; a snapshot discrepancy after successful replay may pause the
/// link while still returning the committed upper bound.
public struct SimpleFINAccountSyncOutcome: Sendable, Equatable {
    public var importedTransactionIDs: [TransactionID] = []
    public var updatedInPlaceTransactionIDs: [TransactionID] = []
    public var newCursor: Int64?
    public var pause: SimpleFINLinkPauseReason?
    public var conflictIDs: [SyncConflictID] = []
    public var discrepancyID: SnapshotDiscrepancyID?
    public var skippedPendingCount = 0
    public var ignoredOutOfWindowCount = 0
    public var closedMonthAppendCount = 0
    /// Boundary-redacted, bounded provider diagnostics; never raw payloads.
    public private(set) var providerErrors: [String] = []

    public init(providerErrors: [String] = []) {
        self.providerErrors = SimpleFINDiagnosticRedactor.redact(providerErrors)
    }

    public var hasProviderErrors: Bool { !providerErrors.isEmpty }

    /// Explicit mutation path for tests and future response aggregation. Raw
    /// provider text can never become UI-readable through this value.
    public mutating func replaceProviderErrors(with errors: [String]) {
        providerErrors = SimpleFINDiagnosticRedactor.redact(errors)
    }
}

/// Applies one account's successful response to the workspace and its link,
/// in memory (§4.3). The caller commits both through a single
/// `BudgetMutationService.syncTransact` so imports, staged rows, conflicts,
/// discrepancies, import identities, pause state, and the cursor land in one
/// database transaction.
///
/// Protocol anomalies never throw: they pause the link (workspace untouched,
/// cursor unchanged) so other accounts keep syncing. Only genuine integrity
/// failures (replay violations, arithmetic in local state) throw and abort
/// the account commit.
public enum SimpleFINSyncEngine {
    private struct ValidRow {
        var remoteID: String
        var rawAmount: String
        var normalizedAmount: Milliunits
        var postedEpoch: Int64
        var transactedEpoch: Int64?
        var payee: String?
        var description: String?
        var hash: String
    }

    private static func importedPayeeName(payee: String?, description: String?) -> String? {
        for candidate in [payee, description] {
            guard let candidate else { continue }
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    public static func applyAccountSync(
        response: SimpleFINAccountsResponse,
        link: inout SimpleFINAccountLink,
        window: SimpleFINSyncWindow,
        workspace: inout BudgetWorkspace,
        nowEpoch: Int64
    ) throws -> SimpleFINAccountSyncOutcome {
        var outcome = SimpleFINAccountSyncOutcome(providerErrors: response.errors)
        // A provider-marked response is partial/untrustworthy (§4.5). Return a
        // diagnostic-only outcome before account matching, row/balance
        // validation, imports, disappearance/discrepancy checks, cursor
        // derivation, or any workspace/link mutation.
        guard !outcome.hasProviderErrors else { return outcome }
        guard link.status == .active else {
            outcome.pause = link.pauseReason
            return outcome
        }
        // An account-less link (§4.4 step 6 positiveCardSnapshot state) has
        // nothing to sync: no import, no cursor, workspace untouched. Reaching
        // here requires an explicit resume of an unbound link; re-linking is
        // the recovery path.
        guard let localAccountID = link.localAccountID else {
            return outcome
        }
        guard let localAccount = workspace.accounts[localAccountID] else {
            throw MutationError.accountNotFound
        }
        // A closed account no longer participates: importing into it would
        // resurrect voided history and raise review items nobody can decide.
        // Like an account-less link, the workspace and cursor stay untouched.
        guard !localAccount.closed else {
            return outcome
        }
        try SimpleFINSynchronizer.validateSignNormalization(
            accountType: localAccount.type,
            signNormalization: link.signNormalization
        )

        func paused(_ reason: SimpleFINLinkPauseReason, _ message: String) -> SimpleFINAccountSyncOutcome {
            link.pause(reason: reason, message: message)
            var result = outcome
            result.pause = reason
            return result
        }

        // Resolve this link's account block. Another link's block never gates
        // this one; a block claiming our remote account id but lacking a
        // stable connection key is unresolvable and pauses (§4.2).
        var matching: [SimpleFINRemoteAccount] = []
        for account in response.accounts where account.id == link.remoteAccountID {
            let key: String
            do {
                key = try account.remoteConnectionKey()
            } catch {
                return paused(.missingStableConnectionKey, "A remote account block has no stable connection identity.")
            }
            if key == link.connectionKey { matching.append(account) }
        }
        guard matching.count <= 1 else {
            return paused(.duplicateRemoteIdentity, "Duplicate remote account identity in one response.")
        }
        guard let remoteAccount = matching.first else {
            // No data for this account in an otherwise valid response: nothing
            // imports and the cursor must not move.
            return outcome
        }
        guard remoteAccount.currency == localAccount.currency else {
            return paused(.currencyMismatch, "The remote account currency changed after linking.")
        }
        guard let today = workspace.calendar.budgetDate(fromEpoch: nowEpoch) else {
            throw IntegrityError(code: .invalidCalendar)
        }

        let multiplier = Int64(link.signNormalization.rawValue)

        // Validate the snapshot balance up front so a malformed balance aborts
        // before any import work.
        let initialSnapshotBalance: Milliunits?
        let requestedBalanceDateEpoch: Int64?
        switch window {
        case .initialLink(_, let balanceDateEpoch):
            initialSnapshotBalance = nil
            requestedBalanceDateEpoch = balanceDateEpoch
        case .initialLinkWithSnapshot(_, let balanceDateEpoch, let snapshotBalanceMilliunits):
            initialSnapshotBalance = snapshotBalanceMilliunits
            requestedBalanceDateEpoch = balanceDateEpoch
        default:
            initialSnapshotBalance = nil
            requestedBalanceDateEpoch = nil
        }
        let responseBalanceDateEpoch = remoteAccount.balanceDateEpoch ?? response.balanceDateEpoch
        let balanceDateEpoch: Int64?
        if let requestedBalanceDateEpoch {
            // The discovery snapshot case carries the exact B/T pair. The
            // compatibility case has no B, but must still never compare at a
            // history response cutoff later than its requested T.
            balanceDateEpoch = initialSnapshotBalance == nil
                ? min(requestedBalanceDateEpoch, responseBalanceDateEpoch ?? requestedBalanceDateEpoch)
                : requestedBalanceDateEpoch
        } else {
            balanceDateEpoch = responseBalanceDateEpoch
        }
        var normalizedRemoteBalance: Milliunits?
        if balanceDateEpoch != nil {
            let parsedBalance: Milliunits
            do {
                parsedBalance = try MoneyParser.milliunits(fromDecimalString: remoteAccount.balance)
            } catch {
                return paused(.protocolError, "The remote balance is malformed.")
            }
            let normalized = parsedBalance.multipliedReportingOverflow(by: multiplier)
            guard !normalized.overflow else {
                return paused(.protocolError, "The remote balance overflows supported amounts.")
            }
            normalizedRemoteBalance = initialSnapshotBalance ?? normalized.partialValue
        }

        // Validate and normalize every row before touching the workspace; a
        // single bad row pauses the whole account with no partial import.
        var validRows: [ValidRow] = []
        var seenRemoteIDs = Set<String>()
        let ordered = remoteAccount.transactions.sorted {
            ($0.postedEpoch, $0.id ?? "") < ($1.postedEpoch, $1.id ?? "")
        }
        for row in ordered {
            if row.pending {
                outcome.skippedPendingCount += 1
                continue
            }
            guard let remoteID = row.id, !remoteID.isEmpty else {
                return paused(.protocolError, "A posted row has no stable remote transaction ID.")
            }
            guard seenRemoteIDs.insert(remoteID).inserted else {
                return paused(.duplicateRemoteIdentity, "A remote response contains a duplicate transaction identity.")
            }
            let parsed: Milliunits
            do {
                parsed = try MoneyParser.milliunits(fromDecimalString: row.amount)
            } catch {
                return paused(.protocolError, "A remote amount is malformed.")
            }
            let normalized = parsed.multipliedReportingOverflow(by: multiplier)
            guard !normalized.overflow else {
                return paused(.protocolError, "A remote amount overflows supported amounts.")
            }
            // §4.3 step 0: the gate is the normalized *budget date*, not the
            // raw epoch.
            guard let rowDate = workspace.calendar.budgetDate(fromEpoch: row.postedEpoch), rowDate <= today else {
                return paused(.futurePostedEpoch, "A remote row is posted on a future budget date.")
            }
            let hash = try SimpleFINPayloadHash.canonicalHash(remoteTransactionID: remoteID, transaction: row)
            validRows.append(ValidRow(
                remoteID: remoteID,
                rawAmount: row.amount,
                normalizedAmount: normalized.partialValue,
                postedEpoch: row.postedEpoch,
                transactedEpoch: row.transactedAtEpoch,
                payee: row.payee,
                description: row.description,
                hash: hash
            ))
        }

        // Window and cursor derivation (§4.2).
        let priorCursor = link.lastSuccessfulPostedEpoch
        let windowStart: Int64
        let upperBound: Int64
        let cursorCandidate: Int64?
        switch window {
        case .recurring(let requestStartEpoch):
            windowStart = requestStartEpoch
            if let maxPosted = validRows.map(\.postedEpoch).max() {
                upperBound = max(priorCursor ?? Int64.min, maxPosted)
                cursorCandidate = max(priorCursor ?? Int64.min, maxPosted)
            } else {
                upperBound = priorCursor ?? Int64.min
                cursorCandidate = priorCursor
            }
        case .initialLink(let startEpoch, let balanceDate):
            windowStart = startEpoch
            upperBound = balanceDate
            cursorCandidate = balanceDate
        case .initialLinkWithSnapshot(let startEpoch, let balanceDate, _):
            windowStart = startEpoch
            upperBound = balanceDate
            cursorCandidate = balanceDate
        }

        var copy = workspace
        var mutated = false

        for row in validRows {
            guard row.postedEpoch > windowStart, row.postedEpoch <= upperBound else {
                outcome.ignoredOutOfWindowCount += 1
                continue
            }
            let importedPayeeName = Self.importedPayeeName(
                payee: row.payee,
                description: row.description
            )
            if let record = copy.simpleFINImportRecord(
                connectionKey: link.connectionKey,
                remoteAccountID: link.remoteAccountID,
                remoteTransactionID: row.remoteID
            ) {
                if record.remotePayloadHash == row.hash {
                    copy.updateSimpleFINImportLastSeen(
                        transactionID: record.transactionID,
                        lastSeenEpoch: nowEpoch,
                        observedPayloadHash: row.hash
                    )
                    outcome.conflictIDs.append(contentsOf: copy.recordManualPotentialDuplicateConflicts(
                        for: record.transactionID,
                        nowEpoch: nowEpoch
                    ))
                    mutated = true
                    continue
                }
                guard let localRow = copy.transactions[record.transactionID] else {
                    throw IntegrityError(code: .invalidReference)
                }
                let newDate = copy.calendar.budgetDate(fromEpoch: row.postedEpoch)
                let eligibleForSilentUpdate = localRow.postingState == .needsCategory
                    && localRow.userEditedAtEpoch == nil
                    && !localRow.approved
                    && localRow.cleared == .uncleared
                    && localRow.transferPairID == nil
                    && localRow.refundOfTransactionID == nil
                    && !copy.reconciliationMembership.contains(localRow.id)
                    && !copy.isMonthClosed(localRow.date.budgetMonth)
                    && newDate.map({ !copy.isMonthClosed($0.budgetMonth) }) == true
                if eligibleForSilentUpdate {
                    try copy.updateImportedTransactionInPlace(
                        transactionID: record.transactionID,
                        newAmountMilliunits: row.normalizedAmount,
                        newPostedEpoch: row.postedEpoch,
                        newPayeeName: importedPayeeName,
                        newMemo: row.description,
                        nowEpoch: nowEpoch
                    )
                    var updatedRecord = record
                    updatedRecord.remoteAmountDecimalString = row.rawAmount
                    updatedRecord.remotePostedEpoch = row.postedEpoch
                    updatedRecord.remoteTransactedEpoch = row.transactedEpoch
                    updatedRecord.remotePayloadHash = row.hash
                    updatedRecord.lastSeenEpoch = nowEpoch
                    updatedRecord.remoteDisappearanceAcknowledged = false
                    copy.setSimpleFINImport(updatedRecord)
                    copy.updateSimpleFINImportLastSeen(
                        transactionID: record.transactionID,
                        lastSeenEpoch: nowEpoch,
                        observedPayloadHash: row.hash
                    )
                    copy.dismissOpenSimpleFINRemoteObservations(
                        simpleFINImportID: updatedRecord.id,
                        nowEpoch: nowEpoch
                    )
                    outcome.updatedInPlaceTransactionIDs.append(record.transactionID)
                } else {
                    // User-owned or otherwise touched rows are never
                    // overwritten; the change becomes an open conflict and the
                    // stored baseline hash stays as-imported until resolution.
                    let old = SyncConflictMetadata(
                        amountDecimalString: record.remoteAmountDecimalString,
                        postedEpoch: record.remotePostedEpoch,
                        transactedEpoch: record.remoteTransactedEpoch,
                        date: localRow.date.description,
                        payeeDisplay: localRow.payeeID.flatMap { copy.payees[$0]?.displayName },
                        descriptionText: localRow.memo,
                        payloadHash: record.remotePayloadHash
                    )
                    let new = SyncConflictMetadata(
                        amountDecimalString: row.rawAmount,
                        postedEpoch: row.postedEpoch,
                        transactedEpoch: row.transactedEpoch,
                        payeeDisplay: importedPayeeName,
                        descriptionText: row.description,
                        payloadHash: row.hash
                    )
                    if let conflictID = copy.recordSyncConflictIfNew(
                        transactionID: record.transactionID,
                        simpleFINImportID: record.id,
                        eventKind: .remoteChanged,
                        oldMetadata: old,
                        newMetadata: new,
                        nowEpoch: nowEpoch
                    ) {
                        outcome.conflictIDs.append(conflictID)
                    }
                    copy.updateSimpleFINImportLastSeen(
                        transactionID: record.transactionID,
                        lastSeenEpoch: nowEpoch,
                        observedPayloadHash: row.hash
                    )
                    outcome.conflictIDs.append(contentsOf: copy.recordManualPotentialDuplicateConflicts(
                        for: record.transactionID,
                        nowEpoch: nowEpoch
                    ))
                }
                mutated = true
            } else if let existingID = copy.importedTransactionID(
                connectionKey: link.connectionKey,
                remoteAccountID: link.remoteAccountID,
                remoteTransactionID: row.remoteID
            ) {
                // Pre-upgrade imported row without a record: baseline it from
                // this sighting. Changes between the original import and this
                // baseline are undetectable — documented graceful degradation.
                copy.setSimpleFINImport(SimpleFINImportRecord(
                    budgetID: copy.budget.id,
                    transactionID: existingID,
                    connectionKey: link.connectionKey,
                    remoteAccountID: link.remoteAccountID,
                    remoteTransactionID: row.remoteID,
                    remoteAmountDecimalString: row.rawAmount,
                    remotePostedEpoch: row.postedEpoch,
                    remoteTransactedEpoch: row.transactedEpoch,
                    remotePayloadHash: row.hash,
                    lastSeenEpoch: nowEpoch
                ))
                outcome.conflictIDs.append(contentsOf: copy.recordManualPotentialDuplicateConflicts(
                    for: existingID,
                    nowEpoch: nowEpoch
                ))
                mutated = true
            } else {
                let transactionID = try copy.importPostedTransaction(
                    accountID: localAccountID,
                    connectionKey: link.connectionKey,
                    remoteAccountID: link.remoteAccountID,
                    remoteTransactionID: row.remoteID,
                    postedEpoch: row.postedEpoch,
                    payeeName: importedPayeeName,
                    amountMilliunits: row.normalizedAmount,
                    memo: row.description,
                    remoteAmountDecimalString: row.rawAmount,
                    remoteTransactedEpoch: row.transactedEpoch,
                    remotePayloadHash: row.hash,
                    nowEpoch: nowEpoch
                )
                outcome.importedTransactionIDs.append(transactionID)
                outcome.conflictIDs.append(contentsOf: copy.recordManualPotentialDuplicateConflicts(
                    for: transactionID,
                    nowEpoch: nowEpoch
                ))
                if copy.transactions[transactionID]?.stageReason == .closedMonthImport {
                    outcome.closedMonthAppendCount += 1
                }
                mutated = true
            }
        }

        // Disappeared-row detection (§4.3, final bullet): only for a recurring
        // pass over a successful response, only inside the requested overlap,
        // against the response's full valid-row ID set. Never auto-void.
        if case .recurring = window, response.errors.isEmpty {
            let records = copy.simpleFINImports.values
                .filter { $0.connectionKey == link.connectionKey && $0.remoteAccountID == link.remoteAccountID }
                .sorted { $0.id < $1.id }
            for record in records {
                guard record.remotePostedEpoch > windowStart, record.remotePostedEpoch <= upperBound else { continue }
                guard !seenRemoteIDs.contains(record.remoteTransactionID) else { continue }
                guard !record.remoteDisappearanceAcknowledged else { continue }
                guard let localRow = copy.transactions[record.transactionID], localRow.postingState != .voided else { continue }
                let old = SyncConflictMetadata(
                    amountDecimalString: record.remoteAmountDecimalString,
                    postedEpoch: record.remotePostedEpoch,
                    transactedEpoch: record.remoteTransactedEpoch,
                    date: localRow.date.description,
                    payeeDisplay: localRow.payeeID.flatMap { copy.payees[$0]?.displayName },
                    descriptionText: localRow.memo,
                    payloadHash: record.remotePayloadHash
                )
                let new = SyncConflictMetadata(
                    note: "Absent from a successful response covering the requested window."
                )
                if let conflictID = copy.recordSyncConflictIfNew(
                    transactionID: record.transactionID,
                    simpleFINImportID: record.id,
                    eventKind: .remoteDisappeared,
                    oldMetadata: old,
                    newMetadata: new,
                    nowEpoch: nowEpoch
                ) {
                    outcome.conflictIDs.append(conflictID)
                    mutated = true
                }
            }
        }

        // §4.4 snapshot comparison, after all replay work: sign-normalized
        // remote balance vs the pair-pulled as-of register balance. A match
        // never auto-resolves an open discrepancy.
        if let balanceDateEpoch, let normalizedRemoteBalance, response.errors.isEmpty {
            let local = try copy.registerBalanceAsOf(accountID: localAccountID, epoch: balanceDateEpoch)
            if local != normalizedRemoteBalance {
                if let discrepancyID = try copy.upsertOpenSnapshotDiscrepancy(
                    accountID: localAccountID,
                    simpleFINLinkIdentity: link.identity,
                    observedEpoch: balanceDateEpoch,
                    remoteBalanceMilliunits: normalizedRemoteBalance,
                    localRegisterMilliunits: local,
                    nowEpoch: nowEpoch
                ) {
                    outcome.discrepancyID = discrepancyID
                    link.pause(reason: .snapshotDiscrepancy)
                    outcome.pause = .snapshotDiscrepancy
                    mutated = true
                }
            }
        }

        // Informational closed-month badge (§2.1): the link stays active and
        // keeps syncing; the reason clears once no unresolved closedMonthImport
        // staged rows remain for this account.
        let hasUnresolvedClosedMonthImports = copy.transactions.values.contains {
            $0.accountID == localAccountID && $0.postingState == .staged && $0.stageReason == .closedMonthImport
        }
        if link.pauseReason != .snapshotDiscrepancy {
            if hasUnresolvedClosedMonthImports {
                link.pauseReason = .closedMonthImportPending
            } else if link.pauseReason == .closedMonthImportPending {
                link.pauseReason = nil
            }
        }

        if let cursorCandidate {
            link.lastSuccessfulPostedEpoch = cursorCandidate
            outcome.newCursor = cursorCandidate
        }
        link.clearSyncError()
        if mutated { try copy.bumpRevision() }
        workspace = copy
        return outcome
    }
}

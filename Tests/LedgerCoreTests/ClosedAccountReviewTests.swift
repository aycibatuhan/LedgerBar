import Foundation
import Testing
@testable import LedgerCore

/// Closing an account must never strand review items: once its rows are
/// voided and it is closed, conflicts and discrepancies on it can no longer
/// pass their resolution guards.
@Suite("Closed-account review items")
struct ClosedAccountReviewTests {

    private func metadata(_ note: String) -> SyncConflictMetadata {
        SyncConflictMetadata(amountDecimalString: "-20.00", postedEpoch: testEpoch + 86_400 * 4,
                             payloadHash: String(repeating: "a", count: 64), note: note)
    }

    private struct Fixture {
        var ws: BudgetWorkspace
        let closing: AccountID
        let other: AccountID
        let closingConflict: SyncConflictID
        let otherConflict: SyncConflictID
        let closingDiscrepancy: SnapshotDiscrepancyID
        let otherDiscrepancy: SnapshotDiscrepancyID
    }

    /// Two accounts, each with one open conflict and one open discrepancy.
    /// The closing account's conflict points at a manual row that
    /// void-and-close removes, so account lookup must fall back to the import.
    private func fixture() throws -> Fixture {
        var ws = try makeWorkspace(timeZone: "UTC")
        let closing = try ws.addAccount(name: "Duplicate Checking", type: .checking, onBudget: true,
                                        openingBalance: usd(500), openingDate: date("2025-01-01"), nowEpoch: testEpoch)
        let other = try ws.addAccount(name: "Checking", type: .checking, onBudget: true,
                                      openingBalance: usd(300), openingDate: date("2025-01-01"), nowEpoch: testEpoch)
        let posted = try ws.calendar.noonEpoch(of: date("2025-01-05"))
        let importedClosing = try ws.importPostedTransaction(accountID: closing, connectionKey: "c", remoteAccountID: "dup",
                                                             remoteTransactionID: "t1", postedEpoch: posted,
                                                             payeeName: "Grocer", amountMilliunits: -usd(20), nowEpoch: testEpoch)
        let manualClosing = try ws.addManualTransaction(accountID: closing, date: date("2025-01-05"), payeeName: "Grocer",
                                                        categoryID: ws.categoryID(named: "Groceries"),
                                                        amountMilliunits: -usd(20), nowEpoch: testEpoch)
        let importedOther = try ws.importPostedTransaction(accountID: other, connectionKey: "c", remoteAccountID: "chk",
                                                           remoteTransactionID: "t2", postedEpoch: posted,
                                                           payeeName: "Cafe", amountMilliunits: -usd(7), nowEpoch: testEpoch)
        let closingRecord = try #require(ws.simpleFINImports[importedClosing])
        let otherRecord = try #require(ws.simpleFINImports[importedOther])
        // Clear any conflicts the imports raised on their own so the fixture
        // controls exactly one per account.
        for id in ws.syncConflicts.keys {
            var row = ws.syncConflicts[id]!
            row.status = .dismissed
            row.resolvedAtEpoch = testEpoch
            ws.setSyncConflict(row)
        }
        let closingConflictValue = ws.recordSyncConflictIfNew(
            transactionID: manualClosing, simpleFINImportID: closingRecord.id, eventKind: .manualPotentialDuplicate,
            oldMetadata: metadata("manual"), newMetadata: metadata("import"), nowEpoch: testEpoch)
        let closingConflict = try #require(closingConflictValue)
        let otherConflictValue = ws.recordSyncConflictIfNew(
            transactionID: importedOther, simpleFINImportID: otherRecord.id, eventKind: .remoteDisappeared,
            oldMetadata: metadata("stored"), newMetadata: metadata("gone"), nowEpoch: testEpoch)
        let otherConflict = try #require(otherConflictValue)
        let closingDiscrepancyValue = try ws.upsertOpenSnapshotDiscrepancy(
            accountID: closing, observedEpoch: posted, remoteBalanceMilliunits: usd(450),
            localRegisterMilliunits: usd(460), nowEpoch: testEpoch)
        let closingDiscrepancy = try #require(closingDiscrepancyValue)
        let otherDiscrepancyValue = try ws.upsertOpenSnapshotDiscrepancy(
            accountID: other, observedEpoch: posted, remoteBalanceMilliunits: usd(290),
            localRegisterMilliunits: usd(293), nowEpoch: testEpoch)
        let otherDiscrepancy = try #require(otherDiscrepancyValue)
        return Fixture(ws: ws, closing: closing, other: other, closingConflict: closingConflict,
                       otherConflict: otherConflict, closingDiscrepancy: closingDiscrepancy,
                       otherDiscrepancy: otherDiscrepancy)
    }

    private func settledAudits(_ ws: BudgetWorkspace, _ entityID: String) -> [AuditEventRow] {
        ws.auditEvents.filter { $0.entityID == entityID && $0.metadata["cause"] == "accountClosed" }
    }

    @Test("Void History and Close settles only that account's review items, and the ledger elsewhere is untouched")
    func voidAndCloseSettlesItems() throws {
        var f = try fixture()
        let otherBalanceBefore = try f.ws.projection().registerBalances[f.other]
        try f.ws.closeAccountVoidingHistory(accountID: f.closing, nowEpoch: testEpoch + 10)

        let conflict = try #require(f.ws.syncConflicts[f.closingConflict])
        #expect(conflict.status == .dismissed)
        #expect(conflict.resolvedAtEpoch == testEpoch + 10)
        let discrepancy = try #require(f.ws.snapshotDiscrepancies[f.closingDiscrepancy])
        #expect(discrepancy.status == .resolved)
        #expect(discrepancy.resolutionReason == .manualAttestation)
        #expect(discrepancy.adjustmentTransactionID == nil)
        #expect(settledAudits(f.ws, f.closingConflict.description).count == 1)
        #expect(settledAudits(f.ws, f.closingDiscrepancy.description).count == 1)

        #expect(f.ws.syncConflicts[f.otherConflict]?.status == .open, "another account's conflict stays open")
        #expect(f.ws.snapshotDiscrepancies[f.otherDiscrepancy]?.status == .open, "another account's discrepancy stays open")
        #expect(try f.ws.projection().registerBalances[f.other] == otherBalanceBefore)

        // The published snapshot still validates and resolves the account
        // through the import even though the manual row was removed.
        let snapshot = f.ws.snapshot()
        _ = try BudgetWorkspace(snapshot: snapshot)
        #expect(snapshot.accountID(forConflict: conflict) == f.closing)
        #expect(snapshot.openReviewItemCount(forClosedAccount: f.closing) == 0)
    }

    @Test("Plain Close Account settles review items too")
    func plainCloseSettlesItems() throws {
        var ws = try makeWorkspace(timeZone: "UTC")
        let empty = try ws.addAccount(name: "Old Savings", type: .savings, onBudget: true,
                                      openingBalance: 0, openingDate: date("2025-01-01"), nowEpoch: testEpoch)
        let idValue = try ws.upsertOpenSnapshotDiscrepancy(
            accountID: empty, observedEpoch: testEpoch, remoteBalanceMilliunits: usd(1),
            localRegisterMilliunits: 0, nowEpoch: testEpoch)
        let id = try #require(idValue)
        try ws.closeAccount(accountID: empty, nowEpoch: testEpoch + 5)
        #expect(ws.snapshotDiscrepancies[id]?.status == .resolved)
        #expect(ws.snapshotDiscrepancies[id]?.resolutionReason == .manualAttestation)
    }

    @Test("Items stranded on an already-closed account can be dismissed; open accounts are refused")
    func dismissStrandedItems() throws {
        var f = try fixture()
        try f.ws.closeAccountVoidingHistory(accountID: f.closing, nowEpoch: testEpoch + 10)
        // Recreate the pre-fix state: open items on a closed account.
        let voidedImport = try #require(f.ws.transactions.values.first {
            $0.accountID == f.closing && $0.postingState == .voided
        })
        let record = try #require(f.ws.simpleFINImports[voidedImport.id])
        var dismissedDuplicate = try #require(f.ws.syncConflicts[f.closingConflict])
        dismissedDuplicate.status = .open
        dismissedDuplicate.resolvedAtEpoch = nil
        f.ws.setSyncConflict(dismissedDuplicate)
        _ = record
        let strandedValue = try f.ws.upsertOpenSnapshotDiscrepancy(
            accountID: f.closing, observedEpoch: testEpoch + 86_400, remoteBalanceMilliunits: usd(480),
            localRegisterMilliunits: usd(500), nowEpoch: testEpoch + 20)
        let stranded = try #require(strandedValue)
        #expect(f.ws.snapshot().openReviewItemCount(forClosedAccount: f.closing) == 2)
        #expect(f.ws.snapshot().closedAccountID(forDiscrepancy: f.ws.snapshotDiscrepancies[f.otherDiscrepancy]!) == nil)

        #expect(throws: MutationError.accountNotClosed) {
            try f.ws.dismissReviewItems(forClosedAccount: f.other, nowEpoch: testEpoch + 30)
        }
        #expect(throws: MutationError.accountNotFound) {
            try f.ws.dismissReviewItems(forClosedAccount: AccountID(), nowEpoch: testEpoch + 30)
        }

        let revision = f.ws.budget.revision
        let cleanup = try f.ws.dismissReviewItems(forClosedAccount: f.closing, nowEpoch: testEpoch + 30)
        #expect(cleanup == ClosedAccountReviewCleanup(dismissedConflicts: 1, resolvedDiscrepancies: 1))
        #expect(f.ws.budget.revision == revision + 1)
        #expect(f.ws.snapshotDiscrepancies[stranded]?.status == .resolved)
        #expect(f.ws.syncConflicts[f.closingConflict]?.status == .dismissed)
        #expect(f.ws.syncConflicts[f.otherConflict]?.status == .open)
        #expect(f.ws.snapshotDiscrepancies[f.otherDiscrepancy]?.status == .open)

        // A second run is a no-op and does not bump the revision.
        let again = try f.ws.dismissReviewItems(forClosedAccount: f.closing, nowEpoch: testEpoch + 40)
        #expect(again.total == 0)
        #expect(f.ws.budget.revision == revision + 1)
    }

    @Test("Dismissals persist through the database constraints and reload")
    func dismissalPersists() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledgerbar-closed-reviews-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LedgerWorkspaceStore(databaseURL: directory.appendingPathComponent("db.sqlite"))
        let service = BudgetMutationService(store: store)
        _ = try await service.createBudget(name: "P", currency: "USD", timeZoneIdentifier: "UTC",
                                           firstMonth: month("2025-01"), currentMonth: month("2025-01"), nowEpoch: testEpoch)
        let ids = try await service.transact(nowEpoch: testEpoch) { ws in
            let account = try ws.addAccount(name: "Dup", type: .checking, onBudget: true,
                                            openingBalance: usd(50), openingDate: date("2025-01-01"), nowEpoch: testEpoch)
            let row = try ws.importPostedTransaction(accountID: account, connectionKey: "c", remoteAccountID: "a",
                                                     remoteTransactionID: "t", postedEpoch: try ws.calendar.noonEpoch(of: date("2025-01-03")),
                                                     payeeName: "P", amountMilliunits: -usd(5), nowEpoch: testEpoch)
            let record = ws.simpleFINImports[row]!
            try ws.closeAccountVoidingHistory(accountID: account, nowEpoch: testEpoch)
            let conflict = ws.recordSyncConflictIfNew(
                transactionID: row, simpleFINImportID: record.id, eventKind: .remoteDisappeared,
                oldMetadata: SyncConflictMetadata(note: "a"), newMetadata: SyncConflictMetadata(note: "b"), nowEpoch: testEpoch)!
            let discrepancy = try ws.upsertOpenSnapshotDiscrepancy(
                accountID: account, observedEpoch: testEpoch, remoteBalanceMilliunits: usd(45),
                localRegisterMilliunits: usd(50), nowEpoch: testEpoch)!
            try ws.bumpRevision()
            return (account, conflict, discrepancy)
        }
        _ = try await service.transact(nowEpoch: testEpoch + 1) { ws in
            try ws.dismissReviewItems(forClosedAccount: ids.0, nowEpoch: testEpoch + 1)
        }
        let reloaded = try await BudgetMutationService(store: store).loadActive()
        #expect(reloaded.syncConflicts.first { $0.id == ids.1 }?.status == .dismissed)
        let discrepancy = reloaded.snapshotDiscrepancies.first { $0.id == ids.2 }
        #expect(discrepancy?.status == .resolved)
        #expect(discrepancy?.resolutionReason == .manualAttestation)
    }
}

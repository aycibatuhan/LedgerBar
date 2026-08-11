import Foundation
import GRDB
import Testing
@testable import LedgerCore

/// M5.1/M5.9 foundations: the sync schema shape, normalized SimpleFIN mirror
/// tables, blob backward compatibility, and the single-transaction
/// import-plus-cursor commit (`syncTransact`).
@Suite("SimpleFIN sync persistence — schema, mirrors, atomic commit")
struct SyncPersistenceTests {
    private struct DeliberateFailure: Error {}

    private func temporaryDatabaseURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledgerbar-syncpersist-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("LedgerBar.sqlite")
    }

    private func makeService(at url: URL) async throws -> BudgetMutationService {
        let store = try LedgerWorkspaceStore(databaseURL: url)
        let service = BudgetMutationService(store: store)
        _ = try await service.createBudget(
            name: "Sync",
            currency: "USD",
            timeZoneIdentifier: "UTC",
            firstMonth: month("2025-01"),
            currentMonth: month("2025-01"),
            nowEpoch: testEpoch
        )
        return service
    }

    @Test func v5SchemaShape() async throws {
        let url = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        _ = try await makeService(at: url)

        let queue = try DatabaseQueue(path: url.path)
        func columns(_ table: String) throws -> Set<String> {
            try queue.read { db in
                Set(try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))").map { $0["name"] as String })
            }
        }
        let imports = try columns("simplefin_imports")
        #expect(imports.isSuperset(of: [
            "id", "budget_id", "transaction_id", "connection_id",
            "remote_connection_key", "remote_account_id", "remote_transaction_id",
            "remote_amount", "remote_posted_epoch", "remote_transacted_epoch",
            "remote_payload_hash", "protocol_version", "last_seen_epoch",
            "remote_disappearance_acknowledged"
        ]))
        let conflicts = try columns("sync_conflicts")
        #expect(conflicts.isSuperset(of: [
            "id", "transaction_id", "simplefin_import_id", "event_kind",
            "status", "old_metadata", "new_metadata"
        ]))
        let discrepancies = try columns("snapshot_discrepancies")
        #expect(discrepancies.isSuperset(of: [
            "id", "account_id", "simplefin_link_identity", "snapshot_epoch", "remote_balance_milliunits",
            "local_register_milliunits", "difference_milliunits", "status",
            "resolution_reason", "adjustment_transaction_id"
        ]))

        // The event-kind and status CHECK constraints are live.
        try await queue.write { db in
            do {
                try db.execute(
                    sql: "INSERT INTO sync_conflicts(id, budget_id, event_kind, status, old_metadata, new_metadata, created_at_epoch) SELECT 'x', id, 'bogusKind', 'open', x'00', x'00', 0 FROM budgets LIMIT 1"
                )
                Issue.record("bogus event_kind was accepted")
            } catch {
                // expected: CHECK violation
            }
        }
    }

    @Test func v6MigrationAddsNullableSnapshotDiscrepancyLinkIdentity() async throws {
        let url = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let queue = try DatabaseQueue(path: url.path)
        let migrator = LedgerDatabaseSchema.migrator

        try migrator.migrate(queue, upTo: "v5-sync-resolution")
        let before = try await queue.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(snapshot_discrepancies)")
        }
        #expect(!before.contains { ($0["name"] as String) == "simplefin_link_identity" })

        try migrator.migrate(queue)
        let added = try await queue.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(snapshot_discrepancies)").first {
                ($0["name"] as String) == "simplefin_link_identity"
            }
        }
        #expect((added?["notnull"] as Int?) == 0)
        #expect(added?["dflt_value"] as String? == nil)
    }

    @Test func v9MigrationEnforcesOneLocalAccountPerSimpleFINConnection() async throws {
        let url = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        _ = try await makeService(at: url)
        let queue = try DatabaseQueue(path: url.path)

        let index = try await queue.read { db in
            try Row.fetchAll(db, sql: "PRAGMA index_list(simplefin_links)").first {
                ($0["name"] as String) == "simplefin_links_one_local_account_per_connection"
            }
        }
        #expect((index?["unique"] as Int?) == 1)
        #expect((index?["partial"] as Int?) == 1)
        let columns = try await queue.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM pragma_index_info('simplefin_links_one_local_account_per_connection') ORDER BY seqno"
            )
        }
        #expect(columns == ["connection_id", "local_account_id"])
    }

    @Test func v9MigrationClearsLegacyDerivedMirrorBeforeAddingConstraint() async throws {
        let url = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let queue = try DatabaseQueue(path: url.path)
        let migrator = LedgerDatabaseSchema.migrator
        try migrator.migrate(queue, upTo: "v8-derived-projection-cache")

        try await queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO budgets(
                    id, name, currency, timezone_identifier, first_month,
                    last_observed_month, next_local_source_sequence,
                    created_at_epoch, revision
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    "budget-v9", "Migration fixture", "USD", "UTC", "2025-01",
                    "2025-01", 0, testEpoch, 0
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO accounts(
                    id, budget_id, name, type, on_budget, closed, currency,
                    history_incomplete, created_at_epoch
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    "account-v9", "budget-v9", "Checking", "checking", 1, 0,
                    "USD", 0, testEpoch
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO simplefin_connections(
                    id, budget_id, status, keychain_item_ref,
                    credential_generation, created_at_epoch
                ) VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    "primary", "budget-v9", "active", nil, 1, testEpoch
                ]
            )
            for suffix in ["one", "two"] {
                try db.execute(
                    sql: """
                    INSERT INTO simplefin_links(
                        id, budget_id, connection_id, local_account_id,
                        remote_connection_key, remote_account_id,
                        sign_normalization, status
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        "link-\(suffix)", "budget-v9", "primary", "account-v9",
                        "remote-connection-\(suffix)", "remote-account-\(suffix)",
                        1, "active"
                    ]
                )
            }
        }

        try migrator.migrate(queue)
        let remaining = try await queue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM simplefin_links WHERE budget_id = ?",
                arguments: ["budget-v9"]
            ) ?? 0
        }
        #expect(remaining == 0)
        let index = try await queue.read { db in
            try Row.fetchAll(db, sql: "PRAGMA index_list(simplefin_links)").first {
                ($0["name"] as String?) == "simplefin_links_one_local_account_per_connection"
            }
        }
        #expect((index?["unique"] as Int?) == 1)
        #expect((index?["partial"] as Int?) == 1)
    }

    @Test func upsertLinkRejectsSecondRemoteIdentityForOneLocalAccount() throws {
        let localAccountID = AccountID()
        let first = SimpleFINAccountLink(
            connectionKey: "conn:primary",
            remoteAccountID: "remote-1",
            localAccountID: localAccountID
        )
        let second = SimpleFINAccountLink(
            connectionKey: "conn:primary",
            remoteAccountID: "remote-2",
            localAccountID: localAccountID
        )
        var state = SimpleFINConnectionState(
            status: .active,
            keychainItemID: "synthetic-keychain-item",
            baseHost: "bridge.simplefin.org",
            basePort: 443,
            credentialGeneration: 1,
            createdAtEpoch: testEpoch,
            links: [first]
        )

        let inserted = state.upsertLink(second)
        #expect(!inserted)
        #expect(state.links == [first])
    }

    @Test("account-less links remain allowed to coexist")
    func accountlessLinksDoNotTripLocalAccountUniqueness() throws {
        var state = SimpleFINConnectionState(
            status: .active,
            keychainItemID: "synthetic-keychain-item",
            baseHost: "bridge.simplefin.org",
            basePort: 443,
            credentialGeneration: 1,
            createdAtEpoch: testEpoch
        )
        let first = SimpleFINAccountLink(
            connectionKey: "conn:primary",
            remoteAccountID: "remote-1",
            localAccountID: nil
        )
        let second = SimpleFINAccountLink(
            connectionKey: "conn:primary",
            remoteAccountID: "remote-2",
            localAccountID: nil
        )

        let insertedFirst = state.upsertLink(first)
        let insertedSecond = state.upsertLink(second)
        #expect(insertedFirst)
        #expect(insertedSecond)
        #expect(state.links.count == 2)
    }

    @Test("connection, link, and trusted-host mirrors track incremental state updates")
    func connectionLinkAndHostMirrorsTrackIncrementalUpdates() async throws {
        let url = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let service = try await makeService(at: url)
        let now = testEpoch + 40 * 86_400
        let accountID = try await service.transact(nowEpoch: now) { workspace in
            try workspace.addAccount(
                name: "Checking", type: .checking, onBudget: true,
                openingBalance: usd(100), openingDate: date("2025-01-02"), nowEpoch: testEpoch
            )
        }
        let host = try SimpleFINHost(host: "beta-bridge.simplefin.org")
        let link = SimpleFINAccountLink(
            connectionKey: "conn:c1",
            remoteAccountID: "acct-1",
            localAccountID: accountID,
            lastSuccessfulPostedEpoch: testEpoch
        )
        try await service.updateSimpleFINState(nowEpoch: now) { state in
            state = SimpleFINConnectionState(
                status: .active,
                keychainItemID: "synthetic-keychain-reference",
                baseHost: "bridge.simplefin.org",
                basePort: 443,
                credentialGeneration: 1,
                createdAtEpoch: testEpoch,
                links: [link],
                extraTrustedHosts: [host]
            )
        }

        let queue = try DatabaseQueue(path: url.path)
        let budgetID = try #require(await service.currentSnapshot()?.budget.id.description)
        let firstRows: (connections: Int, links: Int, hosts: Int, cursor: Int64?) = try await queue.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM simplefin_connections WHERE budget_id = ?", arguments: [budgetID]) ?? 0,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM simplefin_links WHERE budget_id = ?", arguments: [budgetID]) ?? 0,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM trusted_hosts WHERE budget_id = ?", arguments: [budgetID]) ?? 0,
                try Int64.fetchOne(db, sql: "SELECT cursor_posted_epoch FROM simplefin_links WHERE budget_id = ?", arguments: [budgetID])
            )
        }
        #expect(firstRows.connections == 1)
        #expect(firstRows.links == 1)
        #expect(firstRows.hosts == 1)
        #expect(firstRows.cursor == testEpoch)

        let updatedCursor = testEpoch + 8 * 86_400
        try await service.updateSimpleFINState(nowEpoch: now + 1) { state in
            guard var updated = state,
                  var updatedLink = updated.link(identity: link.identity) else {
                throw DeliberateFailure()
            }
            updatedLink.lastSuccessfulPostedEpoch = updatedCursor
            updatedLink.pause(reason: .protocolError, message: "synthetic provider failure")
            updated.upsertLink(updatedLink)
            state = updated
        }

        let secondRows: (cursor: Int64?, status: String?, pause: String?, diagnostic: String?) = try await queue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT cursor_posted_epoch, status, pause_reason, last_error_redacted FROM simplefin_links WHERE budget_id = ?",
                arguments: [budgetID]
            )
            return (row?["cursor_posted_epoch"], row?["status"], row?["pause_reason"], row?["last_error_redacted"])
        }
        #expect(secondRows.cursor == updatedCursor)
        #expect(secondRows.status == SimpleFINLinkStatus.paused.rawValue)
        #expect(secondRows.pause == SimpleFINLinkPauseReason.protocolError.rawValue)
        #expect(secondRows.diagnostic == "synthetic provider failure")

        let coldStore = try LedgerWorkspaceStore(databaseURL: url)
        let coldService = BudgetMutationService(store: coldStore)
        _ = try await coldService.loadFirst()
        let reloaded = try #require(await coldService.simpleFINState())
        #expect(reloaded.link(identity: link.identity)?.lastSuccessfulPostedEpoch == updatedCursor)
        #expect(reloaded.link(identity: link.identity)?.pauseReason == .protocolError)
        #expect(reloaded.extraTrustedHosts == [host])
    }

    @Test func v5MigrationAddsDisappearanceAcknowledgementWithFalseDefault() async throws {
        let url = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let queue = try DatabaseQueue(path: url.path)
        let migrator = LedgerDatabaseSchema.migrator

        try migrator.migrate(queue, upTo: "v4-simplefin-sync")
        let v4Columns = try await queue.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(simplefin_imports)")
        }
        #expect(!v4Columns.contains { ($0["name"] as String) == "remote_disappearance_acknowledged" })
        try await queue.write { db in
            try db.execute(
                sql: "INSERT INTO budgets(id, name, currency, timezone_identifier, first_month, last_observed_month, next_local_source_sequence, created_at_epoch, revision) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                arguments: ["budget", "Synthetic", "USD", "UTC", "2025-01", "2025-01", 1, testEpoch, 0]
            )
            try db.execute(
                sql: "INSERT INTO accounts(id, budget_id, name, type, on_budget, closed, currency, history_incomplete, created_at_epoch) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                arguments: ["account", "budget", "Synthetic", "checking", 1, 0, "USD", 0, testEpoch]
            )
            try db.execute(
                sql: "INSERT INTO transactions(id, budget_id, account_id, source_kind, date, effective_at_epoch, source_order_key, amount_milliunits, cleared, approved, posting_state, kind) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                arguments: [
                    "transaction", "budget", "account", "simplefin", "2025-01-02",
                    testEpoch, "remote:synthetic", -1_000, "cleared", 0, "needsCategory", "normal"
                ]
            )
            try db.execute(
                sql: "INSERT INTO simplefin_imports(id, budget_id, transaction_id, remote_connection_key, remote_account_id, remote_transaction_id, remote_amount, remote_posted_epoch, remote_payload_hash, protocol_version, last_seen_epoch) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                arguments: [
                    "import", "budget", "transaction", "synthetic-connection", "synthetic-account",
                    "synthetic-transaction", "-1.00", testEpoch, "synthetic-hash", "legacy", testEpoch
                ]
            )
        }

        try migrator.migrate(queue)
        let addedColumn = try await queue.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(simplefin_imports)").first {
                ($0["name"] as String) == "remote_disappearance_acknowledged"
            }
        }
        #expect((addedColumn?["notnull"] as Int?) == 1)
        #expect((addedColumn?["dflt_value"] as String?) == "0")
        let migratedValue: Int? = try await queue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT remote_disappearance_acknowledged FROM simplefin_imports WHERE id = 'import'"
            )
        }
        #expect(migratedValue == 0)
    }

    @Test func mirrorRoundTripAndDeleteOrder() async throws {
        let url = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let service = try await makeService(at: url)

        let now = testEpoch + 40 * 86_400
        let seeded: (account: AccountID, transaction: TransactionID, record: SimpleFINImportRecord) =
            try await service.transact(nowEpoch: now) { workspace in
                let accountID = try workspace.addAccount(
                    name: "Checking", type: .checking, onBudget: true,
                    openingBalance: usd(100), openingDate: date("2025-01-02"), nowEpoch: testEpoch
                )
                let transactionID = try workspace.importPostedTransaction(
                    accountID: accountID,
                    connectionKey: "conn:c1",
                    remoteAccountID: "acct-1",
                    remoteTransactionID: "t-1",
                    postedEpoch: testEpoch + 4 * 86_400,
                    payeeName: "Grocer",
                    amountMilliunits: usd(-12),
                    nowEpoch: now
                )
                let record = SimpleFINImportRecord(
                    budgetID: workspace.budget.id,
                    transactionID: transactionID,
                    connectionKey: "conn:c1",
                    remoteAccountID: "acct-1",
                    remoteTransactionID: "t-1",
                    remoteAmountDecimalString: "-12.00",
                    remotePostedEpoch: testEpoch + 4 * 86_400,
                    remoteTransactedEpoch: testEpoch + 3 * 86_400,
                    remotePayloadHash: "aa11",
                    lastSeenEpoch: now,
                    remoteDisappearanceAcknowledged: true
                )
                workspace.setSimpleFINImport(record)
                workspace.setSyncConflict(SyncConflictRow(
                    budgetID: workspace.budget.id,
                    transactionID: transactionID,
                    simpleFINImportID: record.id,
                    eventKind: .remoteChanged,
                    oldMetadata: SyncConflictMetadata(
                        amountDecimalString: "-12.00",
                        transactedEpoch: testEpoch + 3 * 86_400,
                        payloadHash: "aa11"
                    ),
                    newMetadata: SyncConflictMetadata(
                        amountDecimalString: "-13.00",
                        transactedEpoch: testEpoch + 4 * 86_400,
                        payloadHash: "bb22"
                    ),
                    createdAtEpoch: now
                ))
                workspace.setSnapshotDiscrepancy(SnapshotDiscrepancyRow(
                    budgetID: workspace.budget.id,
                    accountID: accountID,
                    simpleFINLinkIdentity: SimpleFINAccountLink.identity(
                        connectionKey: "conn:c1", remoteAccountID: "acct-1"
                    ),
                    observedEpoch: now,
                    remoteBalanceMilliunits: usd(90),
                    localRegisterMilliunits: usd(88),
                    differenceMilliunits: usd(2),
                    createdAtEpoch: now
                ))
                return (accountID, transactionID, record)
            }

        let queue = try DatabaseQueue(path: url.path)
        func count(_ table: String) throws -> Int {
            try queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? -1 }
        }
        #expect(try count("simplefin_imports") == 1)
        #expect(try count("sync_conflicts") == 1)
        #expect(try count("snapshot_discrepancies") == 1)
        let mirroredAmount: String? = try await queue.read { db in
            try String.fetchOne(db, sql: "SELECT remote_amount FROM simplefin_imports WHERE transaction_id = ?", arguments: [seeded.transaction.description])
        }
        #expect(mirroredAmount == "-12.00")
        let mirroredAcknowledgement: Int? = try await queue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT remote_disappearance_acknowledged FROM simplefin_imports WHERE transaction_id = ?",
                arguments: [seeded.transaction.description]
            )
        }
        #expect(mirroredAcknowledgement == 1)

        do {
            try await queue.write { db in
                try db.execute(
                    sql: "UPDATE simplefin_imports SET remote_disappearance_acknowledged = 2 WHERE transaction_id = ?",
                    arguments: [seeded.transaction.description]
                )
            }
            Issue.record("invalid disappearance acknowledgement was accepted")
        } catch {
            // expected: CHECK violation
        }

        // Delete-order regression: with the mirrors populated, every later
        // save truncates and reinserts transactions/accounts; the RESTRICT
        // edges must not fire.
        try await service.transact(nowEpoch: now + 1) { workspace in
            _ = try workspace.addAccount(
                name: "Savings", type: .savings, onBudget: true,
                openingBalance: usd(10), openingDate: date("2025-01-03"), nowEpoch: testEpoch
            )
        }
        #expect(try count("simplefin_imports") == 1)
        #expect(try count("sync_conflicts") == 1)
        #expect(try count("snapshot_discrepancies") == 1)

        // Cold reload rehydrates the records from the workspace blob.
        let coldStore = try LedgerWorkspaceStore(databaseURL: url)
        let coldService = BudgetMutationService(store: coldStore)
        let snapshot = try await coldService.loadFirst()
        #expect(snapshot.simpleFINImports == [seeded.record])
        #expect(snapshot.syncConflicts.count == 1)
        #expect(snapshot.syncConflicts.first?.eventKind == .remoteChanged)
        #expect(snapshot.syncConflicts.first?.status == .open)
        #expect(snapshot.syncConflicts.first?.oldMetadata.transactedEpoch == testEpoch + 3 * 86_400)
        #expect(snapshot.syncConflicts.first?.newMetadata.transactedEpoch == testEpoch + 4 * 86_400)
        #expect(snapshot.snapshotDiscrepancies.count == 1)
        #expect(snapshot.snapshotDiscrepancies.first?.differenceMilliunits == usd(2))
        #expect(snapshot.snapshotDiscrepancies.first?.simpleFINLinkIdentity == SimpleFINAccountLink.identity(
            connectionKey: "conn:c1", remoteAccountID: "acct-1"
        ))
        let reloaded = try BudgetWorkspace(snapshot: snapshot)
        #expect(reloaded.simpleFINImportRecord(
            connectionKey: "conn:c1", remoteAccountID: "acct-1", remoteTransactionID: "t-1"
        ) == seeded.record)
    }

    @Test func syncTransactCommitsBothBlobsAtomically() async throws {
        let url = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let service = try await makeService(at: url)

        let now = testEpoch + 40 * 86_400
        let accountID = try await service.transact(nowEpoch: now) { workspace in
            try workspace.addAccount(
                name: "Checking", type: .checking, onBudget: true,
                openingBalance: usd(100), openingDate: date("2025-01-02"), nowEpoch: testEpoch
            )
        }
        let link = SimpleFINAccountLink(
            connectionKey: "conn:c1", remoteAccountID: "acct-1",
            localAccountID: accountID, lastSuccessfulPostedEpoch: testEpoch
        )
        try await service.updateSimpleFINState(nowEpoch: now) { state in
            var created = SimpleFINConnectionState(
                status: .active, keychainItemID: "item", baseHost: "bridge.simplefin.org",
                basePort: 443, credentialGeneration: 1, createdAtEpoch: testEpoch
            )
            created.upsertLink(link)
            state = created
        }

        // Success: imports and cursor land in one commit.
        let newCursor = testEpoch + 6 * 86_400
        try await service.syncTransact(nowEpoch: now) { workspace, state in
            _ = try workspace.importPostedTransaction(
                accountID: accountID,
                connectionKey: "conn:c1",
                remoteAccountID: "acct-1",
                remoteTransactionID: "t-1",
                postedEpoch: testEpoch + 6 * 86_400,
                payeeName: "Grocer",
                amountMilliunits: usd(-5),
                nowEpoch: now
            )
            guard var updated = state, var storedLink = updated.link(identity: link.identity) else {
                throw DeliberateFailure()
            }
            storedLink.lastSuccessfulPostedEpoch = newCursor
            updated.upsertLink(storedLink)
            state = updated
        }
        let committedState = try await service.simpleFINState()
        #expect(committedState?.link(identity: link.identity)?.lastSuccessfulPostedEpoch == newCursor)
        let committedSnapshot = await service.currentSnapshot()
        #expect(committedSnapshot?.transactions.contains { $0.sourceKind == .simplefin } == true)

        // Failure after mutating both: neither the import nor the cursor may
        // survive, in memory or on disk.
        do {
            try await service.syncTransact(nowEpoch: now + 1) { workspace, state in
                _ = try workspace.importPostedTransaction(
                    accountID: accountID,
                    connectionKey: "conn:c1",
                    remoteAccountID: "acct-1",
                    remoteTransactionID: "t-2",
                    postedEpoch: testEpoch + 7 * 86_400,
                    payeeName: "Grocer",
                    amountMilliunits: usd(-7),
                    nowEpoch: now + 1
                )
                if var updated = state, var storedLink = updated.link(identity: link.identity) {
                    storedLink.lastSuccessfulPostedEpoch = testEpoch + 9 * 86_400
                    updated.upsertLink(storedLink)
                    state = updated
                }
                throw DeliberateFailure()
            }
            Issue.record("syncTransact should have rethrown the body failure")
        } catch is DeliberateFailure {
            // expected
        }

        let coldStore = try LedgerWorkspaceStore(databaseURL: url)
        let coldService = BudgetMutationService(store: coldStore)
        let coldSnapshot = try await coldService.loadFirst()
        let coldState = try await coldService.simpleFINState()
        #expect(coldSnapshot.transactions.filter { $0.sourceKind == .simplefin }.count == 1)
        #expect(coldState?.link(identity: link.identity)?.lastSuccessfulPostedEpoch == newCursor)
    }

    @Test func syncTransactPersistsEngineDiscrepancyPauseAndCanonicalLinkIdentity() async throws {
        let url = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let service = try await makeService(at: url)
        let now = testEpoch + 20 * 86_400
        let accountID = try await service.transact(nowEpoch: now) { workspace in
            try workspace.addAccount(
                name: "Checking", type: .checking, onBudget: true,
                openingBalance: usd(100), openingDate: date("2025-01-02"), nowEpoch: testEpoch
            )
        }
        let link = SimpleFINAccountLink(
            connectionKey: "conn:c1",
            remoteAccountID: "acct-1",
            localAccountID: accountID,
            lastSuccessfulPostedEpoch: testEpoch + 5 * 86_400
        )
        try await service.updateSimpleFINState(nowEpoch: now) { state in
            let connection = SimpleFINConnectionState(
                status: .active,
                keychainItemID: "synthetic-item-reference",
                baseHost: "bridge.simplefin.org",
                basePort: 443,
                credentialGeneration: 1,
                createdAtEpoch: testEpoch,
                links: [link]
            )
            state = connection
        }
        let response = try SimpleFINAccountsResponse(accounts: [
            SimpleFINRemoteAccount(
                id: "acct-1",
                name: "Remote Checking",
                currency: "USD",
                balance: "90.00",
                balanceDateEpoch: testEpoch + 10 * 86_400,
                connectionID: "c1",
                transactions: [
                    SimpleFINRemoteTransaction(
                        id: "t-1",
                        amount: "-3.00",
                        postedEpoch: testEpoch + 7 * 86_400,
                        payee: "Synthetic Payee"
                    )
                ]
            )
        ])

        let outcome = try await service.syncTransact(nowEpoch: now) { workspace, state in
            guard var updated = state,
                  var storedLink = updated.link(identity: link.identity) else {
                throw DeliberateFailure()
            }
            let outcome = try SimpleFINSyncEngine.applyAccountSync(
                response: response,
                link: &storedLink,
                window: .recurring(requestStartEpoch: testEpoch + 5 * 86_400),
                workspace: &workspace,
                nowEpoch: now
            )
            updated.upsertLink(storedLink)
            state = updated
            return outcome
        }

        #expect(outcome.pause == .snapshotDiscrepancy)
        #expect(outcome.newCursor == testEpoch + 7 * 86_400)
        let persistedState = try await service.simpleFINState()
        #expect(persistedState?.link(identity: link.identity)?.status == .paused)
        #expect(persistedState?.link(identity: link.identity)?.pauseReason == .snapshotDiscrepancy)
        let snapshot = try #require(await service.currentSnapshot())
        let discrepancy = try #require(snapshot.snapshotDiscrepancies.first)
        #expect(discrepancy.simpleFINLinkIdentity == link.identity)
        #expect(discrepancy.localRegisterMilliunits == usd(97))
        #expect(discrepancy.remoteBalanceMilliunits == usd(90))
    }

    @Test func initialLinkSyncTransactCommitsAccountImportsCursorAndDiscrepancyPause() async throws {
        let url = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let service = try await makeService(at: url)
        let now = testEpoch + 20 * 86_400
        let link = SimpleFINAccountLink(
            connectionKey: "conn:c-initial",
            remoteAccountID: "acct-initial",
            localAccountID: nil
        )
        try await service.updateSimpleFINState(nowEpoch: now) { state in
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
        let response = try SimpleFINAccountsResponse(accounts: [
            SimpleFINRemoteAccount(
                id: link.remoteAccountID,
                name: "Remote Checking",
                currency: "USD",
                balance: "90.00",
                balanceDateEpoch: testEpoch + 10 * 86_400,
                connectionID: "c-initial",
                transactions: [
                    SimpleFINRemoteTransaction(
                        id: "t-initial",
                        amount: "-3.00",
                        postedEpoch: testEpoch + 7 * 86_400,
                        payee: "Synthetic Payee"
                    )
                ]
            )
        ])

        let commit = try await service.syncTransact(
            nowEpoch: now,
            expectedCredentialPin: SimpleFINConnectionPin(
                itemID: "synthetic-item-reference",
                credentialGeneration: 1
            )
        ) { workspace, updated in
            let accountID = try workspace.addAccount(
                name: "Checking",
                type: .checking,
                onBudget: true,
                openingBalance: usd(100),
                openingDate: date("2025-01-02"),
                nowEpoch: now
            )
            try workspace.markAccountHistoryIncomplete(accountID)
            var boundLink = link
            boundLink.localAccountID = accountID
            let outcome = try SimpleFINSyncEngine.applyAccountSync(
                response: response,
                link: &boundLink,
                window: .initialLinkWithSnapshot(
                    startEpoch: testEpoch + 5 * 86_400,
                    balanceDateEpoch: testEpoch + 10 * 86_400,
                    snapshotBalanceMilliunits: usd(90)
                ),
                workspace: &workspace,
                nowEpoch: now
            )
            guard outcome.pause == nil || outcome.pause == .snapshotDiscrepancy else {
                throw DeliberateFailure()
            }
            updated.upsertLink(boundLink)
            return (accountID, outcome)
        }

        #expect(commit.1.pause == SimpleFINLinkPauseReason.snapshotDiscrepancy)
        #expect(commit.1.newCursor == testEpoch + 10 * 86_400)
        let snapshot = try #require(await service.currentSnapshot())
        #expect(snapshot.accounts.contains { $0.id == commit.0 })
        #expect(snapshot.simpleFINImports.contains { $0.remoteTransactionID == "t-initial" })
        let discrepancy = try #require(snapshot.snapshotDiscrepancies.first)
        #expect(discrepancy.simpleFINLinkIdentity == link.identity)
        #expect(discrepancy.remoteBalanceMilliunits == usd(90))
        #expect(discrepancy.localRegisterMilliunits == usd(97))
        let persistedState = try #require(await service.simpleFINState())
        let persistedLink = try #require(persistedState.link(identity: link.identity))
        #expect(persistedLink.localAccountID == commit.0)
        #expect(persistedLink.lastSuccessfulPostedEpoch == testEpoch + 10 * 86_400)
        #expect(persistedLink.pauseReason == SimpleFINLinkPauseReason.snapshotDiscrepancy)
    }

    @Test func preSyncRecordSnapshotPayloadStillDecodes() async throws {
        let url = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let service = try await makeService(at: url)
        let snapshot = await service.currentSnapshot()!

        // Simulate a payload written before the sync-record fields existed by
        // stripping the new keys from a freshly encoded snapshot.
        let data = try JSONEncoder().encode(snapshot)
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        object.removeValue(forKey: "simpleFINImports")
        object.removeValue(forKey: "syncConflicts")
        object.removeValue(forKey: "snapshotDiscrepancies")
        let stripped = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(BudgetWorkspaceSnapshot.self, from: stripped)
        #expect(decoded.simpleFINImports.isEmpty)
        #expect(decoded.syncConflicts.isEmpty)
        #expect(decoded.snapshotDiscrepancies.isEmpty)
        #expect(decoded.budget == snapshot.budget)
    }

    @Test func preResolutionImportRecordDefaultsDisappearanceAcknowledgementToFalse() throws {
        let record = SimpleFINImportRecord(
            budgetID: BudgetID(),
            transactionID: TransactionID(),
            connectionKey: "synthetic-connection",
            remoteAccountID: "synthetic-account",
            remoteTransactionID: "synthetic-transaction",
            remoteAmountDecimalString: "-1.00",
            remotePostedEpoch: testEpoch,
            remoteTransactedEpoch: testEpoch - 1,
            remotePayloadHash: "synthetic-hash",
            lastSeenEpoch: testEpoch,
            remoteDisappearanceAcknowledged: true
        )
        let data = try JSONEncoder().encode(record)
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        object.removeValue(forKey: "remoteDisappearanceAcknowledged")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(SimpleFINImportRecord.self, from: legacyData)
        #expect(decoded.remoteDisappearanceAcknowledged == false)
        #expect(decoded.remoteTransactedEpoch == record.remoteTransactedEpoch)
        #expect(decoded.remotePayloadHash == record.remotePayloadHash)

        let metadata = SyncConflictMetadata(
            amountDecimalString: "-1.00",
            transactedEpoch: testEpoch - 1,
            payloadHash: "synthetic-hash"
        )
        let metadataData = try JSONEncoder().encode(metadata)
        var metadataObject = try JSONSerialization.jsonObject(with: metadataData) as! [String: Any]
        metadataObject.removeValue(forKey: "transactedEpoch")
        let legacyMetadataData = try JSONSerialization.data(withJSONObject: metadataObject)
        let decodedMetadata = try JSONDecoder().decode(SyncConflictMetadata.self, from: legacyMetadataData)
        #expect(decodedMetadata.transactedEpoch == nil)
        #expect(decodedMetadata.amountDecimalString == metadata.amountDecimalString)
        #expect(decodedMetadata.payloadHash == metadata.payloadHash)
    }
}

import Foundation
import GRDB

public enum LedgerPersistenceError: Error, Equatable, Sendable {
    case workspaceNotFound
    case invalidSnapshot
    case concurrentModification(expectedRevision: Int64, actualRevision: Int64?)
    case concurrentSimpleFINStateModification
    case destinationAlreadyExists
    case backupIntegrityCheckFailed
}

public struct ProjectionCacheEntry: Sendable, Equatable {
    public var revision: Int64
    public var horizon: BudgetMonth?
    public var result: ProjectionResult

    public init(revision: Int64, horizon: BudgetMonth?, result: ProjectionResult) {
        self.revision = revision
        self.horizon = horizon
        self.result = result
    }
}

public enum ProjectionCacheWrite: Sendable {
    case keep
    case replace([ProjectionCacheEntry])
}

/// Registry entry for the budget switcher (D8).
public struct BudgetSummary: Sendable, Equatable, Identifiable {
    public var id: BudgetID
    public var name: String
    public var currency: String
    public var firstMonth: BudgetMonth
    public var currentMonth: BudgetMonth
    public var archived: Bool
    public var sortOrder: Int
    public var createdAtEpoch: Int64
    public var revision: Int64
}

public enum SimpleFINStateExpectation: Sendable {
    case unchecked
    case unchanged(SimpleFINConnectionState?)
}

/// GRDB-backed local store. The snapshot is the deterministic source of truth
/// for the value-type ledger; normalized tables are maintained in the same
/// transaction for SQL constraints, indexes, diagnostics, and future query
/// surfaces.
public final class LedgerWorkspaceStore: @unchecked Sendable {
    public let pool: AnyDatabaseWriter
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public convenience init(databaseURL: URL) throws {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Self.createPreUpgradeBackupIfNeeded(databaseURL: databaseURL)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let databasePool = try DatabasePool(path: databaseURL.path, configuration: configuration)
        try self.init(writer: databasePool)
    }

    /// The first migration of the financial-system series rebuilds the
    /// `transactions` mirror. Before an existing pre-v10 database is
    /// migrated, a verified sibling copy is written next to it
    /// (`<name>-before-v10.sqlite`) so the upgrade is recoverable with the
    /// documented manual restore. A new database, or one already at v10 or
    /// later, gets no copy; an existing copy is never overwritten.
    static func createPreUpgradeBackupIfNeeded(databaseURL: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: databaseURL.path) else { return }
        let backupURL = databaseURL.deletingPathExtension().appendingPathExtension("before-v10.sqlite")
        guard !fileManager.fileExists(atPath: backupURL.path) else { return }
        let needsBackup: Bool = try {
            let queue = try DatabaseQueue(path: databaseURL.path)
            return try queue.read { db in
                guard try db.tableExists("grdb_migrations"), try db.tableExists("budgets") else { return false }
                let applied = try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations")
                return !applied.contains { $0.hasPrefix("v10-") }
            }
        }()
        guard needsBackup else { return }
        let source = try DatabaseQueue(path: databaseURL.path)
        let destination = try DatabaseQueue(path: backupURL.path)
        try source.backup(to: destination)
        let integrity = try destination.read { db in try String.fetchOne(db, sql: "PRAGMA integrity_check") ?? "" }
        guard integrity.lowercased() == "ok" else {
            try? fileManager.removeItem(at: backupURL)
            throw LedgerPersistenceError.backupIntegrityCheckFailed
        }
    }

    /// A process-local fallback for rendering failure states when the normal
    /// filesystem-backed database cannot be opened. It is never used for
    /// production persistence or credential storage.
    public static func inMemory() throws -> LedgerWorkspaceStore {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let databaseQueue = try DatabaseQueue(path: ":memory:", configuration: configuration)
        return try LedgerWorkspaceStore(writer: databaseQueue)
    }

    private init(writer: any DatabaseWriter) throws {
        self.pool = AnyDatabaseWriter(writer)
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.encoder.outputFormatting = [.sortedKeys]
        try LedgerDatabaseSchema.migrator.migrate(pool)
    }

    public func create(_ workspace: BudgetWorkspace, nowEpoch: Int64 = 0) throws {
        try save(workspace, projectionCaches: .replace([]), nowEpoch: nowEpoch)
    }

    public func load(budgetID: BudgetID) throws -> BudgetWorkspace {
        let payload: Data? = try pool.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT payload FROM workspace_states WHERE budget_id = ?",
                arguments: [budgetID.description]
            )?["payload"]
        }
        guard let payload else { throw LedgerPersistenceError.workspaceNotFound }
        do {
            return try BudgetWorkspace(snapshot: decoder.decode(BudgetWorkspaceSnapshot.self, from: payload))
        } catch {
            throw LedgerPersistenceError.invalidSnapshot
        }
    }

    // MARK: - Assistant conversations (docs/LOCAL-AI.md A7)

    public func loadAssistantTranscript(budgetID: BudgetID) throws -> AssistantTranscript? {
        let payload: Data? = try pool.read { db in
            try Row.fetchOne(db, sql: "SELECT payload FROM assistant_conversations WHERE budget_id = ?", arguments: [budgetID.description])?["payload"]
        }
        guard let payload else { return nil }
        return try? decoder.decode(AssistantTranscript.self, from: payload)
    }

    public func saveAssistantTranscript(_ transcript: AssistantTranscript?, budgetID: BudgetID, nowEpoch: Int64) throws {
        try pool.write { db in
            if let transcript {
                let payload = try encoder.encode(transcript)
                try db.execute(sql: "INSERT INTO assistant_conversations(budget_id, payload, updated_at_epoch) VALUES (?, ?, ?) ON CONFLICT(budget_id) DO UPDATE SET payload = excluded.payload, updated_at_epoch = excluded.updated_at_epoch", arguments: [budgetID.description, payload, nowEpoch])
            } else {
                try db.execute(sql: "DELETE FROM assistant_conversations WHERE budget_id = ?", arguments: [budgetID.description])
            }
        }
    }

    // MARK: - Budget registry (docs/DESIGN.md D8)

    public func listBudgets() throws -> [BudgetSummary] {
        try pool.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT id, name, currency, first_month, last_observed_month, archived, sort_order, created_at_epoch, revision FROM budgets ORDER BY sort_order, created_at_epoch, id")
            return rows.compactMap { row in
                guard let idString: String = row["id"], let uuid = UUID(uuidString: idString),
                      let name: String = row["name"], let currency: String = row["currency"],
                      let firstString: String = row["first_month"], let first = BudgetMonth(string: firstString),
                      let currentString: String = row["last_observed_month"], let current = BudgetMonth(string: currentString) else { return nil }
                return BudgetSummary(
                    id: BudgetID(uuid), name: name, currency: currency, firstMonth: first, currentMonth: current,
                    archived: (row["archived"] as Int? ?? 0) == 1, sortOrder: row["sort_order"] as Int? ?? 0,
                    createdAtEpoch: row["created_at_epoch"] as Int64? ?? 0, revision: row["revision"] as Int64? ?? 0
                )
            }
        }
    }

    public static let activeBudgetSettingKey = "activeBudgetID"

    public func setting(_ key: String) throws -> String? {
        try pool.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM app_settings WHERE key = ?", arguments: [key])
        }
    }

    public func setSetting(_ key: String, value: String?, nowEpoch: Int64) throws {
        try pool.write { db in
            if let value {
                try db.execute(sql: "INSERT INTO app_settings(key, value, updated_at_epoch) VALUES (?, ?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at_epoch = excluded.updated_at_epoch", arguments: [key, value, nowEpoch])
            } else {
                try db.execute(sql: "DELETE FROM app_settings WHERE key = ?", arguments: [key])
            }
        }
    }

    /// The one physical deletion in the system: every row of one budget, in
    /// child-to-parent order, plus its state blobs, caches, and request log.
    /// Other budgets are untouched. The caller confirms and audits.
    public func deleteBudget(_ budgetID: BudgetID) throws {
        let id = budgetID.description
        try pool.write { db in
            try db.execute(sql: "DELETE FROM transfer_leg_snapshots WHERE transfer_pair_id IN (SELECT id FROM transfer_pairs WHERE budget_id = ?)", arguments: [id])
            for table in [
                "schedule_reviews", "schedule_occurrences", "schedules",
                "reports", "file_imports", "import_batches", "import_mappings",
                "sync_conflicts", "simplefin_imports", "snapshot_discrepancies",
                "trusted_hosts", "simplefin_links", "simplefin_connections",
                "reconciliation_transactions", "reconciliations",
                "reconciliation_membership", "transaction_splits", "transactions", "allocations",
                "closed_months", "audit_events", "automation_rules", "payees", "categories",
                "category_groups", "accounts", "transfer_pairs",
                "sync_request_log", "projection_caches", "simplefin_state", "assistant_conversations", "workspace_states"
            ] {
                try db.execute(sql: "DELETE FROM \(table) WHERE budget_id = ?", arguments: [id])
            }
            try db.execute(sql: "DELETE FROM budgets WHERE id = ?", arguments: [id])
            if try String.fetchOne(db, sql: "SELECT value FROM app_settings WHERE key = ?", arguments: [Self.activeBudgetSettingKey]) == id {
                try db.execute(sql: "DELETE FROM app_settings WHERE key = ?", arguments: [Self.activeBudgetSettingKey])
            }
        }
    }

    /// Revision observation for one budget only.
    public func observeRevisions(budgetID: BudgetID) -> AsyncThrowingStream<Int64, Error> {
        let id = budgetID.description
        let observation = ValueObservation.tracking { db in
            try Int64.fetchOne(db, sql: "SELECT COALESCE(revision, 0) FROM workspace_states WHERE budget_id = ?", arguments: [id]) ?? 0
        }
        let values = observation.values(in: pool)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await revision in values { continuation.yield(revision) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func loadFirstWorkspace() throws -> BudgetWorkspace {
        let payload: Data? = try pool.read { db in
            try Row.fetchOne(db, sql: "SELECT payload FROM workspace_states ORDER BY rowid LIMIT 1")?["payload"]
        }
        guard let payload else { throw LedgerPersistenceError.workspaceNotFound }
        do {
            return try BudgetWorkspace(snapshot: decoder.decode(BudgetWorkspaceSnapshot.self, from: payload))
        } catch {
            throw LedgerPersistenceError.invalidSnapshot
        }
    }

    /// Loads cache rows only for the authoritative workspace revision. A
    /// malformed derived cache is ignored; the workspace remains loadable and
    /// the next successful save replaces stale rows.
    public func loadProjectionCaches(
        budgetID: BudgetID,
        revision: Int64
    ) throws -> [ProjectionCacheEntry] {
        try pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT revision, horizon, payload FROM projection_caches WHERE budget_id = ? AND revision = ? ORDER BY horizon",
                arguments: [budgetID.description, revision]
            )
            return rows.compactMap { row -> ProjectionCacheEntry? in
                guard let storedRevision: Int64 = row["revision"],
                      let horizonKey: String = row["horizon"],
                      let payload: Data = row["payload"],
                      let result = try? decoder.decode(ProjectionResult.self, from: payload) else {
                    return nil
                }
                let horizon: BudgetMonth?
                if horizonKey.isEmpty {
                    horizon = nil
                } else {
                    guard let parsed = BudgetMonth(string: horizonKey) else { return nil }
                    horizon = parsed
                }
                return ProjectionCacheEntry(
                    revision: storedRevision,
                    horizon: horizon,
                    result: result
                )
            }
        }
    }

    /// How a workspace save treats the SimpleFIN connection-state blob:
    /// `.keep` leaves the stored row untouched; `.set` writes (or deletes, for
    /// `nil`) it inside the same transaction as the workspace, which is how a
    /// per-account sync commits imports and cursor atomically (§4.3/§6.4).
    public enum SimpleFINStateWrite: Sendable {
        case keep
        case set(SimpleFINConnectionState?)
    }

    public func save(
        _ workspace: BudgetWorkspace,
        expectedRevision: Int64? = nil,
        simpleFINState: SimpleFINStateWrite = .keep,
        expectedSimpleFINState: SimpleFINStateExpectation = .unchecked,
        projectionCaches: ProjectionCacheWrite = .keep,
        nowEpoch: Int64 = 0
    ) throws {
        let snapshot = workspace.snapshot()
        let payload: Data
        let statePayload: Data?
        do {
            payload = try encoder.encode(snapshot)
            _ = try BudgetWorkspace(snapshot: snapshot)
            if case .set(let state) = simpleFINState {
                statePayload = try state.map { try encoder.encode($0) }
            } else {
                statePayload = nil
            }
        } catch {
            throw LedgerPersistenceError.invalidSnapshot
        }

        try pool.write { db in
            if let expectedRevision {
                let actualRevision = try Int64.fetchOne(
                    db,
                    sql: "SELECT revision FROM workspace_states WHERE budget_id = ?",
                    arguments: [snapshot.budget.id.description]
                )
                guard actualRevision == expectedRevision else {
                    throw LedgerPersistenceError.concurrentModification(
                        expectedRevision: expectedRevision,
                        actualRevision: actualRevision
                    )
                }
            }
            if case .unchanged(let expectedState) = expectedSimpleFINState {
                let persistedState = try loadSimpleFINState(
                    db: db,
                    budgetID: snapshot.budget.id.description
                )
                guard persistedState == expectedState else {
                    throw LedgerPersistenceError.concurrentSimpleFINStateModification
                }
            }
            try upsertBudget(snapshot.budget, db: db)
            let stateForMirrors: SimpleFINConnectionState?
            switch simpleFINState {
            case .keep:
                stateForMirrors = try loadSimpleFINState(
                    db: db,
                    budgetID: snapshot.budget.id.description
                )
            case .set(let state):
                stateForMirrors = state
            }
            try replaceNormalizedRows(
                snapshot,
                payload: payload,
                simpleFINState: stateForMirrors,
                nowEpoch: nowEpoch,
                db: db
            )
            if case .set = simpleFINState {
                try writeSimpleFINState(
                    payload: statePayload,
                    budgetID: snapshot.budget.id.description,
                    nowEpoch: nowEpoch,
                    db: db
                )
            }
            if case .replace(let entries) = projectionCaches {
                try replaceProjectionCaches(
                    entries,
                    budgetID: snapshot.budget.id.description,
                    revision: snapshot.budget.revision,
                    nowEpoch: nowEpoch,
                    db: db
                )
            }
        }
    }

    /// GRDB `ValueObservation` over the committed workspace revision, exposed
    /// as an async stream so view models can bridge it into `@Observable`
    /// state without importing GRDB (§6.1). The first element fires with the
    /// current value; later elements fire after each committed write.
    public func observeRevisions() -> AsyncThrowingStream<Int64, Error> {
        let observation = ValueObservation.tracking { db in
            try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(revision), 0) FROM workspace_states") ?? 0
        }
        let values = observation.values(in: pool)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await revision in values {
                        continuation.yield(revision)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - SimpleFIN connection state

    public func loadSimpleFINState(budgetID: BudgetID) throws -> SimpleFINConnectionState? {
        let payload: Data? = try pool.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT payload FROM simplefin_state WHERE budget_id = ?",
                arguments: [budgetID.description]
            )?["payload"]
        }
        guard let payload else { return nil }
        return try decodeSimpleFINState(payload)
    }

    /// Passing `nil` deletes the stored connection state.
    public func saveSimpleFINState(
        _ state: SimpleFINConnectionState?,
        budgetID: BudgetID,
        nowEpoch: Int64
    ) throws {
        let payload = try state.map { try encoder.encode($0) }
        try pool.write { db in
            try writeSimpleFINState(payload: payload, budgetID: budgetID.description, nowEpoch: nowEpoch, db: db)
            try replaceSimpleFINMirrors(state, budgetID: budgetID.description, db: db)
        }
    }

    /// Performs a state-level compare-and-swap inside the same SQLite write
    /// transaction. This protects connection metadata without advancing the
    /// accounting workspace revision.
    public func saveSimpleFINStateIfUnchanged(
        _ state: SimpleFINConnectionState?,
        expectedState: SimpleFINConnectionState?,
        budgetID: BudgetID,
        nowEpoch: Int64
    ) throws {
        let payload = try state.map { try encoder.encode($0) }
        try pool.write { db in
            let persistedState = try loadSimpleFINState(db: db, budgetID: budgetID.description)
            guard persistedState == expectedState else {
                throw LedgerPersistenceError.concurrentSimpleFINStateModification
            }
            try writeSimpleFINState(payload: payload, budgetID: budgetID.description, nowEpoch: nowEpoch, db: db)
            try replaceSimpleFINMirrors(state, budgetID: budgetID.description, db: db)
        }
    }

    public func saveProjectionCaches(
        _ entries: [ProjectionCacheEntry],
        budgetID: BudgetID,
        nowEpoch: Int64 = 0
    ) throws {
        try pool.write { db in
            try replaceProjectionCaches(
                entries,
                budgetID: budgetID.description,
                revision: entries.map(\.revision).max() ?? 0,
                nowEpoch: nowEpoch,
                db: db
            )
        }
    }

    // MARK: - Sync request log (§2.1)

    public func insertSyncRequestLog(_ log: SyncRequestLog) throws {
        try pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO sync_request_log
                  (id, budget_id, connection_id, account_id, requested_start_epoch,
                   requested_end_epoch, started_at_epoch, completed_at_epoch, status,
                   http_status, retry_after_seconds)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    log.id.description,
                    log.budgetID.description,
                    log.connectionID,
                    log.accountID?.description,
                    log.requestedStartEpoch,
                    log.requestedEndEpoch,
                    log.startedAtEpoch,
                    log.completedAtEpoch,
                    log.status.rawValue,
                    log.httpStatus,
                    log.retryAfterSeconds
                ]
            )
        }
    }

    public func finishSyncRequestLog(
        id: SyncRequestLogID,
        status: SyncRequestLog.Status,
        completedAtEpoch: Int64,
        httpStatus: Int? = nil,
        retryAfterSeconds: Int64? = nil
    ) throws {
        try pool.write { db in
            try db.execute(
                sql: "UPDATE sync_request_log SET completed_at_epoch = ?, status = ?, http_status = ?, retry_after_seconds = ? WHERE id = ?",
                arguments: [completedAtEpoch, status.rawValue, httpStatus, retryAfterSeconds, id.description]
            )
            guard db.changesCount == 1 else { throw LedgerPersistenceError.invalidSnapshot }
        }
    }

    public func latestSyncRequestStartedAtEpoch(budgetID: BudgetID) throws -> Int64? {
        try pool.read { db in
            try Int64.fetchOne(
                db,
                sql: "SELECT started_at_epoch FROM sync_request_log WHERE budget_id = ? ORDER BY started_at_epoch DESC, rowid DESC LIMIT 1",
                arguments: [budgetID.description]
            )
        }
    }

    public func syncRequestLogs(budgetID: BudgetID, limit: Int = 100) throws -> [SyncRequestLog] {
        let boundedLimit = max(1, min(limit, 1_000))
        return try pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT id, budget_id, connection_id, account_id, requested_start_epoch, requested_end_epoch, started_at_epoch, completed_at_epoch, status, http_status, retry_after_seconds FROM sync_request_log WHERE budget_id = ? ORDER BY started_at_epoch DESC, rowid DESC LIMIT ?",
                arguments: [budgetID.description, boundedLimit]
            )
            return try rows.map(Self.decodeSyncRequestLog)
        }
    }

    private static func decodeSyncRequestLog(_ row: Row) throws -> SyncRequestLog {
        guard let idString: String = row["id"],
              let budgetString: String = row["budget_id"],
              let idUUID = UUID(uuidString: idString),
              let budgetUUID = UUID(uuidString: budgetString),
              let statusRaw: String = row["status"],
              let status = SyncRequestLog.Status(rawValue: statusRaw) else {
            throw LedgerPersistenceError.invalidSnapshot
        }
        let accountID: AccountID?
        if let accountString: String = row["account_id"] {
            guard let accountUUID = UUID(uuidString: accountString) else {
                throw LedgerPersistenceError.invalidSnapshot
            }
            accountID = AccountID(accountUUID)
        } else {
            accountID = nil
        }
        return SyncRequestLog(
            id: SyncRequestLogID(idUUID),
            budgetID: BudgetID(budgetUUID),
            connectionID: row["connection_id"],
            accountID: accountID,
            requestedStartEpoch: row["requested_start_epoch"],
            requestedEndEpoch: row["requested_end_epoch"],
            startedAtEpoch: row["started_at_epoch"],
            completedAtEpoch: row["completed_at_epoch"],
            status: status,
            httpStatus: row["http_status"],
            retryAfterSeconds: row["retry_after_seconds"]
        )
    }

    /// Shared upsert/delete for the `simplefin_state` blob. Takes the open
    /// `db` handle so the combined sync save can run it inside the workspace
    /// write transaction rather than opening a nested `pool.write`.
    private func writeSimpleFINState(payload: Data?, budgetID: String, nowEpoch: Int64, db: Database) throws {
        if let payload {
            try db.execute(
                sql: "INSERT INTO simplefin_state(budget_id, payload, updated_at_epoch) VALUES (?, ?, ?) ON CONFLICT(budget_id) DO UPDATE SET payload = excluded.payload, updated_at_epoch = excluded.updated_at_epoch",
                arguments: [budgetID, payload, nowEpoch]
            )
        } else {
            try db.execute(
                sql: "DELETE FROM simplefin_state WHERE budget_id = ?",
                arguments: [budgetID]
            )
        }
    }

    private func decodeSimpleFINState(_ payload: Data) throws -> SimpleFINConnectionState {
        do {
            return try decoder.decode(SimpleFINConnectionState.self, from: payload)
        } catch {
            throw LedgerPersistenceError.invalidSnapshot
        }
    }

    private func loadSimpleFINState(db: Database, budgetID: String) throws -> SimpleFINConnectionState? {
        let payload: Data? = try Row.fetchOne(
            db,
            sql: "SELECT payload FROM simplefin_state WHERE budget_id = ?",
            arguments: [budgetID]
        )?["payload"]
        guard let payload else { return nil }
        return try decodeSimpleFINState(payload)
    }

    /// Produces a consistent verified SQLite backup. The temporary sibling is
    /// integrity-checked before it is moved into place, replacing an existing
    /// destination atomically rather than deleting it first.
    public func backup(to destination: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".ledgerbar-backup-\(UUID().uuidString).sqlite")
        defer { try? fileManager.removeItem(at: temporary) }

        let destinationQueue = try DatabaseQueue(path: temporary.path)
        try pool.backup(to: destinationQueue)
        let integrity: String = try destinationQueue.read { db in
            try String.fetchOne(db, sql: "PRAGMA integrity_check") ?? ""
        }
        guard integrity.lowercased() == "ok" else {
            throw LedgerPersistenceError.backupIntegrityCheckFailed
        }
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(
                destination,
                withItemAt: temporary,
                backupItemName: nil,
                options: .usingNewMetadataOnly
            )
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
    }

    private func upsertBudget(_ budget: BudgetRow, db: Database) throws {
        try db.execute(
            sql: """
            INSERT INTO budgets
              (id, name, currency, timezone_identifier, first_month,
               last_observed_month, next_local_source_sequence, created_at_epoch, revision,
               archived, sort_order)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              name = excluded.name,
              currency = excluded.currency,
              timezone_identifier = excluded.timezone_identifier,
              first_month = excluded.first_month,
              last_observed_month = excluded.last_observed_month,
              next_local_source_sequence = excluded.next_local_source_sequence,
              created_at_epoch = excluded.created_at_epoch,
              revision = excluded.revision,
              archived = excluded.archived,
              sort_order = excluded.sort_order
            """,
            arguments: [
                budget.id.description, budget.name, budget.currency,
                budget.timeZoneIdentifier, budget.firstMonth.description,
                budget.lastObservedBudgetMonth.description,
                budget.nextLocalSourceSequence, budget.createdAtEpoch, budget.revision,
                budget.archived ? 1 : 0, budget.sortOrder
            ]
        )
    }

    private func replaceNormalizedRows(
        _ snapshot: BudgetWorkspaceSnapshot,
        payload: Data,
        simpleFINState: SimpleFINConnectionState?,
        nowEpoch: Int64,
        db: Database
    ) throws {
        let budgetID = snapshot.budget.id.description
        try db.execute(
            sql: "INSERT INTO workspace_states(budget_id, payload, revision, updated_at_epoch) VALUES (?, ?, ?, ?) ON CONFLICT(budget_id) DO UPDATE SET payload = excluded.payload, revision = excluded.revision, updated_at_epoch = excluded.updated_at_epoch",
            arguments: [budgetID, payload, snapshot.budget.revision, nowEpoch]
        )

        // Delete in child-to-parent order so foreign-key enforcement remains
        // on. The SimpleFIN mirrors must go first: `sync_conflicts` references
        // `simplefin_imports`, and `simplefin_imports`/`snapshot_discrepancies`
        // hold ON DELETE RESTRICT edges into `transactions`/`accounts`, which
        // are truncated below.
        try db.execute(
            sql: "DELETE FROM transfer_leg_snapshots WHERE transfer_pair_id IN (SELECT id FROM transfer_pairs WHERE budget_id = ?)",
            arguments: [budgetID]
        )
        for table in [
            "schedule_reviews", "schedule_occurrences", "schedules",
            "reports", "file_imports", "import_batches", "import_mappings",
            "sync_conflicts", "simplefin_imports", "snapshot_discrepancies",
            "trusted_hosts", "simplefin_links", "simplefin_connections",
            "reconciliation_transactions", "reconciliations",
            "reconciliation_membership", "transaction_splits", "transactions", "allocations",
            "closed_months", "audit_events", "automation_rules", "payees", "categories",
            "category_groups", "accounts", "transfer_pairs"
        ] {
            try db.execute(sql: "DELETE FROM \(table) WHERE budget_id = ?", arguments: [budgetID])
        }

        for account in snapshot.accounts {
            try db.execute(sql: "INSERT INTO accounts(id, budget_id, name, type, on_budget, closed, currency, history_incomplete, created_at_epoch) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)", arguments: [
                account.id.description, budgetID, account.name, account.type.rawValue,
                account.onBudget ? 1 : 0, account.closed ? 1 : 0, account.currency,
                account.historyIncomplete ? 1 : 0, account.createdAtEpoch
            ])
        }
        for group in snapshot.categoryGroups {
            try db.execute(sql: "INSERT INTO category_groups(id, budget_id, name, sort_order, hidden) VALUES (?, ?, ?, ?, ?)", arguments: [
                group.id.description, budgetID, group.name, group.sortOrder, group.hidden ? 1 : 0
            ])
        }
        for category in snapshot.categories {
            try db.execute(sql: "INSERT INTO categories(id, budget_id, group_id, name, sort_order, hidden, kind, linked_account_id, system_kind, note) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", arguments: [
                category.id.description, budgetID, category.groupID.description, category.name,
                category.sortOrder, category.hidden ? 1 : 0, category.kind.rawValue,
                category.linkedAccountID?.description, category.systemKind?.rawValue, category.note
            ])
        }
        for payee in snapshot.payees {
            try db.execute(sql: "INSERT INTO payees(id, budget_id, system_kind, namespace, normalized_name, display_name, last_used_category_id, hidden) VALUES (?, ?, ?, ?, ?, ?, ?, ?)", arguments: [
                payee.id.description, budgetID, payee.systemKind?.rawValue, payee.namespace.rawValue,
                payee.name, payee.displayName, payee.lastUsedCategoryID?.description, payee.hidden ? 1 : 0
            ])
        }
        for pair in snapshot.transferPairs {
            try db.execute(sql: "INSERT INTO transfer_pairs(id, budget_id, status, created_at_epoch) VALUES (?, ?, ?, ?)", arguments: [
                pair.id.description, budgetID, pair.status.rawValue, pair.createdAtEpoch
            ])
        }
        for allocation in snapshot.allocations {
            try db.execute(sql: "INSERT INTO allocations(budget_id, category_id, month, budgeted_milliunits) VALUES (?, ?, ?, ?)", arguments: [
                budgetID, allocation.categoryID.description, allocation.month.description, allocation.budgetedMilliunits
            ])
        }
        // `refund_of_transaction_id` is an immediate self-referential foreign
        // key. Snapshot arrays are UUID-sorted, so a dependent can otherwise
        // be encountered before its origin and make a valid workspace fail to
        // mirror nondeterministically. Insert every reachable origin first;
        // malformed cycles/missing origins retain deterministic order and are
        // still rejected by SQLite.
        for transaction in refundDependencyOrder(snapshot.transactions) {
            let stageMetadata = try transaction.stageMetadata.map { try encoder.encode($0) }
            let splitsPayload = try transaction.splits.map { try encoder.encode($0) }
            try db.execute(sql: "INSERT INTO transactions(id, budget_id, account_id, payee_id, source_kind, date, effective_at_epoch, source_order_key, memo, amount_milliunits, cleared, approved, flag_color, posting_state, stage_reason, stage_metadata, user_edited_at_epoch, category_id, transfer_pair_id, refund_of_transaction_id, kind, splits, imported_description, refund_of_component_index) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", arguments: [
                transaction.id.description, budgetID, transaction.accountID.description,
                transaction.payeeID?.description, transaction.sourceKind.rawValue,
                transaction.date.description, transaction.effectiveAtEpoch,
                transaction.sourceOrderKey.rawValue, transaction.memo, transaction.amountMilliunits,
                transaction.cleared.rawValue, transaction.approved ? 1 : 0,
                transaction.flagColor?.rawValue, transaction.postingState.rawValue,
                transaction.stageReason?.rawValue, stageMetadata, transaction.userEditedAtEpoch,
                transaction.categoryID?.description, transaction.transferPairID?.description,
                transaction.refundOfTransactionID?.description, transaction.kind.rawValue,
                splitsPayload, transaction.importedDescription, transaction.refundOfComponentIndex
            ])
            if let splits = transaction.splits {
                for (index, component) in splits.enumerated() {
                    try db.execute(sql: "INSERT INTO transaction_splits(transaction_id, component_index, budget_id, category_id, amount_milliunits, memo) VALUES (?, ?, ?, ?, ?, ?)", arguments: [
                        transaction.id.description, index, budgetID,
                        component.categoryID.description, component.amountMilliunits, component.memo
                    ])
                }
            }
        }
        for group in snapshot.legSnapshots {
            let data = try encoder.encode(group.rows)
            for row in group.rows {
                try db.execute(sql: "INSERT INTO transfer_leg_snapshots(transfer_pair_id, transaction_id, payload) VALUES (?, ?, ?)", arguments: [
                    group.pairID.description, row.transactionID.description, data
                ])
            }
        }
        for month in snapshot.closedMonths {
            try db.execute(sql: "INSERT INTO closed_months(budget_id, month, status, closed_at_epoch, reopened_at_epoch) VALUES (?, ?, ?, ?, ?)", arguments: [
                budgetID, month.month.description, month.status.rawValue, month.closedAtEpoch, month.reopenedAtEpoch
            ])
        }
        for event in snapshot.auditEvents {
            let metadata = try encoder.encode(event.metadata)
            try db.execute(sql: "INSERT INTO audit_events(id, budget_id, entity_type, entity_id, event_kind, metadata, created_at_epoch) VALUES (?, ?, ?, ?, ?, ?, ?)", arguments: [
                event.id.description, budgetID, event.entityType, event.entityID, event.eventKind, metadata, event.createdAtEpoch
            ])
        }
        for transactionID in snapshot.reconciliationMembership {
            try db.execute(sql: "INSERT INTO reconciliation_membership(budget_id, transaction_id, reconciliation_id) VALUES (?, ?, ?)", arguments: [
                budgetID, transactionID.description, "workspace-reconciliation"
            ])
        }
        for group in snapshot.reconciliations {
            let row = group.reconciliation
            try db.execute(sql: "INSERT INTO reconciliations(id, budget_id, account_id, statement_date, statement_balance_milliunits, cleared_balance_milliunits, adjustment_transaction_id, adjustment_fingerprint, status, created_at_epoch, completed_at_epoch) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", arguments: [
                row.id.description, budgetID, row.accountID.description,
                row.statementDate.description, row.statementBalanceMilliunits,
                row.clearedBalanceMilliunits, row.adjustmentTransactionID?.description,
                row.adjustmentFingerprintAtCreation, row.status.rawValue,
                row.createdAtEpoch, row.completedAtEpoch
            ])
            for member in group.members {
                try db.execute(sql: "INSERT INTO reconciliation_transactions(reconciliation_id, budget_id, transaction_id, fingerprint, was_newly_marked) VALUES (?, ?, ?, ?, ?)", arguments: [
                    row.id.description, budgetID, member.transactionID.description,
                    member.fingerprintAtReconciliation, member.wasNewlyMarkedReconciled ? 1 : 0
                ])
            }
        }
        for rule in snapshot.automationRules {
            let payload = try encoder.encode(rule)
            try db.execute(sql: "INSERT INTO automation_rules(id, budget_id, name, enabled, sort_order, match_mode, stop_after_match, payload, created_at_epoch, updated_at_epoch) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", arguments: [
                rule.id.description, budgetID, rule.name, rule.enabled ? 1 : 0, rule.sortOrder,
                rule.matchMode.rawValue, rule.stopAfterMatch ? 1 : 0, payload,
                rule.createdAtEpoch, rule.updatedAtEpoch
            ])
        }
        for batch in snapshot.importBatches {
            try db.execute(sql: "INSERT INTO import_batches(id, budget_id, account_id, format, file_name, imported_at_epoch, imported_count, skipped_count) VALUES (?, ?, ?, ?, ?, ?, ?, ?)", arguments: [
                batch.id.description, budgetID, batch.accountID.description, batch.format.rawValue,
                batch.fileName, batch.importedAtEpoch, batch.importedCount, batch.skippedCount
            ])
        }
        for record in snapshot.fileImports {
            let raw = try encoder.encode(record.rawFields)
            try db.execute(sql: "INSERT INTO file_imports(transaction_id, budget_id, batch_id, external_id, fingerprint, raw_fields) VALUES (?, ?, ?, ?, ?, ?)", arguments: [
                record.transactionID.description, budgetID, record.batchID.description,
                record.externalID, record.fingerprint, raw
            ])
        }
        for mapping in snapshot.importMappings {
            let payload = try encoder.encode(mapping.mapping)
            try db.execute(sql: "INSERT INTO import_mappings(id, budget_id, name, format, header_fingerprint, payload, created_at_epoch, last_used_at_epoch) VALUES (?, ?, ?, ?, ?, ?, ?, ?)", arguments: [
                mapping.id.description, budgetID, mapping.name, mapping.format.rawValue,
                mapping.headerFingerprint, payload, mapping.createdAtEpoch, mapping.lastUsedAtEpoch
            ])
        }
        for report in snapshot.reports {
            let payload = try encoder.encode(report.definition)
            try db.execute(sql: "INSERT INTO reports(id, budget_id, name, kind, sort_order, payload, created_at_epoch, updated_at_epoch) VALUES (?, ?, ?, ?, ?, ?, ?, ?)", arguments: [
                report.id.description, budgetID, report.name, report.definition.kind.rawValue,
                report.sortOrder, payload, report.createdAtEpoch, report.updatedAtEpoch
            ])
        }
        for schedule in snapshot.schedules {
            let payload = try encoder.encode(schedule)
            try db.execute(sql: "INSERT INTO schedules(id, budget_id, account_id, name, status, amount_milliunits, start_date, end_date, payload, created_at_epoch, updated_at_epoch) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", arguments: [
                schedule.id.description, budgetID, schedule.accountID.description, schedule.name, schedule.status.rawValue,
                schedule.amountMilliunits, schedule.startDate.description, schedule.endDate?.description, payload,
                schedule.createdAtEpoch, schedule.updatedAtEpoch
            ])
        }
        for occurrence in snapshot.scheduleOccurrences {
            try db.execute(sql: "INSERT INTO schedule_occurrences(schedule_id, due_date, budget_id, status, transaction_id, resolved_at_epoch, match_score) VALUES (?, ?, ?, ?, ?, ?, ?)", arguments: [
                occurrence.scheduleID.description, occurrence.dueDate.description, budgetID, occurrence.status.rawValue,
                occurrence.transactionID?.description, occurrence.resolvedAtEpoch, occurrence.matchScore
            ])
        }
        for review in snapshot.scheduleReviews {
            let candidates = try encoder.encode(review.candidateTransactionIDs)
            try db.execute(sql: "INSERT INTO schedule_reviews(id, budget_id, schedule_id, due_date, status, candidates, created_at_epoch, resolved_at_epoch) VALUES (?, ?, ?, ?, ?, ?, ?, ?)", arguments: [
                review.id.description, budgetID, review.scheduleID.description, review.dueDate.description,
                review.status.rawValue, candidates, review.createdAtEpoch, review.resolvedAtEpoch
            ])
        }
        // SimpleFIN mirrors last: imports reference transactions, conflicts
        // reference imports, discrepancies reference accounts/transactions.
        for record in snapshot.simpleFINImports {
            // The mirror's composite identity is scoped by the per-budget
            // connection id (D8): two budgets may legitimately import the
            // same remote row.
            try db.execute(sql: "INSERT INTO simplefin_imports(id, budget_id, transaction_id, connection_id, remote_connection_key, remote_account_id, remote_transaction_id, remote_amount, remote_posted_epoch, remote_transacted_epoch, remote_payload_hash, protocol_version, last_seen_epoch, remote_disappearance_acknowledged) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", arguments: [
                record.id.description, budgetID, record.transactionID.description,
                "\(budgetID):primary", record.connectionKey, record.remoteAccountID,
                record.remoteTransactionID, record.remoteAmountDecimalString,
                record.remotePostedEpoch, record.remoteTransactedEpoch,
                record.remotePayloadHash, record.protocolVersion, record.lastSeenEpoch,
                record.remoteDisappearanceAcknowledged ? 1 : 0
            ])
        }
        for conflict in snapshot.syncConflicts {
            let oldMetadata = try encoder.encode(conflict.oldMetadata)
            let newMetadata = try encoder.encode(conflict.newMetadata)
            try db.execute(sql: "INSERT INTO sync_conflicts(id, budget_id, transaction_id, simplefin_import_id, event_kind, status, old_metadata, new_metadata, created_at_epoch, resolved_at_epoch) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", arguments: [
                conflict.id.description, budgetID, conflict.transactionID?.description,
                conflict.simpleFINImportID?.description, conflict.eventKind.rawValue,
                conflict.status.rawValue, oldMetadata, newMetadata,
                conflict.createdAtEpoch, conflict.resolvedAtEpoch
            ])
        }
        for discrepancy in snapshot.snapshotDiscrepancies {
            try db.execute(sql: "INSERT INTO snapshot_discrepancies(id, budget_id, account_id, simplefin_link_identity, snapshot_epoch, remote_balance_milliunits, local_register_milliunits, difference_milliunits, status, resolution_reason, adjustment_transaction_id, created_at_epoch, resolved_at_epoch) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", arguments: [
                discrepancy.id.description, budgetID, discrepancy.accountID.description,
                discrepancy.simpleFINLinkIdentity,
                discrepancy.observedEpoch, discrepancy.remoteBalanceMilliunits,
                discrepancy.localRegisterMilliunits, discrepancy.differenceMilliunits,
                discrepancy.status.rawValue, discrepancy.resolutionReason?.rawValue,
                discrepancy.adjustmentTransactionID?.description,
                discrepancy.createdAtEpoch, discrepancy.resolvedAtEpoch
            ])
        }
        try replaceSimpleFINMirrors(simpleFINState, budgetID: budgetID, db: db)
    }

    private func replaceSimpleFINMirrors(
        _ state: SimpleFINConnectionState?,
        budgetID: String,
        db: Database
    ) throws {
        try db.execute(sql: "DELETE FROM trusted_hosts WHERE budget_id = ?", arguments: [budgetID])
        try db.execute(sql: "DELETE FROM simplefin_links WHERE budget_id = ?", arguments: [budgetID])
        try db.execute(sql: "DELETE FROM simplefin_connections WHERE budget_id = ?", arguments: [budgetID])
        guard let state else { return }

        let knownAccountIDs = Set(try String.fetchAll(
            db,
            sql: "SELECT id FROM accounts WHERE budget_id = ?",
            arguments: [budgetID]
        ))
        let connectionID = "\(budgetID):primary"
        try db.execute(
            sql: "INSERT INTO simplefin_connections(id, budget_id, status, keychain_item_ref, credential_generation, created_at_epoch) VALUES (?, ?, ?, ?, ?, ?)",
            arguments: [
                connectionID, budgetID, state.status.rawValue, state.keychainItemID,
                state.credentialGeneration, state.createdAtEpoch
            ]
        )
        for link in state.links {
            try db.execute(
                sql: "INSERT INTO simplefin_links(id, budget_id, connection_id, local_account_id, remote_connection_key, remote_account_id, sign_normalization, cursor_posted_epoch, last_successful_sync_epoch, last_error_redacted, pause_reason, status) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                arguments: [
                    "\(budgetID):\(link.identity)", budgetID, connectionID,
                    link.localAccountID.flatMap { knownAccountIDs.contains($0.description) ? $0.description : nil },
                    link.connectionKey, link.remoteAccountID, link.signNormalization.rawValue,
                    link.lastSuccessfulPostedEpoch, link.lastSuccessfulPostedEpoch,
                    link.lastErrorRedacted, link.pauseReason?.rawValue, link.status.rawValue
                ]
            )
        }
        for host in state.extraTrustedHosts {
            try db.execute(
                sql: "INSERT INTO trusted_hosts(budget_id, host, port, added_at_epoch) VALUES (?, ?, ?, ?)",
                arguments: [budgetID, host.host, host.port, state.createdAtEpoch]
            )
        }
    }

    private func replaceProjectionCaches(
        _ entries: [ProjectionCacheEntry],
        budgetID: String,
        revision: Int64,
        nowEpoch: Int64,
        db: Database
    ) throws {
        try db.execute(sql: "DELETE FROM projection_caches WHERE budget_id = ?", arguments: [budgetID])
        for entry in entries where entry.revision == revision {
            let payload = try encoder.encode(entry.result)
            try db.execute(
                sql: "INSERT INTO projection_caches(budget_id, revision, horizon, payload, updated_at_epoch) VALUES (?, ?, ?, ?, ?)",
                arguments: [budgetID, entry.revision, entry.horizon?.description ?? "", payload, nowEpoch]
            )
        }
    }

    private func refundDependencyOrder(_ transactions: [TransactionRow]) -> [TransactionRow] {
        var remaining = Dictionary(uniqueKeysWithValues: transactions.map { ($0.id, $0) })
        var inserted: Set<TransactionID> = []
        var ordered: [TransactionRow] = []
        ordered.reserveCapacity(transactions.count)

        while !remaining.isEmpty {
            let ready = remaining.values
                .filter { row in
                    guard let originID = row.refundOfTransactionID else { return true }
                    return inserted.contains(originID)
                }
                .sorted { $0.id < $1.id }
            guard !ready.isEmpty else {
                ordered.append(contentsOf: remaining.values.sorted { $0.id < $1.id })
                break
            }
            for row in ready {
                ordered.append(row)
                inserted.insert(row.id)
                remaining.removeValue(forKey: row.id)
            }
        }
        return ordered
    }
}

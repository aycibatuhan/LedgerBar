import Foundation

public enum BudgetMutationServiceError: Error, Equatable, Sendable {
    case noLoadedBudget
    case budgetIsActive
    case budgetHasCredential
}

private struct SimpleFINSignViolation: Hashable {
    var linkIdentity: String
    var localAccountID: AccountID
}

private struct ProjectionCacheKey: Hashable {
    var revision: Int64
    var horizon: BudgetMonth?
}

/// Sole coordinator for durable budget writes. Callers submit Sendable
/// mutations; the service applies them to a candidate value, persists the
/// complete state in one DatabasePool.write transaction, and publishes only
/// after the write succeeds.
public actor BudgetMutationService {
    static let maxProjectionCacheEntries = 16

    private let store: LedgerWorkspaceStore
    private var workspace: BudgetWorkspace?
    private var loadedSimpleFINState: SimpleFINConnectionState?
    private var projectionCache: [ProjectionCacheKey: ProjectionResult] = [:]

    public init(store: LedgerWorkspaceStore) {
        self.store = store
    }

    @discardableResult
    public func createBudget(
        name: String,
        currency: String,
        timeZoneIdentifier: String,
        firstMonth: BudgetMonth,
        currentMonth: BudgetMonth,
        nowEpoch: Int64
    ) throws -> BudgetWorkspaceSnapshot {
        let created = try BudgetWorkspace.create(
            name: name,
            currency: currency,
            timeZoneIdentifier: timeZoneIdentifier,
            firstMonth: firstMonth,
            currentMonth: currentMonth,
            nowEpoch: nowEpoch,
            sortOrder: ((try? store.listBudgets().map(\.sortOrder).max()) ?? nil).map { $0 + 1 } ?? 0
        )
        try store.create(created, nowEpoch: nowEpoch)
        workspace = created
        loadedSimpleFINState = nil
        projectionCache.removeAll()
        try setActiveBudgetID(created.budget.id, nowEpoch: nowEpoch)
        return created.snapshot()
    }

    @discardableResult
    public func load(budgetID: BudgetID) throws -> BudgetWorkspaceSnapshot {
        let loaded = try store.load(budgetID: budgetID)
        workspace = loaded
        loadedSimpleFINState = try store.loadSimpleFINState(budgetID: budgetID)
        projectionCache = Self.cacheDictionary(
            try store.loadProjectionCaches(
                budgetID: loaded.budget.id,
                revision: loaded.budget.revision
            )
        )
        return loaded.snapshot()
    }

    @discardableResult
    public func loadFirst() throws -> BudgetWorkspaceSnapshot {
        let loaded = try store.loadFirstWorkspace()
        workspace = loaded
        loadedSimpleFINState = try store.loadSimpleFINState(budgetID: loaded.budget.id)
        projectionCache = Self.cacheDictionary(
            try store.loadProjectionCaches(
                budgetID: loaded.budget.id,
                revision: loaded.budget.revision
            )
        )
        return loaded.snapshot()
    }

    @discardableResult
    public func reload() throws -> BudgetWorkspaceSnapshot {
        guard let budgetID = workspace?.budget.id else {
            throw BudgetMutationServiceError.noLoadedBudget
        }
        return try load(budgetID: budgetID)
    }

    public func currentSnapshot() -> BudgetWorkspaceSnapshot? {
        workspace?.snapshot()
    }

    // MARK: - Budget registry (D8)

    public var loadedBudgetID: BudgetID? { workspace?.budget.id }

    public func listBudgets() throws -> [BudgetSummary] {
        try store.listBudgets()
    }

    public func activeBudgetID() throws -> BudgetID? {
        guard let value = try store.setting(LedgerWorkspaceStore.activeBudgetSettingKey), let uuid = UUID(uuidString: value) else { return nil }
        return BudgetID(uuid)
    }

    public func appSetting(_ key: String) throws -> String? {
        try store.setting(key)
    }

    public func setAppSetting(_ key: String, value: String?, nowEpoch: Int64) throws {
        try store.setSetting(key, value: value, nowEpoch: nowEpoch)
    }

    public func loadAssistantTranscript(budgetID: BudgetID) throws -> AssistantTranscript? {
        try store.loadAssistantTranscript(budgetID: budgetID)
    }

    public func saveAssistantTranscript(_ transcript: AssistantTranscript?, budgetID: BudgetID, nowEpoch: Int64) throws {
        try store.saveAssistantTranscript(transcript, budgetID: budgetID, nowEpoch: nowEpoch)
    }

    public func setActiveBudgetID(_ id: BudgetID?, nowEpoch: Int64) throws {
        try store.setSetting(LedgerWorkspaceStore.activeBudgetSettingKey, value: id?.description, nowEpoch: nowEpoch)
    }

    /// Loads the active budget: the persisted choice, else the first
    /// non-archived budget, else the first budget.
    @discardableResult
    public func loadActive() throws -> BudgetWorkspaceSnapshot {
        let budgets = try store.listBudgets()
        guard !budgets.isEmpty else { throw LedgerPersistenceError.workspaceNotFound }
        if let active = try activeBudgetID(), budgets.contains(where: { $0.id == active }) {
            return try load(budgetID: active)
        }
        let target = budgets.first { !$0.archived } ?? budgets[0]
        return try load(budgetID: target.id)
    }

    /// Switches the loaded workspace. The projection cache and SimpleFIN
    /// state are replaced wholesale; nothing from the previous budget
    /// survives in memory.
    @discardableResult
    public func switchBudget(to id: BudgetID, nowEpoch: Int64) throws -> BudgetWorkspaceSnapshot {
        let snapshot = try load(budgetID: id)
        try setActiveBudgetID(id, nowEpoch: nowEpoch)
        return snapshot
    }

    /// Physically deletes a budget that is not currently loaded. Callers
    /// must have removed its SimpleFIN credential first (the connection
    /// state must be absent or disconnected) so no Keychain item is orphaned.
    public func deleteBudget(_ id: BudgetID) throws {
        guard workspace?.budget.id != id else { throw BudgetMutationServiceError.budgetIsActive }
        if let state = try store.loadSimpleFINState(budgetID: id), state.keychainItemID != nil || state.status == .active {
            throw BudgetMutationServiceError.budgetHasCredential
        }
        try store.deleteBudget(id)
    }

    /// Creates a budget from an exported snapshot with fresh identities.
    @discardableResult
    public func importBudget(_ export: BudgetExport, name: String?, nowEpoch: Int64) throws -> BudgetWorkspaceSnapshot {
        let remapped = try BudgetTransfer.remapIdentities(export.snapshot)
        var workspace = try BudgetWorkspace(snapshot: remapped)
        if let name { try workspace.renameBudget(to: name) }
        workspace.setBudgetSortOrder(((try? store.listBudgets().map(\.sortOrder).max()) ?? nil).map { $0 + 1 } ?? 0)
        workspace.setBudgetArchivedFlag(false)
        try store.create(workspace, nowEpoch: nowEpoch)
        self.workspace = workspace
        loadedSimpleFINState = nil
        projectionCache.removeAll()
        try setActiveBudgetID(workspace.budget.id, nowEpoch: nowEpoch)
        return workspace.snapshot()
    }

    /// Returns a projection from the actor-owned revision/horizon cache. The
    /// cache is derived state only; durable snapshots never contain it.
    public func cachedProjectionResult(through horizon: BudgetMonth? = nil) throws -> ProjectionResult? {
        guard let workspace else { return nil }
        let key = ProjectionCacheKey(revision: workspace.budget.revision, horizon: horizon)
        if let cached = projectionCache[key] {
            return cached
        }
        let result = try workspace.projection(through: horizon)
        var nextCache = projectionCache
        nextCache[key] = result
        while nextCache.count > Self.maxProjectionCacheEntries {
            guard let evictedKey = nextCache.keys
                .filter({ $0 != key })
                .sorted(by: Self.projectionCacheKeyComesFirst)
                .first else {
                break
            }
            nextCache.removeValue(forKey: evictedKey)
        }
        try store.saveProjectionCaches(
            Self.cacheEntries(nextCache),
            budgetID: workspace.budget.id
        )
        projectionCache = nextCache
        return result
    }

    private static func projectionCacheKeyComesFirst(
        _ lhs: ProjectionCacheKey,
        _ rhs: ProjectionCacheKey
    ) -> Bool {
        let leftHorizon = lhs.horizon?.description ?? "~"
        let rightHorizon = rhs.horizon?.description ?? "~"
        if leftHorizon != rightHorizon { return leftHorizon < rightHorizon }
        return lhs.revision < rhs.revision
    }

    @discardableResult
    public func transact<T: Sendable>(
        nowEpoch: Int64,
        _ body: @Sendable (inout BudgetWorkspace) throws -> T
    ) throws -> T {
        guard let workspace else { throw BudgetMutationServiceError.noLoadedBudget }
        var candidate = workspace
        let result = try body(&candidate)
        let nextCache = reseededProjectionCache(previous: workspace, current: candidate)
        do {
            try store.save(
                candidate,
                expectedRevision: workspace.budget.revision,
                projectionCaches: .replace(Self.cacheEntries(nextCache)),
                nowEpoch: nowEpoch
            )
        } catch let error as LedgerPersistenceError {
            if Self.isConcurrencyConflict(error) {
                _ = try? reload()
            }
            throw error
        }
        projectionCache = nextCache
        self.workspace = candidate
        return result
    }

    /// Per-account sync commit (§4.3/§6.4): the body mutates the workspace
    /// (imported posted rows, staged rows, conflicts, discrepancies, import
    /// identities) and the SimpleFIN connection state (cursor, pause,
    /// last-seen metadata) together, and both blobs persist in ONE
    /// `DatabasePool.write` transaction. A thrown body leaves both untouched;
    /// the cursor can never outrun or lag its account's imports.
    @discardableResult
    public func syncTransact<T: Sendable>(
        nowEpoch: Int64,
        _ body: @Sendable (inout BudgetWorkspace, inout SimpleFINConnectionState?) throws -> T
    ) throws -> T {
        guard let workspace else { throw BudgetMutationServiceError.noLoadedBudget }
        var candidate = workspace
        var state = loadedSimpleFINState
        let expectedState = state
        let existingSignViolations = Self.simpleFINSignViolations(
            workspace: workspace,
            state: state
        )
        let result = try body(&candidate, &state)
        try Self.rejectNewSimpleFINSignViolations(
            existing: existingSignViolations,
            workspace: candidate,
            state: state
        )
        let nextCache = reseededProjectionCache(previous: workspace, current: candidate)
        do {
            try store.save(
                candidate,
                expectedRevision: workspace.budget.revision,
                simpleFINState: .set(state),
                expectedSimpleFINState: .unchanged(expectedState),
                projectionCaches: .replace(Self.cacheEntries(nextCache)),
                nowEpoch: nowEpoch
            )
        } catch let error as LedgerPersistenceError {
            if Self.isConcurrencyConflict(error) {
                _ = try? reload()
            }
            throw error
        }
        projectionCache = nextCache
        self.workspace = candidate
        loadedSimpleFINState = state
        return result
    }

    private func reseededProjectionCache(
        previous: BudgetWorkspace,
        current: BudgetWorkspace
    ) -> [ProjectionCacheKey: ProjectionResult] {
        let previousEntries = projectionCache.filter { $0.key.revision == previous.budget.revision }
        guard !previousEntries.isEmpty else { return [:] }
        var nextCache: [ProjectionCacheKey: ProjectionResult] = [:]

        let affectedMonth = current.earliestProjectionAffectedMonth(comparedTo: previous)
        for (oldKey, oldResult) in previousEntries {
            let coversRequestedHorizon: Bool
            if let requestedHorizon = oldKey.horizon {
                coversRequestedHorizon = requestedHorizon <= oldResult.horizon
            } else {
                coversRequestedHorizon = oldResult.horizon >= current.currentMonth
            }
            guard coversRequestedHorizon else { continue }

            let result: ProjectionResult?
            if let affectedMonth,
               let requestedHorizon = oldKey.horizon,
               requestedHorizon < affectedMonth
            {
                result = oldResult
            } else if let affectedMonth,
                      let checkpoint = oldResult.checkpoints[affectedMonth]
            {
                if let suffix = try? ReplayEngine.replay(
                    current.replayInput(),
                    through: oldKey.horizon,
                    startingAt: checkpoint
                ) {
                    result = Self.mergeProjectionPrefix(
                        oldResult,
                        suffix: suffix,
                        startingAt: affectedMonth
                    )
                } else {
                    result = nil
                }
            } else {
                result = oldResult
            }
            if let result {
                let newKey = ProjectionCacheKey(
                    revision: current.budget.revision,
                    horizon: oldKey.horizon
                )
                nextCache[newKey] = result
            }
        }
        return nextCache
    }

    private static func cacheDictionary(
        _ entries: [ProjectionCacheEntry]
    ) -> [ProjectionCacheKey: ProjectionResult] {
        entries.reduce(into: [:]) { result, entry in
            result[ProjectionCacheKey(revision: entry.revision, horizon: entry.horizon)] = entry.result
        }
    }

    private static func cacheEntries(
        _ cache: [ProjectionCacheKey: ProjectionResult]
    ) -> [ProjectionCacheEntry] {
        cache.map { key, result in
            ProjectionCacheEntry(revision: key.revision, horizon: key.horizon, result: result)
        }
        .sorted {
            ($0.revision, $0.horizon?.description ?? "") < ($1.revision, $1.horizon?.description ?? "")
        }
    }

    private static func mergeProjectionPrefix(
        _ previous: ProjectionResult,
        suffix: ProjectionResult,
        startingAt month: BudgetMonth
    ) -> ProjectionResult {
        let prefixMonths = previous.months.filter { $0.month < month }
        var checkpoints = previous.checkpoints.filter { $0.key < month }
        checkpoints.merge(suffix.checkpoints) { _, replacement in replacement }
        return ProjectionResult(
            months: prefixMonths + suffix.months,
            registerBalances: suffix.registerBalances,
            projectionBalances: suffix.projectionBalances,
            postingDecisions: suffix.postingDecisions,
            checkpoints: checkpoints,
            horizon: suffix.horizon
        )
    }

    /// Generation-pinned sync commit. This centralizes the stale-response gate
    /// at the sole database-writer boundary so no caller can mutate workspace
    /// or cursor state through a disconnected/replaced credential generation.
    @discardableResult
    public func syncTransact<T: Sendable>(
        nowEpoch: Int64,
        expectedCredentialPin: SimpleFINConnectionPin,
        _ body: @Sendable (inout BudgetWorkspace, inout SimpleFINConnectionState) throws -> T
    ) throws -> T {
        try syncTransact(nowEpoch: nowEpoch) { workspace, stored in
            guard var current = stored,
                  current.matchesActiveCredential(expectedCredentialPin) else {
                throw SimpleFINConnectionPinError.connectionChanged
            }
            let result = try body(&workspace, &current)
            stored = current
            return result
        }
    }

    // MARK: - Explicit sync-record resolution

    /// Resolves one persisted §4.3 conflict through the sole durable writer.
    /// Connection state is read for stored sign normalization and written back
    /// unchanged in the same atomic save as the workspace resolution.
    @discardableResult
    public func resolveSyncConflict(
        _ command: SyncConflictResolutionCommand,
        nowEpoch: Int64
    ) throws -> SyncConflictResolutionResult {
        try syncTransact(nowEpoch: nowEpoch) { workspace, state in
            try workspace.resolveSyncConflict(
                command,
                simpleFINState: state,
                nowEpoch: nowEpoch
            )
        }
    }

    /// Resolves one persisted §4.4 snapshot discrepancy. All validation,
    /// adjustment insertion, replay, terminal state, and audit data are part
    /// of one workspace candidate and one DatabasePool.write.
    @discardableResult
    public func resolveSnapshotDiscrepancy(
        _ command: SnapshotDiscrepancyResolutionCommand,
        nowEpoch: Int64
    ) throws -> SnapshotDiscrepancyResolutionResult {
        try syncTransact(nowEpoch: nowEpoch) { workspace, state in
            guard let discrepancy = workspace.snapshotDiscrepancies[command.discrepancyID] else {
                throw SyncResolutionError.discrepancyNotFound
            }
            guard discrepancy.budgetID == workspace.budget.id else {
                throw SyncResolutionError.budgetMismatch
            }
            guard discrepancy.status == .open else {
                throw SyncResolutionError.discrepancyNotOpen
            }
            var successorMigrationLinkIndex: Int?
            if case .accountClosedOffBudget = command.choice {
                guard let connection = state else {
                    throw SyncResolutionError.missingReference
                }
                let matchingIndices: [Int]
                if let identity = discrepancy.simpleFINLinkIdentity {
                    matchingIndices = connection.links.indices.filter {
                        connection.links[$0].identity == identity
                            && connection.links[$0].localAccountID == discrepancy.accountID
                    }
                } else {
                    matchingIndices = connection.links.indices.filter {
                        connection.links[$0].localAccountID == discrepancy.accountID
                    }
                }
                guard matchingIndices.count == 1 else {
                    throw SyncResolutionError.missingReference
                }
                successorMigrationLinkIndex = matchingIndices[0]
            }
            let result = try workspace.resolveSnapshotDiscrepancy(command, nowEpoch: nowEpoch)

            if let linkIndex = successorMigrationLinkIndex {
                guard case .offBudgetSuccessor(let successorID) = result.artifact,
                      var connection = state,
                      connection.links.indices.contains(linkIndex),
                      connection.links[linkIndex].localAccountID == discrepancy.accountID else {
                    throw SyncResolutionError.dependencyInvalid
                }
                connection.links[linkIndex].localAccountID = successorID
                connection.links[linkIndex].resume()
                state = connection
                return result
            }

            // Pre-M5.9.1/manual workspace rows have no link identity and may
            // legitimately have no SimpleFIN state at all. Preserve their
            // workspace-only resolution semantics. New sync-created rows have
            // an identity and must find that exact persisted link before this
            // transaction can commit.
            guard var connection = state else {
                guard discrepancy.simpleFINLinkIdentity == nil else {
                    throw SyncResolutionError.missingReference
                }
                return result
            }

            let linkIdentity: String
            if let persistedIdentity = discrepancy.simpleFINLinkIdentity {
                linkIdentity = persistedIdentity
            } else {
                let matchingLinks = connection.links.filter {
                    $0.localAccountID == discrepancy.accountID
                }
                guard matchingLinks.count == 1,
                      let onlyMatch = matchingLinks.first else {
                    // Legacy rows without a canonical identity are unsafe to
                    // resolve when account-to-link ownership is missing or
                    // ambiguous.
                    throw SyncResolutionError.missingReference
                }
                linkIdentity = onlyMatch.identity
            }

            guard let linkIndex = connection.links.firstIndex(where: {
                $0.identity == linkIdentity && $0.localAccountID == discrepancy.accountID
            }) else {
                throw SyncResolutionError.missingReference
            }

            let hasOtherOpenDiscrepancy = workspace.snapshotDiscrepancies.values.contains {
                guard $0.id != command.discrepancyID, $0.status == .open else { return false }
                if let identity = $0.simpleFINLinkIdentity {
                    return identity == linkIdentity
                }
                return $0.accountID == discrepancy.accountID
            }
            if !hasOtherOpenDiscrepancy {
                let canReactivateLink = connection.activeCredentialPin != nil
                    && !connection.disconnectPausedLinkIdentities.contains(linkIdentity)
                    && !connection.authRevokedLinkIdentitiesAwaitingReconnect.contains(linkIdentity)
                let didClearSnapshotPause = connection.links[linkIndex].clearSnapshotDiscrepancyPause()
                if didClearSnapshotPause && !canReactivateLink {
                    // Resolution clears only the snapshot reason. A disconnected,
                    // pending, or reconnect-gated connection must not be
                    // accidentally reactivated by that narrower operation.
                    connection.links[linkIndex].status = .paused
                    if connection.status == .disconnected
                        || connection.credentialDisconnectPending
                        || connection.keychainItemID == nil,
                       !connection.disconnectPausedLinkIdentities.contains(linkIdentity) {
                        connection.disconnectPausedLinkIdentities.append(linkIdentity)
                    }
                    if connection.credentialAuthorizationRevoked,
                       !connection.authRevokedLinkIdentitiesAwaitingReconnect.contains(linkIdentity) {
                        connection.authRevokedLinkIdentitiesAwaitingReconnect.append(linkIdentity)
                    }
                }
                let hasPendingClosedMonthImports = workspace.transactions.values.contains {
                    $0.accountID == discrepancy.accountID
                        && $0.postingState == .staged
                        && $0.stageReason == .closedMonthImport
                }
                if hasPendingClosedMonthImports,
                   connection.links[linkIndex].status == .active,
                   connection.links[linkIndex].pauseReason == nil {
                    connection.links[linkIndex].pauseReason = .closedMonthImportPending
                }
            }
            state = connection
            return result
        }
    }

    public func backup(to destination: URL) throws {
        try store.backup(to: destination)
    }

    // MARK: - SimpleFIN connection state (single-writer boundary)

    public func simpleFINState() throws -> SimpleFINConnectionState? {
        guard let workspace else { throw BudgetMutationServiceError.noLoadedBudget }
        return try store.loadSimpleFINState(budgetID: workspace.budget.id)
    }

    /// Starts a durable request-log row before network I/O. This is a separate
    /// small write from the eventual per-account sync transaction so an
    /// interrupted request remains visible as an incomplete attempt.
    public func beginSyncRequest(
        connectionID: String,
        accountID: AccountID? = nil,
        requestedStartEpoch: Int64? = nil,
        requestedEndEpoch: Int64? = nil,
        startedAtEpoch: Int64
    ) throws -> SyncRequestLog {
        guard let workspace else { throw BudgetMutationServiceError.noLoadedBudget }
        let log = SyncRequestLog(
            budgetID: workspace.budget.id,
            connectionID: connectionID,
            accountID: accountID,
            requestedStartEpoch: requestedStartEpoch,
            requestedEndEpoch: requestedEndEpoch,
            startedAtEpoch: startedAtEpoch
        )
        try store.insertSyncRequestLog(log)
        return log
    }

    public func finishSyncRequest(
        _ log: SyncRequestLog,
        status: SyncRequestLog.Status,
        completedAtEpoch: Int64,
        httpStatus: Int? = nil,
        retryAfterSeconds: Int64? = nil
    ) throws {
        try store.finishSyncRequestLog(
            id: log.id,
            status: status,
            completedAtEpoch: completedAtEpoch,
            httpStatus: httpStatus,
            retryAfterSeconds: retryAfterSeconds
        )
    }

    public func latestSyncRequestStartedAtEpoch() throws -> Int64? {
        guard let workspace else { throw BudgetMutationServiceError.noLoadedBudget }
        return try store.latestSyncRequestStartedAtEpoch(budgetID: workspace.budget.id)
    }

    public func syncRequestLogs(limit: Int = 100) throws -> [SyncRequestLog] {
        guard let workspace else { throw BudgetMutationServiceError.noLoadedBudget }
        return try store.syncRequestLogs(budgetID: workspace.budget.id, limit: limit)
    }

    /// Reads, mutates, and persists the connection state through the same
    /// serialized actor as budget writes. Setting the state to `nil` deletes
    /// the row (used only by tests; production disconnect keeps a tombstone).
    @discardableResult
    public func updateSimpleFINState(
        nowEpoch: Int64,
        _ body: @Sendable (inout SimpleFINConnectionState?) throws -> Void
    ) throws -> SimpleFINConnectionState? {
        guard let workspace else { throw BudgetMutationServiceError.noLoadedBudget }
        var state = loadedSimpleFINState
        let expectedState = state
        let existingSignViolations = Self.simpleFINSignViolations(
            workspace: workspace,
            state: state
        )
        try body(&state)
        try Self.rejectNewSimpleFINSignViolations(
            existing: existingSignViolations,
            workspace: workspace,
            state: state
        )
        do {
            try store.saveSimpleFINStateIfUnchanged(
                state,
                expectedState: expectedState,
                budgetID: workspace.budget.id,
                nowEpoch: nowEpoch
            )
        } catch let error as LedgerPersistenceError {
            if Self.isConcurrencyConflict(error) {
                _ = try? reload()
            }
            throw error
        }
        loadedSimpleFINState = state
        return state
    }

    private static func isConcurrencyConflict(_ error: LedgerPersistenceError) -> Bool {
        switch error {
        case .concurrentModification, .concurrentSimpleFINStateModification:
            return true
        default:
            return false
        }
    }

    /// Rejects a newly linked inverted cash-like account at the durable actor
    /// boundary. Exact pre-existing violations are tolerated only so a legacy
    /// tombstone cannot block retryable credential disconnect/cleanup; the
    /// sync engine independently refuses to process such a link.
    private static func rejectNewSimpleFINSignViolations(
        existing: Set<SimpleFINSignViolation>,
        workspace: BudgetWorkspace,
        state: SimpleFINConnectionState?
    ) throws {
        let candidate = simpleFINSignViolations(workspace: workspace, state: state)
        guard candidate.isSubset(of: existing) else {
            throw SimpleFINSignNormalizationError.invertedCashLikeAccount
        }
    }

    private static func simpleFINSignViolations(
        workspace: BudgetWorkspace,
        state: SimpleFINConnectionState?
    ) -> Set<SimpleFINSignViolation> {
        Set((state?.links ?? []).compactMap { link in
            guard link.signNormalization == .inverted,
                  let localAccountID = link.localAccountID,
                  workspace.accounts[localAccountID]?.type.isCashLike == true else {
                return nil
            }
            return SimpleFINSignViolation(
                linkIdentity: link.identity,
                localAccountID: localAccountID
            )
        })
    }
}

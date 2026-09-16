import Foundation

public struct AllocationKey: Hashable, Sendable {
    public var categoryID: CategoryID
    public var month: BudgetMonth
    public init(categoryID: CategoryID, month: BudgetMonth) {
        self.categoryID = categoryID
        self.month = month
    }
}

/// In-memory value-type projection of one budget's full mutable state, plus
/// the validated mutation surface. The persistence layer loads rows into a
/// workspace, applies exactly one mutation, and persists the diff inside one
/// `DatabasePool.write` transaction; tests drive it directly.
///
/// Mutations follow a strict pattern: validate → mutate a copy → run the
/// deterministic replay/re-staging pass (§4.3) → assert the conservation
/// oracle → commit. A thrown error leaves the workspace byte-for-byte
/// unchanged.
public struct BudgetWorkspace: Sendable, Equatable {
    public private(set) var budget: BudgetRow
    public private(set) var accounts: [AccountID: AccountRow] = [:]
    public private(set) var categoryGroups: [CategoryGroupID: CategoryGroupRow] = [:]
    public private(set) var categories: [CategoryID: CategoryRow] = [:]
    public private(set) var payees: [PayeeID: PayeeRow] = [:]
    public private(set) var allocations: [AllocationKey: AllocationRow] = [:]
    public private(set) var transactions: [TransactionID: TransactionRow] = [:]
    public private(set) var transferPairs: [TransferPairID: TransferPairRow] = [:]
    public private(set) var legSnapshots: [TransferPairID: [TransferPairLegSnapshotRow]] = [:]
    public private(set) var closedMonths: [BudgetMonth: ClosedMonthRow] = [:]
    public private(set) var auditEvents: [AuditEventRow] = []
    /// Transaction IDs currently reconciled into a completed reconciliation.
    public private(set) var reconciliationMembership: Set<TransactionID> = []
    /// Reconciliation history (§3.9 steps 6–7).
    public private(set) var reconciliations: [ReconciliationID: ReconciliationRow] = [:]
    /// Fingerprinted membership rows per reconciliation.
    public private(set) var reconciliationTransactions: [ReconciliationID: [ReconciliationTransactionRow]] = [:]
    /// Per-remote-row import identity and last-seen state, keyed by the local
    /// transaction (§2.1: `source_kind == .simplefin` iff a record exists).
    public private(set) var simpleFINImports: [TransactionID: SimpleFINImportRecord] = [:]
    /// Open/resolved remote-change, disappearance, and duplicate conflicts (§4.3).
    public private(set) var syncConflicts: [SyncConflictID: SyncConflictRow] = [:]
    /// §4.4 post-sync balance mismatches, at most one `open` per account.
    public private(set) var snapshotDiscrepancies: [SnapshotDiscrepancyID: SnapshotDiscrepancyRow] = [:]
    /// Budget-scoped automation rules (docs/DESIGN.md D4).
    public private(set) var automationRules: [AutomationRuleID: AutomationRule] = [:]
    /// File-import identity per transaction (`source_kind == .file` iff present).
    public private(set) var fileImports: [TransactionID: FileImportRecord] = [:]
    public private(set) var importBatches: [ImportBatchID: ImportBatchRow] = [:]
    public private(set) var importMappings: [ImportMappingID: ImportMappingRow] = [:]
    /// Saved report definitions (docs/DESIGN.md D7).
    public private(set) var reports: [ReportID: ReportRow] = [:]
    /// Schedules, their sparse occurrences, and open match reviews (D5).
    public private(set) var schedules: [ScheduleID: Schedule] = [:]
    public private(set) var scheduleOccurrences: [ScheduleOccurrenceKey: ScheduleOccurrence] = [:]
    public private(set) var scheduleReviews: [ScheduleReviewID: ScheduleMatchReview] = [:]

    public let rtaCategoryID: CategoryID
    public let uncategorizedID: CategoryID
    public private(set) var systemPayeeIDs: [PayeeSystemKind: PayeeID] = [:]
    public private(set) var creditCardPaymentsGroupID: CategoryGroupID?

    public let calendar: BudgetCalendar

    // MARK: - Bootstrap (§2.2)

    /// Creates the budget with default groups, placeholder categories, system
    /// categories, and system payees. `firstMonth` must not be in the future
    /// relative to `currentMonth` (both in the budget time zone).
    public static func create(
        name: String,
        currency: String,
        timeZoneIdentifier: String,
        firstMonth: BudgetMonth,
        currentMonth: BudgetMonth,
        nowEpoch: Int64,
        sortOrder: Int = 0
    ) throws -> BudgetWorkspace {
        guard firstMonth <= currentMonth else {
            throw MutationError.futureDatedTransaction
        }
        let budget = BudgetRow(
            name: name,
            currency: currency,
            timeZoneIdentifier: timeZoneIdentifier,
            firstMonth: firstMonth,
            lastObservedBudgetMonth: currentMonth,
            createdAtEpoch: nowEpoch,
            sortOrder: sortOrder
        )
        return try BudgetWorkspace(budget: budget)
    }

    init(budget: BudgetRow) throws {
        var groups: [CategoryGroupID: CategoryGroupRow] = [:]
        var cats: [CategoryID: CategoryRow] = [:]
        var payeeRows: [PayeeID: PayeeRow] = [:]
        var systemIDs: [PayeeSystemKind: PayeeID] = [:]

        // Default groups.
        var sort = 0
        func group(_ name: String) -> CategoryGroupRow {
            defer { sort += 1 }
            let g = CategoryGroupRow(budgetID: budget.id, name: name, sortOrder: sort)
            groups[g.id] = g
            return g
        }
        let fixed = group("Fixed Expenses")
        let savings = group("Savings")
        let everyday = group("Everyday Spending")
        let needsAttention = group("Needs Attention")

        // System categories: RTA lives outside user groups conceptually; it is
        // parented to Needs Attention for storage but is immutable and never
        // allocatable.
        let rta = CategoryRow(
            budgetID: budget.id, groupID: needsAttention.id, name: "Inflow: Ready to Assign",
            sortOrder: 0, kind: .inflow, systemKind: .readyToAssign
        )
        cats[rta.id] = rta

        let uncategorized = CategoryRow(
            budgetID: budget.id, groupID: needsAttention.id, name: "Uncategorized",
            sortOrder: 1, kind: .spending, systemKind: .uncategorized
        )
        cats[uncategorized.id] = uncategorized

        // Editable placeholder categories.
        var catSort = 0
        func placeholder(_ name: String, in group: CategoryGroupRow) {
            defer { catSort += 1 }
            let c = CategoryRow(budgetID: budget.id, groupID: group.id, name: name, sortOrder: catSort, kind: .spending)
            cats[c.id] = c
        }
        placeholder("Rent", in: fixed)
        placeholder("Utilities", in: fixed)
        placeholder("Emergency Fund", in: savings)
        placeholder("Groceries", in: everyday)
        placeholder("Dining", in: everyday)
        placeholder("Transport", in: everyday)

        // System payees.
        func systemPayee(_ kind: PayeeSystemKind, _ display: String) {
            let p = PayeeRow(
                budgetID: budget.id, systemKind: kind, namespace: .system,
                name: BudgetWorkspace.normalizePayeeName(display), displayName: display
            )
            payeeRows[p.id] = p
            systemIDs[kind] = p.id
        }
        systemPayee(.openingBalance, "Opening Balance")
        systemPayee(.transfer, "Transfer")
        systemPayee(.reconciliationAdjustment, "Reconciliation Balance Adjustment")
        systemPayee(.cardDebtAdjustment, "Card Debt Adjustment")
        systemPayee(.unknown, "Unknown Payee")

        self.budget = budget
        self.calendar = try BudgetCalendar(timeZoneIdentifier: budget.timeZoneIdentifier)
        self.categoryGroups = groups
        self.categories = cats
        self.payees = payeeRows
        self.systemPayeeIDs = systemIDs
        self.rtaCategoryID = rta.id
        self.uncategorizedID = uncategorized.id
    }

    // MARK: - Derived accessors

    public var currentMonth: BudgetMonth { budget.lastObservedBudgetMonth }

    public func systemPayeeID(_ kind: PayeeSystemKind) -> PayeeID {
        systemPayeeIDs[kind]!
    }

    public func paymentCategoryID(forCard accountID: AccountID) -> CategoryID? {
        categories.values.first { $0.kind == .ccPayment && $0.linkedAccountID == accountID }?.id
    }

    public func isMonthClosed(_ month: BudgetMonth) -> Bool {
        closedMonths[month]?.status == .closed
    }

    /// NFKC + uppercase + whitespace-collapse (deterministic built-in
    /// normalizer; configurable rename rules are v1.1).
    public static func normalizePayeeName(_ raw: String) -> String {
        let nfkc = raw.precomposedStringWithCompatibilityMapping
        let collapsed = nfkc
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.uppercased()
    }

    public func replayInput() -> ReplayInput {
        ReplayInput(
            budget: budget,
            accounts: accounts,
            categories: categories,
            allocations: allocations.values.sorted {
                ($0.month, $0.categoryID) < ($1.month, $1.categoryID)
            },
            transactions: transactions.values.sorted { $0.id < $1.id },
            transferPairs: transferPairs,
            closedMonths: Set(closedMonths.values.filter { $0.status == .closed }.map(\.month))
        )
    }

    /// Returns the earliest month whose replay may change when moving from
    /// `previous` to this workspace. Metadata-only mutations return `nil` so a
    /// cached projection can be reused across the revision bump.
    public func earliestProjectionAffectedMonth(comparedTo previous: BudgetWorkspace) -> BudgetMonth? {
        var earliest: BudgetMonth?

        func mark(_ month: BudgetMonth) {
            if earliest == nil || month < earliest! { earliest = month }
        }

        if budget.firstMonth != previous.budget.firstMonth
            || budget.currency != previous.budget.currency
            || budget.timeZoneIdentifier != previous.budget.timeZoneIdentifier
        {
            mark(budget.firstMonth)
        }
        if accounts != previous.accounts
            || categories != previous.categories
            || transferPairs != previous.transferPairs
            || closedMonths != previous.closedMonths
        {
            mark(budget.firstMonth)
        }

        for key in Set(allocations.keys).union(previous.allocations.keys)
        where allocations[key] != previous.allocations[key] {
            mark(key.month)
        }
        for id in Set(transactions.keys).union(previous.transactions.keys)
        where transactions[id] != previous.transactions[id] {
            if let month = transactions[id]?.date.budgetMonth ?? previous.transactions[id]?.date.budgetMonth {
                mark(month)
            } else {
                mark(budget.firstMonth)
            }
        }
        if reconciliationMembership != previous.reconciliationMembership {
            for id in reconciliationMembership.union(previous.reconciliationMembership) {
                if let month = transactions[id]?.date.budgetMonth ?? previous.transactions[id]?.date.budgetMonth {
                    mark(month)
                } else {
                    mark(budget.firstMonth)
                }
            }
        }
        return earliest
    }

    public func projection(through horizon: BudgetMonth? = nil) throws -> ProjectionResult {
        try ReplayEngine.replay(replayInput(), through: horizon)
    }

    // MARK: - Internal mutation plumbing

    mutating func bumpRevision() throws {
        budget.revision = try addChecked(budget.revision, 1)
    }

    mutating func allocateSourceSequence() throws -> Int64 {
        let seq = budget.nextLocalSourceSequence
        budget.nextLocalSourceSequence = try addChecked(budget.nextLocalSourceSequence, 1)
        return seq
    }

    mutating func recordAudit(entityType: String, entityID: String, eventKind: String, metadata: [String: String] = [:], nowEpoch: Int64) {
        auditEvents.append(AuditEventRow(
            budgetID: budget.id,
            entityType: entityType,
            entityID: entityID,
            eventKind: eventKind,
            metadata: metadata,
            createdAtEpoch: nowEpoch
        ))
    }

    mutating func setTransaction(_ row: TransactionRow) {
        transactions[row.id] = row
    }

    mutating func removeTransaction(_ id: TransactionID) {
        transactions.removeValue(forKey: id)
    }

    mutating func setAllocation(_ row: AllocationRow) {
        let key = AllocationKey(categoryID: row.categoryID, month: row.month)
        if row.budgetedMilliunits == 0 {
            allocations.removeValue(forKey: key) // sparse: zero rows mean zero
        } else {
            allocations[key] = row
        }
    }

    mutating func setAccount(_ row: AccountRow) { accounts[row.id] = row }
    mutating func setCategory(_ row: CategoryRow) { categories[row.id] = row }
    mutating func setCategoryGroup(_ row: CategoryGroupRow) { categoryGroups[row.id] = row }
    mutating func setPayee(_ row: PayeeRow) { payees[row.id] = row }
    mutating func setTransferPair(_ row: TransferPairRow) { transferPairs[row.id] = row }
    mutating func setCreditCardPaymentsGroupID(_ id: CategoryGroupID) { creditCardPaymentsGroupID = id }
    mutating func setClosedMonth(_ row: ClosedMonthRow) { closedMonths[row.month] = row }
    mutating func setLegSnapshots(_ pairID: TransferPairID, _ rows: [TransferPairLegSnapshotRow]) {
        legSnapshots[pairID] = rows
    }
    mutating func removeLegSnapshots(_ pairID: TransferPairID) {
        legSnapshots.removeValue(forKey: pairID)
    }
    mutating func removeTransferPair(_ id: TransferPairID) {
        transferPairs.removeValue(forKey: id)
    }
    mutating func advanceBudgetMonth(_ month: BudgetMonth) {
        budget.lastObservedBudgetMonth = month
    }
    mutating func setBudgetName(_ name: String) { budget.name = name }
    mutating func setBudgetSortOrder(_ order: Int) { budget.sortOrder = order }
    mutating func setBudgetArchivedFlag(_ archived: Bool) { budget.archived = archived }
    mutating func insertReconciliationMembership(_ id: TransactionID) {
        reconciliationMembership.insert(id)
    }
    mutating func removeReconciliationMembership(_ id: TransactionID) {
        reconciliationMembership.remove(id)
    }
    mutating func setReconciliation(_ row: ReconciliationRow) {
        reconciliations[row.id] = row
    }
    mutating func setReconciliationTransactions(_ id: ReconciliationID, _ rows: [ReconciliationTransactionRow]) {
        reconciliationTransactions[id] = rows
    }
    mutating func setSimpleFINImport(_ record: SimpleFINImportRecord) {
        simpleFINImports[record.transactionID] = record
    }
    mutating func setSyncConflict(_ row: SyncConflictRow) {
        syncConflicts[row.id] = row
    }
    mutating func setSnapshotDiscrepancy(_ row: SnapshotDiscrepancyRow) {
        snapshotDiscrepancies[row.id] = row
    }
    mutating func setAutomationRule(_ rule: AutomationRule) {
        automationRules[rule.id] = rule
    }
    mutating func removeAutomationRule(_ id: AutomationRuleID) {
        automationRules.removeValue(forKey: id)
    }
    mutating func setFileImport(_ record: FileImportRecord) {
        fileImports[record.transactionID] = record
    }
    mutating func setImportBatch(_ row: ImportBatchRow) {
        importBatches[row.id] = row
    }
    mutating func setImportMapping(_ row: ImportMappingRow) {
        importMappings[row.id] = row
    }
    mutating func removeImportMapping(_ id: ImportMappingID) {
        importMappings.removeValue(forKey: id)
    }
    mutating func setReport(_ row: ReportRow) {
        reports[row.id] = row
    }
    mutating func removeReport(_ id: ReportID) {
        reports.removeValue(forKey: id)
    }
    mutating func setSchedule(_ row: Schedule) { schedules[row.id] = row }
    mutating func removeSchedule(_ id: ScheduleID) { schedules.removeValue(forKey: id) }
    mutating func setScheduleOccurrence(_ row: ScheduleOccurrence) { scheduleOccurrences[row.key] = row }
    mutating func removeScheduleOccurrence(_ key: ScheduleOccurrenceKey) { scheduleOccurrences.removeValue(forKey: key) }
    mutating func setScheduleReview(_ row: ScheduleMatchReview) { scheduleReviews[row.id] = row }
    mutating func removeScheduleReview(_ id: ScheduleReviewID) { scheduleReviews.removeValue(forKey: id) }

    /// Composite-identity lookup mirroring the unique
    /// `(connection_key, remote_account_id, remote_transaction_id)` constraint.
    public func simpleFINImportRecord(
        connectionKey: String, remoteAccountID: String, remoteTransactionID: String
    ) -> SimpleFINImportRecord? {
        simpleFINImports.values.first {
            $0.connectionKey == connectionKey
                && $0.remoteAccountID == remoteAccountID
                && $0.remoteTransactionID == remoteTransactionID
        }
    }

    /// Full-state equality over every persisted collection (the calendar is
    /// derived from the immutable budget row). Used by tests to verify that a
    /// rejected mutation leaves the prior state byte-for-byte unchanged.
    public static func == (lhs: BudgetWorkspace, rhs: BudgetWorkspace) -> Bool {
        lhs.budget == rhs.budget
            && lhs.accounts == rhs.accounts
            && lhs.categoryGroups == rhs.categoryGroups
            && lhs.categories == rhs.categories
            && lhs.payees == rhs.payees
            && lhs.allocations == rhs.allocations
            && lhs.transactions == rhs.transactions
            && lhs.transferPairs == rhs.transferPairs
            && lhs.legSnapshots == rhs.legSnapshots
            && lhs.closedMonths == rhs.closedMonths
            && lhs.auditEvents == rhs.auditEvents
            && lhs.reconciliationMembership == rhs.reconciliationMembership
            && lhs.reconciliations == rhs.reconciliations
            && lhs.reconciliationTransactions == rhs.reconciliationTransactions
            && lhs.creditCardPaymentsGroupID == rhs.creditCardPaymentsGroupID
            && lhs.simpleFINImports == rhs.simpleFINImports
            && lhs.syncConflicts == rhs.syncConflicts
            && lhs.snapshotDiscrepancies == rhs.snapshotDiscrepancies
            && lhs.automationRules == rhs.automationRules
            && lhs.fileImports == rhs.fileImports
            && lhs.importBatches == rhs.importBatches
            && lhs.importMappings == rhs.importMappings
            && lhs.reports == rhs.reports
            && lhs.schedules == rhs.schedules
            && lhs.scheduleOccurrences == rhs.scheduleOccurrences
            && lhs.scheduleReviews == rhs.scheduleReviews
    }

    /// Runs the deterministic replay pass, persists changed posting
    /// classifications (the §4.3 re-staging pass), and returns the projection.
    /// Applying the returned decisions twice is a no-op.
    @discardableResult
    mutating func runReplayAndApplyDecisions() throws -> ProjectionResult {
        let result = try ReplayEngine.replay(replayInput())
        for (id, decision) in result.postingDecisions {
            guard var row = transactions[id] else {
                throw IntegrityError(code: .invalidReference)
            }
            guard decision.postingState != row.postingState || decision.stageReason != row.stageReason else {
                continue
            }
            let wasStaged = row.postingState == .staged
            let willBeStaged = decision.postingState == .staged
            if !wasStaged && willBeStaged {
                // Newly staged: stash the category so re-staging is
                // deterministic and resolution can restore it (§2.1).
                var meta = row.stageMetadata ?? StageMetadata()
                if meta.proposedCategoryID == nil { meta.proposedCategoryID = row.categoryID }
                if meta.refundOfTransactionID == nil { meta.refundOfTransactionID = row.refundOfTransactionID }
                row.stageMetadata = meta
                row.categoryID = nil
            } else if wasStaged && !willBeStaged {
                // Condition no longer applies: restore the proposed category.
                if row.categoryID == nil { row.categoryID = row.stageMetadata?.proposedCategoryID }
                // A linked refund's category is a materialized copy of its
                // origin's current spending category (§3.5.3).
                if row.categoryID == nil, row.kind == .refund, let originID = row.refundOfTransactionID,
                   let origin = transactions[originID] {
                    row.categoryID = origin.categoryID ?? origin.stageMetadata?.proposedCategoryID
                }
                row.stageMetadata = nil
            }
            row.postingState = decision.postingState
            row.stageReason = willBeStaged ? decision.stageReason : nil
            transactions[id] = row
        }
        return result
    }
}

// MARK: - Durable workspace snapshots

/// Codable, deterministic representation of the complete in-memory ledger.
/// SQLite stores this as a transactionally replaced state payload while the
/// normalized schema tables provide queryable metadata and future migrations.
public struct BudgetWorkspaceSnapshot: Codable, Sendable, Equatable {
    public struct SystemPayee: Codable, Sendable, Equatable {
        public var kind: PayeeSystemKind
        public var id: PayeeID
        public init(kind: PayeeSystemKind, id: PayeeID) {
            self.kind = kind
            self.id = id
        }
    }

    public struct LegSnapshotGroup: Codable, Sendable, Equatable {
        public var pairID: TransferPairID
        public var rows: [TransferPairLegSnapshotRow]
        public init(pairID: TransferPairID, rows: [TransferPairLegSnapshotRow]) {
            self.pairID = pairID
            self.rows = rows
        }
    }

    public struct ReconciliationGroup: Codable, Sendable, Equatable {
        public var reconciliation: ReconciliationRow
        public var members: [ReconciliationTransactionRow]
        public init(reconciliation: ReconciliationRow, members: [ReconciliationTransactionRow]) {
            self.reconciliation = reconciliation
            self.members = members
        }
    }

    public var budget: BudgetRow
    public var accounts: [AccountRow]
    public var categoryGroups: [CategoryGroupRow]
    public var categories: [CategoryRow]
    public var payees: [PayeeRow]
    public var allocations: [AllocationRow]
    public var transactions: [TransactionRow]
    public var transferPairs: [TransferPairRow]
    public var legSnapshots: [LegSnapshotGroup]
    public var closedMonths: [ClosedMonthRow]
    public var auditEvents: [AuditEventRow]
    public var reconciliationMembership: [TransactionID]
    public var reconciliations: [ReconciliationGroup]
    public var simpleFINImports: [SimpleFINImportRecord]
    public var syncConflicts: [SyncConflictRow]
    public var snapshotDiscrepancies: [SnapshotDiscrepancyRow]
    public var automationRules: [AutomationRule]
    public var fileImports: [FileImportRecord]
    public var importBatches: [ImportBatchRow]
    public var importMappings: [ImportMappingRow]
    public var reports: [ReportRow]
    public var schedules: [Schedule]
    public var scheduleOccurrences: [ScheduleOccurrence]
    public var scheduleReviews: [ScheduleMatchReview]
    public var rtaCategoryID: CategoryID
    public var uncategorizedID: CategoryID
    public var systemPayees: [SystemPayee]
    public var creditCardPaymentsGroupID: CategoryGroupID?

    public init(
        budget: BudgetRow,
        accounts: [AccountRow],
        categoryGroups: [CategoryGroupRow],
        categories: [CategoryRow],
        payees: [PayeeRow],
        allocations: [AllocationRow],
        transactions: [TransactionRow],
        transferPairs: [TransferPairRow],
        legSnapshots: [LegSnapshotGroup],
        closedMonths: [ClosedMonthRow],
        auditEvents: [AuditEventRow],
        reconciliationMembership: [TransactionID],
        reconciliations: [ReconciliationGroup] = [],
        simpleFINImports: [SimpleFINImportRecord] = [],
        syncConflicts: [SyncConflictRow] = [],
        snapshotDiscrepancies: [SnapshotDiscrepancyRow] = [],
        automationRules: [AutomationRule] = [],
        fileImports: [FileImportRecord] = [],
        importBatches: [ImportBatchRow] = [],
        importMappings: [ImportMappingRow] = [],
        reports: [ReportRow] = [],
        schedules: [Schedule] = [],
        scheduleOccurrences: [ScheduleOccurrence] = [],
        scheduleReviews: [ScheduleMatchReview] = [],
        rtaCategoryID: CategoryID,
        uncategorizedID: CategoryID,
        systemPayees: [SystemPayee],
        creditCardPaymentsGroupID: CategoryGroupID?
    ) {
        self.budget = budget
        self.accounts = accounts
        self.categoryGroups = categoryGroups
        self.categories = categories
        self.payees = payees
        self.allocations = allocations
        self.transactions = transactions
        self.transferPairs = transferPairs
        self.legSnapshots = legSnapshots
        self.closedMonths = closedMonths
        self.auditEvents = auditEvents
        self.reconciliationMembership = reconciliationMembership
        self.reconciliations = reconciliations
        self.simpleFINImports = simpleFINImports
        self.syncConflicts = syncConflicts
        self.snapshotDiscrepancies = snapshotDiscrepancies
        self.automationRules = automationRules
        self.fileImports = fileImports
        self.importBatches = importBatches
        self.importMappings = importMappings
        self.reports = reports
        self.schedules = schedules
        self.scheduleOccurrences = scheduleOccurrences
        self.scheduleReviews = scheduleReviews
        self.rtaCategoryID = rtaCategoryID
        self.uncategorizedID = uncategorizedID
        self.systemPayees = systemPayees
        self.creditCardPaymentsGroupID = creditCardPaymentsGroupID
    }

    /// Custom decode only so payloads written before the reconciliation
    /// history and SimpleFIN sync records existed still load (the new fields
    /// default to empty).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.budget = try container.decode(BudgetRow.self, forKey: .budget)
        self.accounts = try container.decode([AccountRow].self, forKey: .accounts)
        self.categoryGroups = try container.decode([CategoryGroupRow].self, forKey: .categoryGroups)
        self.categories = try container.decode([CategoryRow].self, forKey: .categories)
        self.payees = try container.decode([PayeeRow].self, forKey: .payees)
        self.allocations = try container.decode([AllocationRow].self, forKey: .allocations)
        var decodedTransactions = try container.decode([TransactionRow].self, forKey: .transactions)
        // Backfill (D4.2): rows imported before `importedDescription` existed
        // take their payee display name, which was initialized from the raw
        // provider string. Deterministic, so repeated loads agree.
        let payeeDisplayNames = Dictionary(
            self.payees.map { ($0.id, $0.displayName) },
            uniquingKeysWith: { first, _ in first }
        )
        for index in decodedTransactions.indices
        where decodedTransactions[index].sourceKind == .simplefin
            && decodedTransactions[index].importedDescription == nil {
            if let payeeID = decodedTransactions[index].payeeID,
               let display = payeeDisplayNames[payeeID] {
                decodedTransactions[index].importedDescription = display
            }
        }
        self.transactions = decodedTransactions
        self.transferPairs = try container.decode([TransferPairRow].self, forKey: .transferPairs)
        self.legSnapshots = try container.decode([LegSnapshotGroup].self, forKey: .legSnapshots)
        self.closedMonths = try container.decode([ClosedMonthRow].self, forKey: .closedMonths)
        self.auditEvents = try container.decode([AuditEventRow].self, forKey: .auditEvents)
        self.reconciliationMembership = try container.decode([TransactionID].self, forKey: .reconciliationMembership)
        self.reconciliations = try container.decodeIfPresent([ReconciliationGroup].self, forKey: .reconciliations) ?? []
        self.simpleFINImports = try container.decodeIfPresent([SimpleFINImportRecord].self, forKey: .simpleFINImports) ?? []
        self.syncConflicts = try container.decodeIfPresent([SyncConflictRow].self, forKey: .syncConflicts) ?? []
        self.snapshotDiscrepancies = try container.decodeIfPresent([SnapshotDiscrepancyRow].self, forKey: .snapshotDiscrepancies) ?? []
        self.automationRules = try container.decodeIfPresent([AutomationRule].self, forKey: .automationRules) ?? []
        self.fileImports = try container.decodeIfPresent([FileImportRecord].self, forKey: .fileImports) ?? []
        self.importBatches = try container.decodeIfPresent([ImportBatchRow].self, forKey: .importBatches) ?? []
        self.importMappings = try container.decodeIfPresent([ImportMappingRow].self, forKey: .importMappings) ?? []
        self.reports = try container.decodeIfPresent([ReportRow].self, forKey: .reports) ?? []
        self.schedules = try container.decodeIfPresent([Schedule].self, forKey: .schedules) ?? []
        self.scheduleOccurrences = try container.decodeIfPresent([ScheduleOccurrence].self, forKey: .scheduleOccurrences) ?? []
        self.scheduleReviews = try container.decodeIfPresent([ScheduleMatchReview].self, forKey: .scheduleReviews) ?? []
        self.rtaCategoryID = try container.decode(CategoryID.self, forKey: .rtaCategoryID)
        self.uncategorizedID = try container.decode(CategoryID.self, forKey: .uncategorizedID)
        self.systemPayees = try container.decode([SystemPayee].self, forKey: .systemPayees)
        self.creditCardPaymentsGroupID = try container.decodeIfPresent(CategoryGroupID.self, forKey: .creditCardPaymentsGroupID)
    }
}

extension BudgetWorkspace {
    public func snapshot() -> BudgetWorkspaceSnapshot {
        BudgetWorkspaceSnapshot(
            budget: budget,
            accounts: accounts.values.sorted { $0.id < $1.id },
            categoryGroups: categoryGroups.values.sorted { $0.id < $1.id },
            categories: categories.values.sorted { $0.id < $1.id },
            payees: payees.values.sorted { $0.id < $1.id },
            allocations: allocations.values.sorted { ($0.month, $0.categoryID) < ($1.month, $1.categoryID) },
            transactions: transactions.values.sorted { $0.id < $1.id },
            transferPairs: transferPairs.values.sorted { $0.id < $1.id },
            legSnapshots: legSnapshots.keys.sorted().compactMap { id in
                guard let rows = legSnapshots[id] else { return nil }
                return BudgetWorkspaceSnapshot.LegSnapshotGroup(pairID: id, rows: rows)
            },
            closedMonths: closedMonths.values.sorted { $0.month < $1.month },
            auditEvents: auditEvents,
            reconciliationMembership: reconciliationMembership.sorted(),
            reconciliations: reconciliations.keys.sorted().compactMap { id in
                guard let row = reconciliations[id] else { return nil }
                return BudgetWorkspaceSnapshot.ReconciliationGroup(
                    reconciliation: row,
                    members: reconciliationTransactions[id] ?? []
                )
            },
            simpleFINImports: simpleFINImports.values.sorted { $0.id < $1.id },
            syncConflicts: syncConflicts.values.sorted { $0.id < $1.id },
            snapshotDiscrepancies: snapshotDiscrepancies.values.sorted { $0.id < $1.id },
            automationRules: automationRules.values.sorted { ($0.sortOrder, $0.id) < ($1.sortOrder, $1.id) },
            fileImports: fileImports.values.sorted { $0.transactionID < $1.transactionID },
            importBatches: importBatches.values.sorted { $0.id < $1.id },
            importMappings: importMappings.values.sorted { $0.id < $1.id },
            reports: reports.values.sorted { ($0.sortOrder, $0.id) < ($1.sortOrder, $1.id) },
            schedules: schedules.values.sorted { $0.id < $1.id },
            scheduleOccurrences: scheduleOccurrences.values.sorted { ($0.scheduleID, $0.dueDate) < ($1.scheduleID, $1.dueDate) },
            scheduleReviews: scheduleReviews.values.sorted { $0.id < $1.id },
            rtaCategoryID: rtaCategoryID,
            uncategorizedID: uncategorizedID,
            systemPayees: systemPayeeIDs.keys.sorted { $0.rawValue < $1.rawValue }.compactMap {
                guard let id = systemPayeeIDs[$0] else { return nil }
                return BudgetWorkspaceSnapshot.SystemPayee(kind: $0, id: id)
            },
            creditCardPaymentsGroupID: creditCardPaymentsGroupID
        )
    }

    private static func uniqueDictionary<Key: Hashable, Value>(
        _ pairs: [(Key, Value)]
    ) throws -> [Key: Value] {
        var result: [Key: Value] = [:]
        result.reserveCapacity(pairs.count)
        for (key, value) in pairs {
            guard result.updateValue(value, forKey: key) == nil else {
                throw LedgerPersistenceError.invalidSnapshot
            }
        }
        return result
    }

    private static func validateSnapshotReferences(
        _ snapshot: BudgetWorkspaceSnapshot,
        accounts: [AccountID: AccountRow],
        categoryGroups: [CategoryGroupID: CategoryGroupRow],
        categories: [CategoryID: CategoryRow],
        payees: [PayeeID: PayeeRow],
        allocations: [AllocationKey: AllocationRow],
        transactions: [TransactionID: TransactionRow],
        transferPairs: [TransferPairID: TransferPairRow],
        legSnapshots: [TransferPairID: [TransferPairLegSnapshotRow]],
        closedMonths: [BudgetMonth: ClosedMonthRow],
        reconciliations: [ReconciliationID: ReconciliationRow],
        reconciliationTransactions: [ReconciliationID: [ReconciliationTransactionRow]],
        imports: [TransactionID: SimpleFINImportRecord],
        conflicts: [SyncConflictID: SyncConflictRow],
        discrepancies: [SnapshotDiscrepancyID: SnapshotDiscrepancyRow],
        systemPayees: [PayeeSystemKind: PayeeID]
    ) throws {
        let budgetID = snapshot.budget.id

        func require(_ condition: @autoclosure () -> Bool) throws {
            guard condition() else { throw LedgerPersistenceError.invalidSnapshot }
        }

        func requireBudget(_ rowBudgetID: BudgetID) throws {
            try require(rowBudgetID == budgetID)
        }

        func requireStageMetadata(_ metadata: StageMetadata?) throws {
            guard let metadata else { return }
            if let categoryID = metadata.proposedCategoryID {
                try require(categories[categoryID]?.budgetID == budgetID)
            }
            if let categoryID = metadata.originalCategoryID {
                try require(categories[categoryID]?.budgetID == budgetID)
            }
            if let transactionID = metadata.refundOfTransactionID {
                try require(transactions[transactionID]?.budgetID == budgetID)
            }
            if let pairID = metadata.transferPairID {
                try require(transferPairs[pairID]?.budgetID == budgetID)
            }
        }

        for row in accounts {
            try requireBudget(row.value.budgetID)
        }
        for row in categoryGroups {
            try requireBudget(row.value.budgetID)
        }
        for row in categories {
            let category = row.value
            try requireBudget(category.budgetID)
            try require(categoryGroups[category.groupID]?.budgetID == budgetID)
            if let accountID = category.linkedAccountID {
                try require(accounts[accountID]?.budgetID == budgetID)
            }
        }
        try require(categories[snapshot.rtaCategoryID]?.budgetID == budgetID)
        try require(categories[snapshot.uncategorizedID]?.budgetID == budgetID)
        if let groupID = snapshot.creditCardPaymentsGroupID {
            try require(categoryGroups[groupID]?.budgetID == budgetID)
        }
        for row in payees {
            let payee = row.value
            try requireBudget(payee.budgetID)
            if let categoryID = payee.lastUsedCategoryID {
                try require(categories[categoryID]?.budgetID == budgetID)
            }
        }
        for row in allocations {
            let allocation = row.value
            try requireBudget(allocation.budgetID)
            try require(categories[allocation.categoryID]?.budgetID == budgetID)
        }
        for row in closedMonths {
            try requireBudget(row.value.budgetID)
        }
        for audit in snapshot.auditEvents {
            try requireBudget(audit.budgetID)
        }

        for row in transactions {
            let transaction = row.value
            try requireBudget(transaction.budgetID)
            try require(accounts[transaction.accountID]?.budgetID == budgetID)
            if let payeeID = transaction.payeeID {
                try require(payees[payeeID]?.budgetID == budgetID)
            }
            if let categoryID = transaction.categoryID {
                try require(categories[categoryID]?.budgetID == budgetID)
            }
            if let pairID = transaction.transferPairID {
                try require(transferPairs[pairID]?.budgetID == budgetID)
            }
            if let refundID = transaction.refundOfTransactionID {
                try require(transactions[refundID]?.budgetID == budgetID)
            }
            if let splits = transaction.splits {
                try require(splits.count >= 2)
                for component in splits {
                    try require(categories[component.categoryID]?.budgetID == budgetID)
                }
            }
            try requireStageMetadata(transaction.stageMetadata)
        }

        for row in transferPairs {
            try requireBudget(row.value.budgetID)
        }
        for (pairID, rows) in legSnapshots {
            try require(transferPairs[pairID]?.budgetID == budgetID)
            for leg in rows {
                try require(leg.transferPairID == pairID)
                try require(transactions[leg.transactionID]?.budgetID == budgetID)
                if let payeeID = leg.payeeID {
                    try require(payees[payeeID]?.budgetID == budgetID)
                }
                if let categoryID = leg.categoryID {
                    try require(categories[categoryID]?.budgetID == budgetID)
                }
                try requireStageMetadata(leg.stageMetadata)
            }
        }

        var membershipIDs = Set<TransactionID>()
        for transactionID in snapshot.reconciliationMembership {
            try require(membershipIDs.insert(transactionID).inserted)
            try require(transactions[transactionID]?.budgetID == budgetID)
        }
        for (reconciliationID, row) in reconciliations {
            try requireBudget(row.budgetID)
            try require(accounts[row.accountID]?.budgetID == budgetID)
            if let adjustmentID = row.adjustmentTransactionID {
                if let adjustment = transactions[adjustmentID] {
                    try require(adjustment.budgetID == budgetID)
                } else {
                    try require(row.status == .undone)
                }
            }
            let members = reconciliationTransactions[reconciliationID] ?? []
            var memberIDs = Set<TransactionID>()
            for member in members {
                try require(member.reconciliationID == reconciliationID)
                try require(memberIDs.insert(member.transactionID).inserted)
                if let transaction = transactions[member.transactionID] {
                    try require(transaction.budgetID == budgetID)
                } else {
                    try require(row.status == .undone)
                }
            }
        }
        for reconciliationID in reconciliationTransactions.keys {
            try require(reconciliations[reconciliationID] != nil)
        }

        var importIDs = Set<SimpleFINImportID>()
        var importIdentities = Set<String>()
        for record in imports.values {
            try requireBudget(record.budgetID)
            try require(importIDs.insert(record.id).inserted)
            try require(transactions[record.transactionID]?.sourceKind == .simplefin)
            let identity = "\(record.connectionKey)\u{1F}\(record.remoteAccountID)\u{1F}\(record.remoteTransactionID)"
            try require(importIdentities.insert(identity).inserted)
        }
        for transaction in transactions.values {
            if transaction.sourceKind == .simplefin {
                try require(imports[transaction.id] != nil)
            }
        }

        var conflictImportIDs = Set<SimpleFINImportID>()
        for conflict in conflicts.values {
            try requireBudget(conflict.budgetID)
            if let transactionID = conflict.transactionID,
               let transaction = transactions[transactionID] {
                try require(transaction.budgetID == budgetID)
            }
            if let importID = conflict.simpleFINImportID {
                try require(imports.values.contains { $0.id == importID })
                try require(conflictImportIDs.insert(importID).inserted || conflict.eventKind == .remoteChanged)
            }
        }
        for discrepancy in discrepancies.values {
            try requireBudget(discrepancy.budgetID)
            try require(accounts[discrepancy.accountID]?.budgetID == budgetID)
            if let adjustmentID = discrepancy.adjustmentTransactionID {
                try require(transactions[adjustmentID]?.budgetID == budgetID)
            }
        }
        for payeeID in systemPayees.values {
            try require(payees[payeeID]?.budgetID == budgetID)
        }
    }

    public init(snapshot: BudgetWorkspaceSnapshot) throws {
        let accountRows = try Self.uniqueDictionary(snapshot.accounts.map { ($0.id, $0) })
        let categoryGroupRows = try Self.uniqueDictionary(snapshot.categoryGroups.map { ($0.id, $0) })
        let categoryRows = try Self.uniqueDictionary(snapshot.categories.map { ($0.id, $0) })
        let payeeRows = try Self.uniqueDictionary(snapshot.payees.map { ($0.id, $0) })
        let allocationRows = try Self.uniqueDictionary(snapshot.allocations.map {
            (AllocationKey(categoryID: $0.categoryID, month: $0.month), $0)
        })
        let transactionRows = try Self.uniqueDictionary(snapshot.transactions.map { ($0.id, $0) })
        let transferPairRows = try Self.uniqueDictionary(snapshot.transferPairs.map { ($0.id, $0) })
        let legSnapshotRows = try Self.uniqueDictionary(snapshot.legSnapshots.map { ($0.pairID, $0.rows) })
        let closedMonthRows = try Self.uniqueDictionary(snapshot.closedMonths.map { ($0.month, $0) })
        let reconciliationRows = try Self.uniqueDictionary(snapshot.reconciliations.map { ($0.reconciliation.id, $0.reconciliation) })
        let reconciliationMemberRows = try Self.uniqueDictionary(snapshot.reconciliations.map { ($0.reconciliation.id, $0.members) })
        let importRows = try Self.uniqueDictionary(snapshot.simpleFINImports.map { ($0.transactionID, $0) })
        let conflictRows = try Self.uniqueDictionary(snapshot.syncConflicts.map { ($0.id, $0) })
        let discrepancyRows = try Self.uniqueDictionary(snapshot.snapshotDiscrepancies.map { ($0.id, $0) })
        let ruleRows = try Self.uniqueDictionary(snapshot.automationRules.map { ($0.id, $0) })
        let fileImportRows = try Self.uniqueDictionary(snapshot.fileImports.map { ($0.transactionID, $0) })
        let batchRows = try Self.uniqueDictionary(snapshot.importBatches.map { ($0.id, $0) })
        let mappingRows = try Self.uniqueDictionary(snapshot.importMappings.map { ($0.id, $0) })
        for record in fileImportRows.values {
            guard record.budgetID == snapshot.budget.id,
                  transactionRows[record.transactionID]?.sourceKind == .file,
                  batchRows[record.batchID] != nil else { throw LedgerPersistenceError.invalidSnapshot }
        }
        for row in transactionRows.values where row.sourceKind == .file && fileImportRows[row.id] == nil {
            throw LedgerPersistenceError.invalidSnapshot
        }
        for batch in batchRows.values {
            guard batch.budgetID == snapshot.budget.id, accountRows[batch.accountID] != nil else {
                throw LedgerPersistenceError.invalidSnapshot
            }
        }
        for mapping in mappingRows.values where mapping.budgetID != snapshot.budget.id {
            throw LedgerPersistenceError.invalidSnapshot
        }
        let reportRows = try Self.uniqueDictionary(snapshot.reports.map { ($0.id, $0) })
        for report in reportRows.values where report.budgetID != snapshot.budget.id {
            throw LedgerPersistenceError.invalidSnapshot
        }
        let scheduleRows = try Self.uniqueDictionary(snapshot.schedules.map { ($0.id, $0) })
        for schedule in scheduleRows.values {
            guard schedule.budgetID == snapshot.budget.id, accountRows[schedule.accountID] != nil else {
                throw LedgerPersistenceError.invalidSnapshot
            }
            if let category = schedule.categoryID, categoryRows[category] == nil { throw LedgerPersistenceError.invalidSnapshot }
            if let target = schedule.transferToAccountID, accountRows[target] == nil { throw LedgerPersistenceError.invalidSnapshot }
        }
        let occurrenceRows = try Self.uniqueDictionary(snapshot.scheduleOccurrences.map { ($0.key, $0) })
        var occurrenceTransactionIDs = Set<TransactionID>()
        for occurrence in occurrenceRows.values {
            guard scheduleRows[occurrence.scheduleID] != nil else { throw LedgerPersistenceError.invalidSnapshot }
            if let transactionID = occurrence.transactionID {
                guard transactionRows[transactionID] != nil, occurrenceTransactionIDs.insert(transactionID).inserted else {
                    throw LedgerPersistenceError.invalidSnapshot
                }
            }
        }
        let reviewRows = try Self.uniqueDictionary(snapshot.scheduleReviews.map { ($0.id, $0) })
        for review in reviewRows.values {
            guard review.budgetID == snapshot.budget.id, scheduleRows[review.scheduleID] != nil else {
                throw LedgerPersistenceError.invalidSnapshot
            }
        }
        for rule in ruleRows.values {
            guard rule.budgetID == snapshot.budget.id else { throw LedgerPersistenceError.invalidSnapshot }
            for condition in rule.conditions {
                switch condition {
                case .account(let id):
                    guard accountRows[id] != nil else { throw LedgerPersistenceError.invalidSnapshot }
                case .category(let id?):
                    guard categoryRows[id] != nil else { throw LedgerPersistenceError.invalidSnapshot }
                default: break
                }
            }
            for action in rule.actions {
                switch action {
                case .setCategory(let id):
                    guard categoryRows[id] != nil else { throw LedgerPersistenceError.invalidSnapshot }
                case .split(let specs):
                    for spec in specs where categoryRows[spec.categoryID] == nil {
                        throw LedgerPersistenceError.invalidSnapshot
                    }
                default: break
                }
            }
        }
        let systemRows = try Self.uniqueDictionary(snapshot.systemPayees.map { ($0.kind, $0.id) })
        let requiredSystemKinds: [PayeeSystemKind] = [
            .openingBalance, .transfer, .reconciliationAdjustment, .cardDebtAdjustment, .unknown
        ]
        guard requiredSystemKinds.allSatisfy({ kind in
            guard let id = systemRows[kind], let payee = payeeRows[id] else { return false }
            return payee.namespace == .system && payee.systemKind == kind
        }) else {
            throw LedgerPersistenceError.invalidSnapshot
        }
        try Self.validateSnapshotReferences(
            snapshot,
            accounts: accountRows,
            categoryGroups: categoryGroupRows,
            categories: categoryRows,
            payees: payeeRows,
            allocations: allocationRows,
            transactions: transactionRows,
            transferPairs: transferPairRows,
            legSnapshots: legSnapshotRows,
            closedMonths: closedMonthRows,
            reconciliations: reconciliationRows,
            reconciliationTransactions: reconciliationMemberRows,
            imports: importRows,
            conflicts: conflictRows,
            discrepancies: discrepancyRows,
            systemPayees: systemRows
        )

        self.budget = snapshot.budget
        self.accounts = accountRows
        self.categoryGroups = categoryGroupRows
        self.categories = categoryRows
        self.payees = payeeRows
        self.allocations = allocationRows
        self.transactions = transactionRows
        self.transferPairs = transferPairRows
        self.legSnapshots = legSnapshotRows
        self.closedMonths = closedMonthRows
        self.auditEvents = snapshot.auditEvents
        self.reconciliationMembership = Set(snapshot.reconciliationMembership)
        self.reconciliations = reconciliationRows
        self.reconciliationTransactions = reconciliationMemberRows
        self.simpleFINImports = importRows
        self.syncConflicts = conflictRows
        self.snapshotDiscrepancies = discrepancyRows
        self.automationRules = ruleRows
        self.fileImports = fileImportRows
        self.importBatches = batchRows
        self.importMappings = mappingRows
        self.reports = reportRows
        self.schedules = scheduleRows
        self.scheduleOccurrences = occurrenceRows
        self.scheduleReviews = reviewRows
        self.rtaCategoryID = snapshot.rtaCategoryID
        self.uncategorizedID = snapshot.uncategorizedID
        self.systemPayeeIDs = systemRows
        self.creditCardPaymentsGroupID = snapshot.creditCardPaymentsGroupID
        self.calendar = try BudgetCalendar(timeZoneIdentifier: snapshot.budget.timeZoneIdentifier)
    }
}

import Foundation

/// Deterministic replay projection (§3). Pure value-in/value-out: the engine
/// never touches the database and production code never calls the test
/// `ReferenceModel`.
///
/// The engine performs one forward pass over logical events (standalone rows
/// and complete `TransferPair` events) in §3.2 replay order, classifying every
/// row (`posted` / `needsCategory` / `staged` + reason) and folding budget
/// events. The conservation oracle (§3.7) and the bucket identities (§3.5)
/// are asserted after every applied event and at each month boundary via
/// checked Int64 running totals; a mismatch throws a redacted
/// `IntegrityError`.
public enum ReplayEngine {

    // MARK: - Ordering

    /// Replay-order tuple: `(effective epoch, source_order_key, transaction
    /// id)`, with `transfer_pair_id` as the final tie-breaker for pair events.
    struct OrderTuple: Comparable, Sendable {
        var epoch: Int64
        var key: SourceOrderKey
        var transactionID: TransactionID
        var pairID: TransferPairID?

        static func < (l: OrderTuple, r: OrderTuple) -> Bool {
            if l.epoch != r.epoch { return l.epoch < r.epoch }
            if l.key != r.key { return l.key < r.key }
            if l.transactionID != r.transactionID { return l.transactionID < r.transactionID }
            switch (l.pairID, r.pairID) {
            case (nil, nil): return false
            case (nil, _): return true
            case (_, nil): return false
            case let (a?, b?): return a < b
            }
        }
    }

    enum EventBody: Sendable {
        case standalone(TransactionRow)
        case pair(TransferPairRow, TransactionRow, TransactionRow)
    }

    struct LogicalEvent: Sendable {
        var order: OrderTuple
        var month: BudgetMonth
        var body: EventBody
    }

    // MARK: - Running state

    struct SpendState {
        var budgeted: Milliunits = 0
        var activity: Milliunits = 0
        var available: Milliunits = 0
        var creditDebt: Milliunits = 0
    }

    struct PayState {
        var budgeted: Milliunits = 0
        var activity: Milliunits = 0
        var available: Milliunits = 0
    }

    struct State {
        var rtaStart: Milliunits = 0
        var rtaActivity: Milliunits = 0
        var assigned: Milliunits = 0
        var spend: [CategoryID: SpendState] = [:]
        var pay: [CategoryID: PayState] = [:]
        /// Month-scoped purchase lots per spending category, in replay order.
        var lots: [CategoryID: [PurchaseLot]] = [:]
        /// Cross-month index of posted credit-card purchases.
        var purchaseIndex: [TransactionID: PurchaseInfo] = [:]
        var projection: [AccountID: Milliunits] = [:]
        var register: [AccountID: Milliunits] = [:]
        // Checked running totals for the §3.7 oracle.
        var totalCashLike: Milliunits = 0
        var totalSpendAvailable: Milliunits = 0
        var totalPayAvailable: Milliunits = 0
        var totalCreditDebt: Milliunits = 0

        func rtaDisplayed() throws -> Milliunits {
            try subChecked(addChecked(rtaStart, rtaActivity), assigned)
        }
    }

    struct Context {
        var budget: BudgetRow
        var accounts: [AccountID: AccountRow]
        var categories: [CategoryID: CategoryRow]
        var calendar: BudgetCalendar
        var rtaCategoryID: CategoryID
        var uncategorizedID: CategoryID
        /// credit-card account → its cc_payment category
        var paymentCategoryByAccount: [AccountID: CategoryID]
        var closedMonths: Set<BudgetMonth>

        func isBudgetEligible(_ id: AccountID) -> Bool {
            guard let a = accounts[id] else { return false }
            return budgetEligible(a, budgetCurrency: budget.currency)
        }

        func isEligibleCashLike(_ id: AccountID) -> Bool {
            guard let a = accounts[id] else { return false }
            return a.type.isCashLike && budgetEligible(a, budgetCurrency: budget.currency)
        }

        func isEligibleCard(_ id: AccountID) -> Bool {
            guard let a = accounts[id] else { return false }
            return a.type == .creditCard && budgetEligible(a, budgetCurrency: budget.currency)
        }
    }

    // MARK: - Entry point

    public static func replay(
        _ input: ReplayInput,
        through requestedHorizon: BudgetMonth? = nil,
        startingAt checkpoint: MonthCheckpoint? = nil
    ) throws -> ProjectionResult {
        let ctx = try makeContext(input)
        let events = try buildLogicalEvents(input, ctx: ctx)

        // Horizon: everything with data plus the observed month.
        var horizon = input.budget.lastObservedBudgetMonth
        if let requested = requestedHorizon, requested > horizon { horizon = requested }
        if let lastEvent = events.last, lastEvent.month > horizon { horizon = lastEvent.month }
        for a in input.allocations where a.month > horizon { horizon = a.month }

        var state = State()
        var decisions: [TransactionID: PostingDecision] = [:]
        var startMonth = input.budget.firstMonth

        if let cp = checkpoint {
            guard cp.month >= input.budget.firstMonth, cp.month <= horizon else {
                throw IntegrityError(code: .invalidRowState, month: cp.month)
            }
            startMonth = cp.month
            state.rtaStart = cp.rtaStart
            for (id, v) in cp.spendingAvailable {
                state.spend[id] = SpendState(available: v)
            }
            for (id, v) in cp.paymentAvailable {
                state.pay[id] = PayState(available: v)
            }
            state.projection = cp.projectionBalances
            state.register = cp.registerBalances
            state.purchaseIndex = cp.purchaseIndex
            decisions = cp.postingDecisions
        }

        // Ensure every category has a state entry (deterministic totals).
        for (id, category) in input.categories {
            switch category.kind {
            case .spending:
                if state.spend[id] == nil { state.spend[id] = SpendState() }
            case .ccPayment:
                if state.pay[id] == nil { state.pay[id] = PayState() }
            case .inflow:
                break // RTA is a sentinel, never a stateful category.
            }
        }

        // Initialize running totals from the (possibly checkpoint-seeded) state.
        state.totalSpendAvailable = 0
        state.totalPayAvailable = 0
        state.totalCreditDebt = 0
        for id in state.spend.keys.sorted() {
            state.totalSpendAvailable = try addChecked(state.totalSpendAvailable, state.spend[id]!.available)
        }
        for id in state.pay.keys.sorted() {
            state.totalPayAvailable = try addChecked(state.totalPayAvailable, state.pay[id]!.available)
        }
        state.totalCashLike = 0
        for id in state.projection.keys.sorted() where ctx.isEligibleCashLike(id) {
            state.totalCashLike = try addChecked(state.totalCashLike, state.projection[id]!)
        }

        // Allocations grouped per month, deterministic order.
        var allocationsByMonth: [BudgetMonth: [AllocationRow]] = [:]
        for row in input.allocations {
            allocationsByMonth[row.month, default: []].append(row)
        }
        for (m, rows) in allocationsByMonth {
            allocationsByMonth[m] = rows.sorted { $0.categoryID < $1.categoryID }
        }

        var eventIndex = events.firstIndex { $0.month >= startMonth } ?? events.count
        // Defensive: events before the start month must already be covered by
        // the checkpoint's decisions.
        if eventIndex > 0 && checkpoint == nil {
            throw IntegrityError(code: .invalidRowState, month: events[0].month)
        }

        var months: [MonthSnapshot] = []
        var checkpoints: [BudgetMonth: MonthCheckpoint] = [:]

        var month = startMonth
        while month <= horizon {
            // -- Month start: capture checkpoint (state before allocations).
            checkpoints[month] = MonthCheckpoint(
                month: month,
                rtaStart: state.rtaStart,
                spendingAvailable: state.spend.mapValues(\.available),
                paymentAvailable: state.pay.mapValues(\.available),
                projectionBalances: state.projection,
                registerBalances: state.register,
                purchaseIndex: state.purchaseIndex,
                postingDecisions: decisions
            )

            // -- Apply the month's allocations at the month-start boundary.
            for alloc in allocationsByMonth[month] ?? [] {
                guard let category = ctx.categories[alloc.categoryID] else {
                    throw IntegrityError(code: .invalidReference, month: month)
                }
                switch category.kind {
                case .spending:
                    guard alloc.categoryID != ctx.uncategorizedID else {
                        throw IntegrityError(code: .invalidRowState, month: month)
                    }
                    var s = state.spend[alloc.categoryID] ?? SpendState()
                    s.budgeted = try addChecked(s.budgeted, alloc.budgetedMilliunits)
                    s.available = try addChecked(s.available, alloc.budgetedMilliunits)
                    state.spend[alloc.categoryID] = s
                    state.totalSpendAvailable = try addChecked(state.totalSpendAvailable, alloc.budgetedMilliunits)
                case .ccPayment:
                    var s = state.pay[alloc.categoryID] ?? PayState()
                    s.budgeted = try addChecked(s.budgeted, alloc.budgetedMilliunits)
                    s.available = try addChecked(s.available, alloc.budgetedMilliunits)
                    state.pay[alloc.categoryID] = s
                    state.totalPayAvailable = try addChecked(state.totalPayAvailable, alloc.budgetedMilliunits)
                case .inflow:
                    // RTA is a sentinel endpoint: no allocation row ever
                    // carries the RTA category id.
                    throw IntegrityError(code: .invalidRowState, month: month)
                }
                state.assigned = try addChecked(state.assigned, alloc.budgetedMilliunits)
            }
            try assertOracle(state, month: month)

            // -- Replay the month's logical events in order.
            while eventIndex < events.count, events[eventIndex].month == month {
                let event = events[eventIndex]
                eventIndex += 1
                try apply(event, month: month, state: &state, ctx: ctx, decisions: &decisions)
            }
            // Defensive ordering check: no event for an earlier month may remain.
            if eventIndex < events.count, events[eventIndex].month < month {
                throw IntegrityError(code: .invalidRowState, month: month)
            }

            // -- Month end: snapshot.
            var cashOverspend: Milliunits = 0
            var creditOverspend: Milliunits = 0
            var categorySnapshots: [CategoryID: CategoryMonthSnapshot] = [:]
            var paymentSnapshots: [CategoryID: PaymentMonthSnapshot] = [:]
            for id in state.spend.keys.sorted() {
                let s = state.spend[id]!
                let cashDebt = max(0, try subChecked(try negChecked(s.available), s.creditDebt))
                categorySnapshots[id] = CategoryMonthSnapshot(
                    budgeted: s.budgeted, activity: s.activity,
                    available: s.available, creditDebt: s.creditDebt, cashDebt: cashDebt
                )
                cashOverspend = try addChecked(cashOverspend, cashDebt)
                creditOverspend = try addChecked(creditOverspend, s.creditDebt)
            }
            for id in state.pay.keys.sorted() {
                let s = state.pay[id]!
                let paymentCashDebt = max(0, try negChecked(s.available))
                paymentSnapshots[id] = PaymentMonthSnapshot(
                    budgeted: s.budgeted, activity: s.activity, available: s.available,
                    paymentCashDebt: paymentCashDebt
                )
                cashOverspend = try addChecked(cashOverspend, paymentCashDebt)
            }
            let snapshot = MonthSnapshot(
                month: month,
                rtaStart: state.rtaStart,
                rtaActivity: state.rtaActivity,
                totalAssigned: state.assigned,
                rtaEnd: try state.rtaDisplayed(),
                categories: categorySnapshots,
                payments: paymentSnapshots,
                cashOverspendingAtEnd: cashOverspend,
                creditOverspendingAtEnd: creditOverspend
            )
            months.append(snapshot)

            // -- Boundary transition into the next month (§3.5.4).
            if month < horizon {
                state.rtaStart = try subChecked(snapshot.rtaEnd, cashOverspend)
                state.rtaActivity = 0
                state.assigned = 0
                for id in state.spend.keys.sorted() {
                    var s = state.spend[id]!
                    if s.available < 0 {
                        state.totalSpendAvailable = try subChecked(state.totalSpendAvailable, s.available)
                        s.available = 0
                    }
                    state.totalCreditDebt = try subChecked(state.totalCreditDebt, s.creditDebt)
                    s.creditDebt = 0
                    s.activity = 0
                    s.budgeted = 0
                    state.spend[id] = s
                }
                for id in state.pay.keys.sorted() {
                    var s = state.pay[id]!
                    if s.available < 0 {
                        state.totalPayAvailable = try subChecked(state.totalPayAvailable, s.available)
                        s.available = 0
                    }
                    s.activity = 0
                    s.budgeted = 0
                    state.pay[id] = s
                }
                state.lots = [:]
                try assertOracle(state, month: month.next)
            }
            month = month.next
        }

        return ProjectionResult(
            months: months,
            registerBalances: state.register,
            projectionBalances: state.projection,
            postingDecisions: decisions,
            checkpoints: checkpoints,
            horizon: horizon
        )
    }

    // MARK: - Context / event construction

    static func makeContext(_ input: ReplayInput) throws -> Context {
        let calendar = try BudgetCalendar(timeZoneIdentifier: input.budget.timeZoneIdentifier)
        var rta: CategoryID?
        var uncategorized: CategoryID?
        var paymentByAccount: [AccountID: CategoryID] = [:]
        for (id, c) in input.categories {
            if c.systemKind == .readyToAssign { rta = id }
            if c.systemKind == .uncategorized { uncategorized = id }
            if c.kind == .ccPayment {
                guard let linked = c.linkedAccountID else {
                    throw IntegrityError(code: .invalidReference)
                }
                guard paymentByAccount[linked] == nil else {
                    // one cc_payment category per credit-card account
                    throw IntegrityError(code: .invalidRowState)
                }
                paymentByAccount[linked] = id
            }
        }
        guard let rtaID = rta, let uncategorizedID = uncategorized else {
            throw IntegrityError(code: .invalidReference)
        }
        return Context(
            budget: input.budget,
            accounts: input.accounts,
            categories: input.categories,
            calendar: calendar,
            rtaCategoryID: rtaID,
            uncategorizedID: uncategorizedID,
            paymentCategoryByAccount: paymentByAccount,
            closedMonths: input.closedMonths
        )
    }

    static func buildLogicalEvents(_ input: ReplayInput, ctx: Context) throws -> [LogicalEvent] {
        var pairLegs: [TransferPairID: [TransactionRow]] = [:]
        var events: [LogicalEvent] = []

        func orderTuple(_ row: TransactionRow, pairID: TransferPairID?) throws -> OrderTuple {
            let epoch: Int64
            if let e = row.effectiveAtEpoch {
                epoch = e
            } else {
                epoch = try ctx.calendar.noonEpoch(of: row.date)
            }
            return OrderTuple(epoch: epoch, key: row.sourceOrderKey, transactionID: row.id, pairID: pairID)
        }

        for row in input.transactions {
            guard row.postingState != .voided else { continue }
            guard row.date.budgetMonth >= input.budget.firstMonth else {
                throw IntegrityError(code: .invalidRowState, month: row.date.budgetMonth)
            }
            if let pairID = row.transferPairID {
                guard let pair = input.transferPairs[pairID] else {
                    throw IntegrityError(code: .invalidReference, month: row.date.budgetMonth)
                }
                switch pair.status {
                case .complete:
                    pairLegs[pairID, default: []].append(row)
                    continue
                case .voided:
                    // A voided pair soft-voids both legs; a live leg is corrupt.
                    throw IntegrityError(code: .invalidRowState, month: row.date.budgetMonth)
                case .unpaired:
                    break // replay standalone; snapshots were restored on unpair
                }
            }
            events.append(LogicalEvent(
                order: try orderTuple(row, pairID: nil),
                month: row.date.budgetMonth,
                body: .standalone(row)
            ))
        }

        for (pairID, legs) in pairLegs {
            guard legs.count == 2, let pair = input.transferPairs[pairID] else {
                throw IntegrityError(code: .invalidRowState)
            }
            let a = legs[0], b = legs[1]
            guard a.date.budgetMonth == b.date.budgetMonth else {
                throw IntegrityError(code: .invalidRowState, month: a.date.budgetMonth)
            }
            let ta = try orderTuple(a, pairID: pairID)
            let tb = try orderTuple(b, pairID: pairID)
            let earlier = min(ta, tb)
            events.append(LogicalEvent(order: earlier, month: a.date.budgetMonth, body: .pair(pair, a, b)))
        }

        events.sort { $0.order < $1.order }
        return events
    }

    // MARK: - Event application

    static func apply(
        _ event: LogicalEvent,
        month: BudgetMonth,
        state: inout State,
        ctx: Context,
        decisions: inout [TransactionID: PostingDecision]
    ) throws {
        switch event.body {
        case .standalone(let row):
            let decision: PostingDecision
            if ctx.closedMonths.contains(month) {
                // Closed-month gate: never re-stage or reclassify existing rows.
                decision = PostingDecision(postingState: row.postingState, stageReason: row.stageReason)
            } else {
                decision = try classifyStandalone(row, month: month, state: state, ctx: ctx)
            }
            decisions[row.id] = decision
            try applyRegister(row, state: &state)
            if decision.postingState == .posted || decision.postingState == .needsCategory {
                try applyStandaloneEffects(row, month: month, state: &state, ctx: ctx)
                try assertOracle(state, month: month)
                try assertCardGuards(rows: [row], state: state, ctx: ctx, month: month)
            }

        case .pair(_, let a, let b):
            let legDecisions: [TransactionID: PostingDecision]
            if ctx.closedMonths.contains(month) {
                legDecisions = [
                    a.id: PostingDecision(postingState: a.postingState, stageReason: a.stageReason),
                    b.id: PostingDecision(postingState: b.postingState, stageReason: b.stageReason),
                ]
            } else {
                legDecisions = try classifyPair(a, b, state: state, ctx: ctx, month: month)
            }
            decisions[a.id] = legDecisions[a.id]
            decisions[b.id] = legDecisions[b.id]
            try applyRegister(a, state: &state)
            try applyRegister(b, state: &state)
            let posted = legDecisions.values.allSatisfy {
                $0.postingState == .posted || $0.postingState == .needsCategory
            }
            let anyPosted = legDecisions.values.contains {
                $0.postingState == .posted || $0.postingState == .needsCategory
            }
            // Transfer-pair atomicity: never replay one leg without the other.
            if anyPosted && !posted {
                throw IntegrityError(code: .invalidRowState, month: month)
            }
            if posted {
                try applyPairEffects(a, b, month: month, state: &state, ctx: ctx)
                try assertOracle(state, month: month)
                try assertCardGuards(rows: [a, b], state: state, ctx: ctx, month: month)
            }
        }
    }

    /// Register balance includes every non-voided physical row exactly once,
    /// whether posted, needsCategory, or staged.
    static func applyRegister(_ row: TransactionRow, state: inout State) throws {
        state.register[row.accountID] = try addChecked(state.register[row.accountID] ?? 0, row.amountMilliunits)
    }

    static func effectiveCategory(_ row: TransactionRow) -> CategoryID? {
        row.categoryID ?? row.stageMetadata?.proposedCategoryID
    }

    // MARK: Classification (standalone)

    static func classifyStandalone(
        _ row: TransactionRow,
        month: BudgetMonth,
        state: State,
        ctx: Context
    ) throws -> PostingDecision {
        guard let account = ctx.accounts[row.accountID] else {
            throw IntegrityError(code: .invalidReference, month: month)
        }
        let eligible = ctx.isBudgetEligible(row.accountID)
        let category = effectiveCategory(row)

        // Sticky reason: an unpaired leg without a standalone snapshot stays
        // staged until the user explicitly categorizes it (§3.8).
        if row.stageReason == .transferPairUnpairNeedsCategorization && category == nil {
            return PostingDecision(postingState: .staged, stageReason: .transferPairUnpairNeedsCategorization)
        }

        switch row.kind {
        case .openingBalance:
            if !eligible {
                guard category == nil else { throw IntegrityError(code: .invalidRowState, month: month) }
                return PostingDecision(postingState: .posted)
            }
            if account.type == .creditCard {
                guard row.amountMilliunits <= 0, category == nil else {
                    throw IntegrityError(code: .invalidRowState, month: month)
                }
                return PostingDecision(postingState: .posted)
            }
            guard row.amountMilliunits >= 0, category == ctx.rtaCategoryID else {
                throw IntegrityError(code: .invalidRowState, month: month)
            }
            return PostingDecision(postingState: .posted)

        case .adjustment:
            if !eligible {
                throw IntegrityError(code: .invalidRowState, month: month)
            }
            if account.type == .creditCard {
                guard category == nil else { throw IntegrityError(code: .invalidRowState, month: month) }
                let candidate = try addChecked(state.projection[row.accountID] ?? 0, row.amountMilliunits)
                if candidate > 0 {
                    return PostingDecision(postingState: .staged, stageReason: .cardBalanceWouldBecomePositive)
                }
                return PostingDecision(postingState: .posted)
            }
            guard account.type.isCashLike, category == ctx.rtaCategoryID else {
                throw IntegrityError(code: .invalidRowState, month: month)
            }
            return PostingDecision(postingState: .posted)

        case .refund:
            guard eligible, row.amountMilliunits > 0 else {
                throw IntegrityError(code: .invalidRowState, month: month)
            }
            if account.type == .creditCard {
                return try classifyCardRefund(row, month: month, state: state, ctx: ctx)
            }
            guard account.type.isCashLike else {
                throw IntegrityError(code: .invalidRowState, month: month)
            }
            // User-explicit cash reimbursement to a spending category.
            guard let cat = category, let categoryRow = ctx.categories[cat], categoryRow.kind == .spending else {
                throw IntegrityError(code: .invalidRowState, month: month)
            }
            if (state.spend[cat]?.creditDebt ?? 0) > 0 {
                return PostingDecision(postingState: .staged, stageReason: .cashInflowWithCreditDebt)
            }
            return PostingDecision(postingState: cat == ctx.uncategorizedID ? .needsCategory : .posted)

        case .normal:
            if !eligible {
                guard category == nil else { throw IntegrityError(code: .invalidRowState, month: month) }
                return PostingDecision(postingState: .posted)
            }
            if account.type == .creditCard {
                if row.amountMilliunits > 0 {
                    // Never silently routed to RTA (§3.5.3).
                    return PostingDecision(postingState: .staged, stageReason: .unlinkedCardInflow)
                }
                guard let cat = category, let categoryRow = ctx.categories[cat], categoryRow.kind == .spending else {
                    throw IntegrityError(code: .invalidRowState, month: month)
                }
                return PostingDecision(postingState: cat == ctx.uncategorizedID ? .needsCategory : .posted)
            }
            // Cash-like on-budget.
            if row.amountMilliunits > 0 {
                guard category == ctx.rtaCategoryID else {
                    throw IntegrityError(code: .invalidRowState, month: month)
                }
                return PostingDecision(postingState: .posted)
            }
            guard let cat = category, let categoryRow = ctx.categories[cat], categoryRow.kind == .spending else {
                throw IntegrityError(code: .invalidRowState, month: month)
            }
            return PostingDecision(postingState: cat == ctx.uncategorizedID ? .needsCategory : .posted)
        }
    }

    static func classifyCardRefund(
        _ row: TransactionRow,
        month: BudgetMonth,
        state: State,
        ctx: Context
    ) throws -> PostingDecision {
        let r = row.amountMilliunits
        let category = effectiveCategory(row)

        // Explicit cross-month refund-recovery resolution (§3.5.3): category
        // is RTA, payee is Card Debt Adjustment (validated by the mutation).
        if category == ctx.rtaCategoryID {
            let candidate = try addChecked(state.projection[row.accountID] ?? 0, r)
            if candidate > 0 {
                return PostingDecision(postingState: .staged, stageReason: .crossMonthRefund)
            }
            return PostingDecision(postingState: .posted)
        }

        guard let originID = row.refundOfTransactionID else {
            return PostingDecision(postingState: .staged, stageReason: .missingRefundOrigin)
        }
        guard let origin = state.purchaseIndex[originID] else {
            // Origin missing, voided, staged, later in replay order, or not a
            // posted card purchase.
            return PostingDecision(postingState: .staged, stageReason: .missingRefundOrigin)
        }
        guard origin.cardAccountID == row.accountID else {
            return PostingDecision(postingState: .staged, stageReason: .missingRefundOrigin)
        }
        guard origin.month == month else {
            return PostingDecision(postingState: .staged, stageReason: .crossMonthRefund)
        }
        // Materialized category copy must match the origin's current category.
        if let stored = category, stored != origin.categoryID {
            throw IntegrityError(code: .invalidRowState, month: month)
        }
        let lots = state.lots[origin.categoryID] ?? []
        guard let lot = lots.first(where: { $0.purchaseID == originID }) else {
            return PostingDecision(postingState: .staged, stageReason: .missingRefundOrigin)
        }
        if r > lot.remainingRefundable {
            return PostingDecision(postingState: .staged, stageReason: .overRefund)
        }
        let creditDebt = state.spend[origin.categoryID]?.creditDebt ?? 0
        let d = min(r, creditDebt)
        let f = try subChecked(r, d)
        var capacity: Milliunits = 0
        for l in lots { capacity = try addChecked(capacity, l.remainingFunded) }
        if f > capacity {
            return PostingDecision(postingState: .staged, stageReason: .overRefund)
        }
        let candidate = try addChecked(state.projection[row.accountID] ?? 0, r)
        if candidate > 0 {
            return PostingDecision(postingState: .staged, stageReason: .cardBalanceWouldBecomePositive)
        }
        return PostingDecision(postingState: .posted)
    }

    // MARK: Classification (pairs)

    static func classifyPair(
        _ a: TransactionRow,
        _ b: TransactionRow,
        state: State,
        ctx: Context,
        month: BudgetMonth
    ) throws -> [TransactionID: PostingDecision] {
        guard a.amountMilliunits != 0,
              a.amountMilliunits == (try negChecked(b.amountMilliunits)),
              a.accountID != b.accountID
        else {
            throw IntegrityError(code: .invalidRowState, month: month)
        }
        let source = a.amountMilliunits < 0 ? a : b
        let dest = a.amountMilliunits < 0 ? b : a

        guard let sourceAccount = ctx.accounts[source.accountID],
              let destAccount = ctx.accounts[dest.accountID]
        else { throw IntegrityError(code: .invalidReference, month: month) }

        let sourceEligible = ctx.isBudgetEligible(source.accountID)
        let destEligible = ctx.isBudgetEligible(dest.accountID)

        // v1 rejects card→cash, card→card, card→off-budget, off-budget→card.
        if sourceAccount.type == .creditCard && sourceEligible {
            throw IntegrityError(code: .invalidRowState, month: month)
        }
        if destAccount.type == .creditCard && destEligible && !(sourceEligible && sourceAccount.type.isCashLike) {
            throw IntegrityError(code: .invalidRowState, month: month)
        }

        func postedBoth() -> [TransactionID: PostingDecision] {
            [a.id: PostingDecision(postingState: .posted), b.id: PostingDecision(postingState: .posted)]
        }

        if destAccount.type == .creditCard && destEligible {
            // Cash → card payment (§3.6).
            let p = dest.amountMilliunits
            let candidate = try addChecked(state.projection[dest.accountID] ?? 0, p)
            if candidate > 0 {
                return [
                    dest.id: PostingDecision(postingState: .staged, stageReason: .cardBalanceWouldBecomePositive),
                    source.id: PostingDecision(postingState: .staged, stageReason: .transferPairCounterpartyStaged),
                ]
            }
            guard source.categoryID == nil, dest.categoryID == nil else {
                throw IntegrityError(code: .invalidRowState, month: month)
            }
            return postedBoth()
        }

        switch (sourceEligible, destEligible) {
        case (true, true):
            // on ↔ on (cash-like both): no envelope effect.
            guard source.categoryID == nil, dest.categoryID == nil else {
                throw IntegrityError(code: .invalidRowState, month: month)
            }
            return postedBoth()
        case (true, false):
            // on → off: on-budget leg categorized to a spending category.
            guard let cat = effectiveCategory(source),
                  let categoryRow = ctx.categories[cat], categoryRow.kind == .spending,
                  dest.categoryID == nil
            else { throw IntegrityError(code: .invalidRowState, month: month) }
            return postedBoth()
        case (false, true):
            // off → on: on-budget leg categorized to RTA.
            guard effectiveCategory(dest) == ctx.rtaCategoryID, source.categoryID == nil else {
                throw IntegrityError(code: .invalidRowState, month: month)
            }
            return postedBoth()
        case (false, false):
            // off ↔ off: register-only paired transfer.
            guard source.categoryID == nil, dest.categoryID == nil else {
                throw IntegrityError(code: .invalidRowState, month: month)
            }
            return postedBoth()
        }
    }

    // MARK: Effects (standalone)

    static func applyStandaloneEffects(
        _ row: TransactionRow,
        month: BudgetMonth,
        state: inout State,
        ctx: Context
    ) throws {
        guard let account = ctx.accounts[row.accountID] else {
            throw IntegrityError(code: .invalidReference, month: month)
        }
        try addToProjection(row.accountID, row.amountMilliunits, state: &state, ctx: ctx)
        let eligible = ctx.isBudgetEligible(row.accountID)
        guard eligible else { return } // off-budget: register/projection only
        let category = effectiveCategory(row)

        switch row.kind {
        case .openingBalance:
            if account.type == .creditCard { return } // pre-existing debt, no envelope
            try addRTAActivity(row.amountMilliunits, state: &state)

        case .adjustment:
            if account.type == .creditCard { return } // budget-neutral
            try addRTAActivity(row.amountMilliunits, state: &state)

        case .normal:
            if row.amountMilliunits > 0 {
                if account.type == .creditCard { return } // staged path only; never here
                try addRTAActivity(row.amountMilliunits, state: &state)
                return
            }
            guard let cat = category else { throw IntegrityError(code: .invalidRowState, month: month) }
            let x = try negChecked(row.amountMilliunits) // outflow magnitude >= 0
            if account.type == .creditCard {
                try applyCardSpending(row, category: cat, amount: x, month: month, state: &state, ctx: ctx)
            } else {
                try applyCashSpending(category: cat, amount: x, state: &state, month: month)
            }

        case .refund:
            guard let cat = category ?? state.purchaseIndex[row.refundOfTransactionID ?? row.id]?.categoryID else {
                throw IntegrityError(code: .invalidRowState, month: month)
            }
            if account.type == .creditCard {
                if cat == ctx.rtaCategoryID {
                    try applyCrossMonthRecovery(row, month: month, state: &state, ctx: ctx)
                } else {
                    try applyLinkedCardRefund(row, category: cat, month: month, state: &state, ctx: ctx)
                }
            } else {
                // Cash reimbursement: raises available; derived cashDebt falls
                // first; never consumes credit-card funded lots.
                var s = state.spend[cat] ?? SpendState()
                s.available = try addChecked(s.available, row.amountMilliunits)
                s.activity = try addChecked(s.activity, row.amountMilliunits)
                state.spend[cat] = s
                state.totalSpendAvailable = try addChecked(state.totalSpendAvailable, row.amountMilliunits)
                try assertBuckets(s, month: month)
            }
        }
    }

    static func applyCashSpending(
        category: CategoryID,
        amount x: Milliunits,
        state: inout State,
        month: BudgetMonth
    ) throws {
        var s = state.spend[category] ?? SpendState()
        s.available = try subChecked(s.available, x)
        s.activity = try subChecked(s.activity, x)
        state.spend[category] = s
        state.totalSpendAvailable = try subChecked(state.totalSpendAvailable, x)
        try assertBuckets(s, month: month)
    }

    static func applyCardSpending(
        _ row: TransactionRow,
        category: CategoryID,
        amount x: Milliunits,
        month: BudgetMonth,
        state: inout State,
        ctx: Context
    ) throws {
        guard let paymentCategory = ctx.paymentCategoryByAccount[row.accountID] else {
            throw IntegrityError(code: .invalidReference, month: month)
        }
        var s = state.spend[category] ?? SpendState()
        let fundedPortion = min(max(s.available, 0), x)
        let creditPortion = try subChecked(x, fundedPortion)
        s.available = try subChecked(s.available, x)
        s.activity = try subChecked(s.activity, x)
        s.creditDebt = try addChecked(s.creditDebt, creditPortion)
        state.spend[category] = s
        state.totalSpendAvailable = try subChecked(state.totalSpendAvailable, x)
        state.totalCreditDebt = try addChecked(state.totalCreditDebt, creditPortion)

        if fundedPortion != 0 {
            var p = state.pay[paymentCategory] ?? PayState()
            p.available = try addChecked(p.available, fundedPortion)
            p.activity = try addChecked(p.activity, fundedPortion)
            state.pay[paymentCategory] = p
            state.totalPayAvailable = try addChecked(state.totalPayAvailable, fundedPortion)
        }

        state.lots[category, default: []].append(PurchaseLot(
            purchaseID: row.id,
            cardAccountID: row.accountID,
            remainingRefundable: x,
            remainingFunded: fundedPortion
        ))
        state.purchaseIndex[row.id] = PurchaseInfo(month: month, categoryID: category, cardAccountID: row.accountID)
        try assertBuckets(s, month: month)
    }

    static func applyLinkedCardRefund(
        _ row: TransactionRow,
        category: CategoryID,
        month: BudgetMonth,
        state: inout State,
        ctx: Context
    ) throws {
        guard let originID = row.refundOfTransactionID else {
            throw IntegrityError(code: .invalidRowState, month: month)
        }
        let r = row.amountMilliunits
        var s = state.spend[category] ?? SpendState()
        let d = min(r, s.creditDebt)
        var f = try subChecked(r, d)

        s.creditDebt = try subChecked(s.creditDebt, d)
        state.totalCreditDebt = try subChecked(state.totalCreditDebt, d)

        // Consume the category's remaining funded lots across all purchases in
        // replay order; each consumed segment debits that segment's own card's
        // payment category (§3.5.3).
        var lots = state.lots[category] ?? []
        var i = 0
        while f > 0 && i < lots.count {
            let take = min(f, lots[i].remainingFunded)
            if take > 0 {
                lots[i].remainingFunded = try subChecked(lots[i].remainingFunded, take)
                guard let paymentCategory = ctx.paymentCategoryByAccount[lots[i].cardAccountID] else {
                    throw IntegrityError(code: .invalidReference, month: month)
                }
                var p = state.pay[paymentCategory] ?? PayState()
                p.available = try subChecked(p.available, take)
                p.activity = try subChecked(p.activity, take)
                state.pay[paymentCategory] = p
                state.totalPayAvailable = try subChecked(state.totalPayAvailable, take)
                f = try subChecked(f, take)
            }
            i += 1
        }
        guard f == 0 else { throw IntegrityError(code: .invalidRowState, month: month) }

        // Decrement the originating purchase's refundable lot by the full r.
        guard let originIdx = lots.firstIndex(where: { $0.purchaseID == originID }) else {
            throw IntegrityError(code: .invalidReference, month: month)
        }
        lots[originIdx].remainingRefundable = try subChecked(lots[originIdx].remainingRefundable, r)
        guard lots[originIdx].remainingRefundable >= 0 else {
            throw IntegrityError(code: .invalidRowState, month: month)
        }
        state.lots[category] = lots

        s.available = try addChecked(s.available, r)
        s.activity = try addChecked(s.activity, r)
        state.spend[category] = s
        state.totalSpendAvailable = try addChecked(state.totalSpendAvailable, r)
        try assertBuckets(s, month: month)
    }

    static func applyCrossMonthRecovery(
        _ row: TransactionRow,
        month: BudgetMonth,
        state: inout State,
        ctx: Context
    ) throws {
        guard let paymentCategory = ctx.paymentCategoryByAccount[row.accountID] else {
            throw IntegrityError(code: .invalidReference, month: month)
        }
        let r = row.amountMilliunits
        try addRTAActivity(r, state: &state)
        var p = state.pay[paymentCategory] ?? PayState()
        p.available = try subChecked(p.available, r)
        p.activity = try subChecked(p.activity, r)
        state.pay[paymentCategory] = p
        state.totalPayAvailable = try subChecked(state.totalPayAvailable, r)
    }

    // MARK: Effects (pairs)

    static func applyPairEffects(
        _ a: TransactionRow,
        _ b: TransactionRow,
        month: BudgetMonth,
        state: inout State,
        ctx: Context
    ) throws {
        let source = a.amountMilliunits < 0 ? a : b
        let dest = a.amountMilliunits < 0 ? b : a
        try addToProjection(source.accountID, source.amountMilliunits, state: &state, ctx: ctx)
        try addToProjection(dest.accountID, dest.amountMilliunits, state: &state, ctx: ctx)

        let sourceEligible = ctx.isBudgetEligible(source.accountID)
        let destEligible = ctx.isBudgetEligible(dest.accountID)
        guard let destAccount = ctx.accounts[dest.accountID] else {
            throw IntegrityError(code: .invalidReference, month: month)
        }

        if destAccount.type == .creditCard && destEligible {
            // Payment: one synthetic -p event to that card's payment category.
            guard let paymentCategory = ctx.paymentCategoryByAccount[dest.accountID] else {
                throw IntegrityError(code: .invalidReference, month: month)
            }
            let p = dest.amountMilliunits
            var pc = state.pay[paymentCategory] ?? PayState()
            pc.available = try subChecked(pc.available, p)
            pc.activity = try subChecked(pc.activity, p)
            state.pay[paymentCategory] = pc
            state.totalPayAvailable = try subChecked(state.totalPayAvailable, p)
            return
        }

        switch (sourceEligible, destEligible) {
        case (true, true), (false, false):
            return // no envelope effect
        case (true, false):
            guard let cat = effectiveCategory(source) else {
                throw IntegrityError(code: .invalidRowState, month: month)
            }
            let x = try negChecked(source.amountMilliunits)
            try applyCashSpending(category: cat, amount: x, state: &state, month: month)
        case (false, true):
            try addRTAActivity(dest.amountMilliunits, state: &state)
        }
    }

    // MARK: Shared effect helpers

    static func addToProjection(
        _ accountID: AccountID,
        _ amount: Milliunits,
        state: inout State,
        ctx: Context
    ) throws {
        state.projection[accountID] = try addChecked(state.projection[accountID] ?? 0, amount)
        if ctx.isEligibleCashLike(accountID) {
            state.totalCashLike = try addChecked(state.totalCashLike, amount)
        }
    }

    static func addRTAActivity(_ amount: Milliunits, state: inout State) throws {
        state.rtaActivity = try addChecked(state.rtaActivity, amount)
    }

    // MARK: Invariants

    /// §3.7 conservation oracle over checked running totals.
    static func assertOracle(_ state: State, month: BudgetMonth) throws {
        let rhs = try addChecked(
            try addChecked(
                try addChecked(state.rtaDisplayed(), state.totalSpendAvailable),
                state.totalPayAvailable
            ),
            state.totalCreditDebt
        )
        if state.totalCashLike != rhs {
            throw IntegrityError(code: .conservationOracleViolated, month: month)
        }
    }

    /// §3.5 bucket identity: `0 <= creditDebt <= max(0, -available)`; with the
    /// derived `cashDebt` this is exactly `negative available ==
    /// -(cashDebt + creditDebt)` when available is negative, and
    /// `cashDebt == creditDebt == 0` when available is non-negative.
    static func assertBuckets(_ s: SpendState, month: BudgetMonth) throws {
        let negAvailable = try negChecked(s.available)
        if s.creditDebt < 0 || s.creditDebt > max(0, negAvailable) {
            throw IntegrityError(code: .bucketIdentityViolated, month: month)
        }
    }

    /// v1 guarantee: every budget-eligible credit card participating in the
    /// projection keeps a normalized `projectionBalance <= 0`.
    static func assertCardGuards(
        rows: [TransactionRow],
        state: State,
        ctx: Context,
        month: BudgetMonth
    ) throws {
        for row in rows where ctx.isEligibleCard(row.accountID) {
            if (state.projection[row.accountID] ?? 0) > 0 {
                throw IntegrityError(code: .positiveCardProjection, month: month)
            }
        }
    }
}

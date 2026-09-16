import Foundation

/// A derived expected occurrence for lists and forecasts (never stored).
public struct ExpectedOccurrence: Sendable, Equatable, Identifiable {
    public var scheduleID: ScheduleID
    public var dueDate: BudgetDate
    public var accountID: AccountID
    public var amountMilliunits: Milliunits
    public var isOverdue: Bool
    public var id: String { "\(scheduleID.description)@\(dueDate.description)" }
}

public struct ScheduleMatchSummary: Sendable, Equatable {
    public var autoMatched: Int
    public var reviewsOpened: Int
}

extension BudgetWorkspace {

    // MARK: - CRUD (D5.1)

    func validateSchedule(_ schedule: Schedule) throws {
        guard !schedule.name.trimmingCharacters(in: .whitespaces).isEmpty,
              !schedule.payeeName.trimmingCharacters(in: .whitespaces).isEmpty,
              schedule.amountMilliunits != 0,
              schedule.amountToleranceMilliunits >= 0,
              schedule.dateWindowDays >= 0, schedule.dateWindowDays <= 30,
              schedule.budgetID == budget.id else { throw MutationError.scheduleInvalid }
        guard let account = accounts[schedule.accountID], !account.closed else { throw MutationError.accountNotFound }
        if let endDate = schedule.endDate, endDate < schedule.startDate { throw MutationError.scheduleInvalid }
        switch schedule.recurrence {
        case .daily(let n), .weekly(let n, _), .monthly(let n, _):
            guard n >= 1 else { throw MutationError.scheduleInvalid }
        default: break
        }
        if case let .weekly(_, weekday) = schedule.recurrence, !(1...7).contains(weekday) { throw MutationError.scheduleInvalid }
        if case let .monthly(_, .day(d)) = schedule.recurrence, !(1...31).contains(d) { throw MutationError.scheduleInvalid }
        if case let .yearly(m, d) = schedule.recurrence, !(1...12).contains(m) || !(1...31).contains(d) { throw MutationError.scheduleInvalid }
        if let destination = schedule.transferToAccountID {
            guard let target = accounts[destination], !target.closed, destination != schedule.accountID else {
                throw MutationError.scheduleInvalid
            }
            guard schedule.amountMilliunits < 0 else { throw MutationError.scheduleInvalid }
            let sourceEligible = budgetEligible(account, budgetCurrency: budget.currency)
            let targetEligible = budgetEligible(target, budgetCurrency: budget.currency)
            if sourceEligible && !targetEligible {
                guard let category = schedule.categoryID, categories[category]?.kind == .spending else {
                    throw MutationError.categoryRequired
                }
            } else {
                guard schedule.categoryID == nil else { throw MutationError.categoryNotAllowed }
            }
        } else {
            let eligible = budgetEligible(account, budgetCurrency: budget.currency)
            if eligible {
                if schedule.amountMilliunits > 0 {
                    guard schedule.categoryID == nil || schedule.categoryID == rtaCategoryID else { throw MutationError.categoryNotAllowed }
                } else if let category = schedule.categoryID {
                    guard let row = categories[category], row.kind == .spending, category != uncategorizedID else {
                        throw MutationError.categoryNotAllowed
                    }
                }
            } else {
                guard schedule.categoryID == nil else { throw MutationError.categoryNotAllowed }
            }
        }
    }

    @discardableResult
    public mutating func addSchedule(_ draft: Schedule, nowEpoch: Int64) throws -> ScheduleID {
        var schedule = draft
        schedule.budgetID = budget.id
        schedule.name = schedule.name.trimmingCharacters(in: .whitespaces)
        schedule.createdAtEpoch = nowEpoch
        schedule.updatedAtEpoch = nowEpoch
        try validateSchedule(schedule)
        var copy = self
        copy.setSchedule(schedule)
        copy.recordAudit(entityType: "schedule", entityID: schedule.id.description, eventKind: "scheduleCreated", nowEpoch: nowEpoch)
        try copy.bumpRevision()
        self = copy
        return schedule.id
    }

    /// Edits apply to future occurrences only; stored occurrences keep the
    /// transactions they point to (D5.2).
    public mutating func updateSchedule(_ updated: Schedule, nowEpoch: Int64) throws {
        guard let existing = schedules[updated.id] else { throw MutationError.entityNotFound }
        var schedule = updated
        schedule.budgetID = existing.budgetID
        schedule.createdAtEpoch = existing.createdAtEpoch
        schedule.updatedAtEpoch = nowEpoch
        schedule.name = schedule.name.trimmingCharacters(in: .whitespaces)
        try validateSchedule(schedule)
        var copy = self
        copy.setSchedule(schedule)
        copy.recordAudit(entityType: "schedule", entityID: schedule.id.description, eventKind: "scheduleUpdated", nowEpoch: nowEpoch)
        try copy.bumpRevision()
        self = copy
    }

    public mutating func setScheduleStatus(_ id: ScheduleID, status: ScheduleStatus, nowEpoch: Int64) throws {
        guard var schedule = schedules[id] else { throw MutationError.entityNotFound }
        guard schedule.status != status else { return }
        schedule.status = status
        schedule.updatedAtEpoch = nowEpoch
        var copy = self
        copy.setSchedule(schedule)
        for id in copy.scheduleReviews.keys.sorted() where copy.scheduleReviews[id]?.scheduleID == schedule.id && copy.scheduleReviews[id]?.status == .open && status != .active {
            var review = copy.scheduleReviews[id]!
            review.status = .dismissed
            review.resolvedAtEpoch = nowEpoch
            copy.setScheduleReview(review)
        }
        try copy.bumpRevision()
        self = copy
    }

    /// Deleting a schedule keeps every transaction it ever matched; only the
    /// expectation and its occurrence bookkeeping go away.
    public mutating func deleteSchedule(_ id: ScheduleID, nowEpoch: Int64) throws {
        guard schedules[id] != nil else { throw MutationError.entityNotFound }
        var copy = self
        copy.removeSchedule(id)
        for key in copy.scheduleOccurrences.keys where key.scheduleID == id { copy.removeScheduleOccurrence(key) }
        for reviewID in copy.scheduleReviews.keys.sorted() where copy.scheduleReviews[reviewID]?.scheduleID == id {
            copy.removeScheduleReview(reviewID)
        }
        copy.recordAudit(entityType: "schedule", entityID: id.description, eventKind: "scheduleDeleted", nowEpoch: nowEpoch)
        try copy.bumpRevision()
        self = copy
    }

    // MARK: - Occurrence decisions

    public mutating func skipOccurrence(scheduleID: ScheduleID, dueDate: BudgetDate, nowEpoch: Int64) throws {
        guard schedules[scheduleID] != nil else { throw MutationError.entityNotFound }
        let key = ScheduleOccurrenceKey(scheduleID: scheduleID, dueDate: dueDate)
        guard scheduleOccurrences[key] == nil else { throw MutationError.scheduleOccurrenceResolved }
        var copy = self
        copy.setScheduleOccurrence(ScheduleOccurrence(scheduleID: scheduleID, dueDate: dueDate, status: .skipped, transactionID: nil, resolvedAtEpoch: nowEpoch))
        copy.dismissOpenScheduleReviews(scheduleID: scheduleID, dueDate: dueDate, nowEpoch: nowEpoch)
        copy.recordAudit(entityType: "schedule", entityID: scheduleID.description, eventKind: "occurrenceSkipped", metadata: ["dueDate": dueDate.description], nowEpoch: nowEpoch)
        try copy.bumpRevision()
        self = copy
    }

    /// Explicit link of an existing row to an expected occurrence (from the
    /// Review Queue or the register). A row may serve one occurrence only.
    public mutating func matchOccurrence(scheduleID: ScheduleID, dueDate: BudgetDate, transactionID: TransactionID, nowEpoch: Int64) throws {
        guard let schedule = schedules[scheduleID] else { throw MutationError.entityNotFound }
        guard let row = transactions[transactionID], row.postingState != .voided, row.accountID == schedule.accountID else {
            throw MutationError.transactionNotFound
        }
        let key = ScheduleOccurrenceKey(scheduleID: scheduleID, dueDate: dueDate)
        guard scheduleOccurrences[key] == nil else { throw MutationError.scheduleOccurrenceResolved }
        guard !scheduleOccurrences.values.contains(where: { $0.transactionID == transactionID }) else {
            throw MutationError.scheduleOccurrenceResolved
        }
        var copy = self
        copy.setScheduleOccurrence(ScheduleOccurrence(scheduleID: scheduleID, dueDate: dueDate, status: .matched, transactionID: transactionID, resolvedAtEpoch: nowEpoch))
        copy.dismissOpenScheduleReviews(scheduleID: scheduleID, dueDate: dueDate, nowEpoch: nowEpoch)
        copy.recordAudit(entityType: "schedule", entityID: scheduleID.description, eventKind: "occurrenceMatched", metadata: ["dueDate": dueDate.description, "transaction": transactionID.description, "manual": "true"], nowEpoch: nowEpoch)
        try copy.bumpRevision()
        self = copy
    }

    /// Reverses a match or skip; an entered occurrence keeps its transaction
    /// (delete the transaction through the register if it was wrong).
    public mutating func unmatchOccurrence(scheduleID: ScheduleID, dueDate: BudgetDate, nowEpoch: Int64) throws {
        let key = ScheduleOccurrenceKey(scheduleID: scheduleID, dueDate: dueDate)
        guard let occurrence = scheduleOccurrences[key] else { throw MutationError.entityNotFound }
        var copy = self
        copy.removeScheduleOccurrence(key)
        copy.recordAudit(entityType: "schedule", entityID: scheduleID.description, eventKind: "occurrenceUnmatched", metadata: ["dueDate": dueDate.description, "previous": occurrence.status.rawValue], nowEpoch: nowEpoch)
        try copy.bumpRevision()
        self = copy
    }

    /// "Enter now": creates the manual transaction (or transfer pair) the
    /// schedule describes, dated `date`, and records an `entered` occurrence.
    /// Never automatic (D5.4).
    @discardableResult
    public mutating func enterOccurrence(scheduleID: ScheduleID, dueDate: BudgetDate, on date: BudgetDate? = nil, nowEpoch: Int64) throws -> TransactionID {
        guard let schedule = schedules[scheduleID] else { throw MutationError.entityNotFound }
        let key = ScheduleOccurrenceKey(scheduleID: scheduleID, dueDate: dueDate)
        guard scheduleOccurrences[key] == nil else { throw MutationError.scheduleOccurrenceResolved }
        let entryDate = date ?? dueDate
        var copy = self
        let transactionID: TransactionID
        if let destination = schedule.transferToAccountID {
            let pairID = try copy.createManualTransferPair(
                sourceAccountID: schedule.accountID, destinationAccountID: destination,
                amount: try negChecked(schedule.amountMilliunits), date: entryDate,
                onLegCategoryID: schedule.categoryID, nowEpoch: nowEpoch
            )
            guard let sourceLeg = copy.transactions.values.first(where: { $0.transferPairID == pairID && $0.accountID == schedule.accountID }) else {
                throw MutationError.transferPairNotFound
            }
            transactionID = sourceLeg.id
        } else {
            let category: CategoryID?
            if let account = copy.accounts[schedule.accountID], budgetEligible(account, budgetCurrency: budget.currency) {
                category = schedule.amountMilliunits > 0 ? rtaCategoryID : schedule.categoryID
            } else {
                category = nil
            }
            if let account = copy.accounts[schedule.accountID], budgetEligible(account, budgetCurrency: budget.currency),
               schedule.amountMilliunits < 0, category == nil {
                throw MutationError.categoryRequired
            }
            transactionID = try copy.addManualTransaction(
                accountID: schedule.accountID, date: entryDate, payeeName: schedule.payeeName,
                categoryID: category, amountMilliunits: schedule.amountMilliunits, memo: schedule.memo, nowEpoch: nowEpoch
            )
        }
        copy.setScheduleOccurrence(ScheduleOccurrence(scheduleID: scheduleID, dueDate: dueDate, status: .entered, transactionID: transactionID, resolvedAtEpoch: nowEpoch))
        copy.dismissOpenScheduleReviews(scheduleID: scheduleID, dueDate: dueDate, nowEpoch: nowEpoch)
        copy.recordAudit(entityType: "schedule", entityID: scheduleID.description, eventKind: "occurrenceEntered", metadata: ["dueDate": dueDate.description, "transaction": transactionID.description], nowEpoch: nowEpoch)
        try copy.bumpRevision()
        self = copy
        return transactionID
    }

    mutating func dismissOpenScheduleReviews(scheduleID: ScheduleID, dueDate: BudgetDate, nowEpoch: Int64) {
        for id in scheduleReviews.keys.sorted() {
            guard var review = scheduleReviews[id], review.status == .open,
                  review.scheduleID == scheduleID, review.dueDate == dueDate else { continue }
            review.status = .dismissed
            review.resolvedAtEpoch = nowEpoch
            setScheduleReview(review)
        }
    }

    public mutating func dismissScheduleReview(_ id: ScheduleReviewID, nowEpoch: Int64) throws {
        guard var review = scheduleReviews[id], review.status == .open else { throw MutationError.entityNotFound }
        review.status = .dismissed
        review.resolvedAtEpoch = nowEpoch
        var copy = self
        copy.setScheduleReview(review)
        try copy.bumpRevision()
        self = copy
    }

    // MARK: - Matching (D5.3)

    /// Transactions already serving an occurrence.
    var scheduledTransactionIDs: Set<TransactionID> {
        Set(scheduleOccurrences.values.compactMap(\.transactionID))
    }

    /// Runs the matcher for every active schedule over expected occurrences
    /// due up to `asOf` (plus the window). Unambiguous high scores link
    /// automatically; ties and medium scores open a review; nothing is ever
    /// created. Idempotent. Does not bump the revision by itself so it can
    /// run inside a larger mutation; standalone callers use
    /// `runScheduleMatching`.
    @discardableResult
    mutating func matchSchedules(asOf: BudgetDate, nowEpoch: Int64) -> ScheduleMatchSummary {
        var summary = ScheduleMatchSummary(autoMatched: 0, reviewsOpened: 0)
        guard !schedules.isEmpty else { return summary }
        var taken = scheduledTransactionIDs
        let horizon = RecurrenceEngine.adding(days: 30, to: asOf)
        for schedule in schedules.values.sorted(by: { ($0.name, $0.id) < ($1.name, $1.id) }) where schedule.status == .active {
            let resolved = Set(scheduleOccurrences.values.filter { $0.scheduleID == schedule.id }.map(\.dueDate))
            let expected = RecurrenceEngine.expectedDates(schedule, in: schedule.startDate...horizon, occurrences: resolved)
            let rows = transactions.values
                .filter { $0.accountID == schedule.accountID && $0.postingState != .voided && !taken.contains($0.id) }
                .sorted { ($0.date, $0.id) < ($1.date, $1.id) }
            for dueDate in expected {
                let window = RecurrenceEngine.adding(days: -schedule.dateWindowDays, to: dueDate)...RecurrenceEngine.adding(days: schedule.dateWindowDays, to: dueDate)
                // Only consider occurrences whose window has started.
                guard window.lowerBound <= asOf else { continue }
                let candidates: [ScheduleMatcher.Candidate] = rows.compactMap { row in
                    guard !taken.contains(row.id), window.contains(row.date),
                          let score = ScheduleMatcher.score(schedule: schedule, dueDate: dueDate, row: row,
                                                            payeeDisplayName: row.payeeID.flatMap { payees[$0]?.displayName })
                    else { return nil }
                    return ScheduleMatcher.Candidate(transactionID: row.id, score: score)
                }
                .sorted { ($0.score, $1.transactionID) > ($1.score, $0.transactionID) }
                guard let best = candidates.first else { continue }
                let tied = candidates.filter { $0.score == best.score }
                if schedule.autoMatch, best.score >= ScheduleMatcher.autoMatchThreshold, tied.count == 1 {
                    setScheduleOccurrence(ScheduleOccurrence(scheduleID: schedule.id, dueDate: dueDate, status: .matched,
                                                             transactionID: best.transactionID, resolvedAtEpoch: nowEpoch, matchScore: best.score))
                    taken.insert(best.transactionID)
                    dismissOpenScheduleReviews(scheduleID: schedule.id, dueDate: dueDate, nowEpoch: nowEpoch)
                    recordAudit(entityType: "schedule", entityID: schedule.id.description, eventKind: "occurrenceMatched",
                                metadata: ["dueDate": dueDate.description, "transaction": best.transactionID.description, "score": String(best.score)], nowEpoch: nowEpoch)
                    summary.autoMatched += 1
                } else if best.score >= ScheduleMatcher.reviewThreshold {
                    let candidateIDs = candidates.prefix(5).map(\.transactionID)
                    let alreadyOpen = scheduleReviews.values.contains {
                        $0.status == .open && $0.scheduleID == schedule.id && $0.dueDate == dueDate && $0.candidateTransactionIDs == candidateIDs
                    }
                    if !alreadyOpen {
                        for id in scheduleReviews.keys.sorted() where scheduleReviews[id]?.scheduleID == schedule.id && scheduleReviews[id]?.dueDate == dueDate && scheduleReviews[id]?.status == .open {
                            var stale = scheduleReviews[id]!
                            stale.status = .dismissed
                            stale.resolvedAtEpoch = nowEpoch
                            setScheduleReview(stale)
                        }
                        setScheduleReview(ScheduleMatchReview(budgetID: budget.id, scheduleID: schedule.id, dueDate: dueDate,
                                                              candidateTransactionIDs: candidateIDs, createdAtEpoch: nowEpoch))
                        summary.reviewsOpened += 1
                    }
                }
            }
        }
        return summary
    }

    /// Standalone matching pass (after sync, on demand).
    @discardableResult
    public mutating func runScheduleMatching(asOf: BudgetDate, nowEpoch: Int64) throws -> ScheduleMatchSummary {
        var copy = self
        let summary = copy.matchSchedules(asOf: asOf, nowEpoch: nowEpoch)
        if summary.autoMatched > 0 || summary.reviewsOpened > 0 {
            try copy.bumpRevision()
            self = copy
        }
        return summary
    }

    // MARK: - Queries and forecast (D5.5/D5.6)

    /// Expected occurrences in `range`, overdue when the window has fully
    /// passed relative to `asOf`.
    public func expectedOccurrences(in range: ClosedRange<BudgetDate>, asOf: BudgetDate) -> [ExpectedOccurrence] {
        var result: [ExpectedOccurrence] = []
        for schedule in schedules.values where schedule.status == .active {
            let resolved = Set(scheduleOccurrences.values.filter { $0.scheduleID == schedule.id }.map(\.dueDate))
            for dueDate in RecurrenceEngine.expectedDates(schedule, in: range, occurrences: resolved) {
                let windowEnd = RecurrenceEngine.adding(days: schedule.dateWindowDays, to: dueDate)
                result.append(ExpectedOccurrence(
                    scheduleID: schedule.id, dueDate: dueDate, accountID: schedule.accountID,
                    amountMilliunits: schedule.amountMilliunits, isOverdue: windowEnd < asOf
                ))
            }
        }
        return result.sorted { ($0.dueDate, $0.scheduleID) < ($1.dueDate, $1.scheduleID) }
    }

    /// The next expected due date for a schedule on or after `asOf`.
    public func nextDueDate(for scheduleID: ScheduleID, asOf: BudgetDate) -> BudgetDate? {
        guard let schedule = schedules[scheduleID] else { return nil }
        let resolved = Set(scheduleOccurrences.values.filter { $0.scheduleID == scheduleID }.map(\.dueDate))
        let horizon = RecurrenceEngine.adding(days: 800, to: asOf)
        return RecurrenceEngine.expectedDates(schedule, in: asOf...horizon, occurrences: resolved).first
    }

    /// Projected register balance: current register plus every unmatched
    /// expected amount due on or before `date` (transfers move money
    /// between the two accounts). Labeled a projection by every caller.
    public func projectedRegisterBalance(accountID: AccountID, through date: BudgetDate, asOf: BudgetDate, registerBalance: Milliunits) throws -> Milliunits {
        var balance = registerBalance
        let lower = RecurrenceEngine.adding(days: -1, to: min(asOf, date))
        for occurrence in expectedOccurrences(in: lower...max(date, asOf), asOf: asOf) where occurrence.dueDate <= date {
            guard let schedule = schedules[occurrence.scheduleID] else { continue }
            if schedule.accountID == accountID {
                balance = try addChecked(balance, occurrence.amountMilliunits)
            } else if schedule.transferToAccountID == accountID {
                balance = try subChecked(balance, occurrence.amountMilliunits)
            }
        }
        return balance
    }

    /// The schedule occurrence a transaction serves, if any.
    public func scheduleOccurrence(for transactionID: TransactionID) -> ScheduleOccurrence? {
        scheduleOccurrences.values.first { $0.transactionID == transactionID }
    }
}

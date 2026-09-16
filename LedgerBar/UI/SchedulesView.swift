import LedgerCore
import SwiftUI

/// Schedules (docs/DESIGN.md D5): expected events, what is overdue, what is
/// coming, and projected balances. Expected rows are never transactions;
/// "Enter" creates one explicitly.
struct SchedulesView: View {
    @Environment(AppModel.self) private var model
    @State private var editorTarget: ScheduleEditorTarget?
    @State private var deleteTarget: Schedule?

    private var today: BudgetDate? {
        guard let snapshot = model.snapshot,
              let calendar = try? BudgetCalendar(timeZoneIdentifier: snapshot.budget.timeZoneIdentifier) else { return nil }
        return calendar.budgetDate(fromEpoch: model.nowEpoch)
    }

    private var workspace: BudgetWorkspace? {
        model.snapshot.flatMap { try? BudgetWorkspace(snapshot: $0) }
    }

    private var schedules: [Schedule] {
        (model.snapshot?.schedules ?? []).sorted { ($0.status == .active ? 0 : 1, $0.name) < ($1.status == .active ? 0 : 1, $1.name) }
    }

    var body: some View {
        Group {
            if schedules.isEmpty {
                ContentUnavailableView {
                    Label("No schedules yet", systemImage: "calendar.badge.clock")
                } description: {
                    Text("Schedules describe expected money movements: rent, salary, subscriptions, card payments. Imports are matched to them; nothing is entered automatically.")
                } actions: {
                    Button("New Schedule…") { editorTarget = .new }.buttonStyle(.borderedProminent)
                }
            } else if let today, let workspace {
                content(today: today, workspace: workspace)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Schedules")
        .toolbar {
            ToolbarItemGroup {
                Button { editorTarget = .new } label: { Label("New Schedule", systemImage: "plus") }
                    .accessibilityIdentifier("ledgerbar.schedules.new")
                Button {
                    guard let today else { return }
                    let now = model.nowEpoch
                    Task {
                        let summary: ScheduleMatchSummary? = await model.perform { try $0.runScheduleMatching(asOf: today, nowEpoch: now) }
                        if let summary {
                            model.infoMessage = "Matched \(summary.autoMatched) occurrence(s); \(summary.reviewsOpened) need review."
                        }
                    }
                } label: { Label("Match Now", systemImage: "link") }
                .help("Re-run schedule matching over existing transactions.")
            }
        }
        .sheet(item: $editorTarget) { target in ScheduleEditorSheet(target: target) }
        .confirmationDialog("Delete schedule “\(deleteTarget?.name ?? "")”?",
                            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
                            titleVisibility: .visible) {
            Button("Delete Schedule", role: .destructive) {
                if let schedule = deleteTarget {
                    let now = model.nowEpoch
                    Task { await model.perform { try $0.deleteSchedule(schedule.id, nowEpoch: now) } }
                }
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Transactions that were matched or entered stay in the ledger; only the expectation is removed.")
        }
    }

    private func content(today: BudgetDate, workspace: BudgetWorkspace) -> some View {
        let horizon = RecurrenceEngine.adding(days: 30, to: today)
        let expected = workspace.expectedOccurrences(in: RecurrenceEngine.adding(days: -400, to: today)...horizon, asOf: today)
        let overdue = expected.filter(\.isOverdue)
        let upcoming = expected.filter { !$0.isOverdue }
        return List {
            if !overdue.isEmpty {
                Section("Overdue — no matching transaction yet") {
                    ForEach(overdue) { occurrence in occurrenceRow(occurrence, workspace: workspace) }
                }
            }
            Section("Next 30 days") {
                if upcoming.isEmpty {
                    Text("Nothing expected in the next 30 days.").foregroundStyle(.secondary)
                }
                ForEach(upcoming) { occurrence in occurrenceRow(occurrence, workspace: workspace) }
            }
            Section("Projected balances at \(horizon.description)") {
                ForEach((model.snapshot?.accounts ?? []).filter { !$0.closed }.sorted { $0.name < $1.name }, id: \.id) { account in
                    let register = model.projection?.registerBalances[account.id] ?? 0
                    let projected = (try? workspace.projectedRegisterBalance(accountID: account.id, through: horizon, asOf: today, registerBalance: register)) ?? register
                    HStack {
                        Text(account.name)
                        Spacer()
                        Text("now \(MoneyFormatting.string(register, currency: account.currency))").foregroundStyle(.secondary).font(.caption)
                        Text(MoneyFormatting.string(projected, currency: account.currency))
                            .monospacedDigit()
                            .foregroundStyle(projected < 0 ? .red : .primary)
                            .help("Projected: register balance plus expected, unmatched occurrences through \(horizon.description). Not a ledger value.")
                    }
                }
            }
            Section("All schedules") {
                ForEach(schedules) { schedule in
                    scheduleRow(schedule, workspace: workspace, today: today)
                        .contextMenu {
                            Button("Edit…") { editorTarget = .existing(schedule) }
                            if schedule.status == .active {
                                Button("Pause") { setStatus(schedule, .paused) }
                            } else if schedule.status == .paused {
                                Button("Resume") { setStatus(schedule, .active) }
                            }
                            if schedule.status != .ended {
                                Button("Mark Ended") { setStatus(schedule, .ended) }
                            }
                            Divider()
                            Button("Delete…", role: .destructive) { deleteTarget = schedule }
                        }
                }
            }
        }
    }

    private func occurrenceRow(_ occurrence: ExpectedOccurrence, workspace: BudgetWorkspace) -> some View {
        let schedule = workspace.schedules[occurrence.scheduleID]
        return HStack {
            Text(occurrence.dueDate.description).monospacedDigit().frame(width: 90, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(schedule?.name ?? "?")
                Text("\(schedule?.payeeName ?? "") · \(model.accountName(occurrence.accountID))").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(MoneyFormatting.string(occurrence.amountMilliunits, currency: model.budgetCurrency)).monospacedDigit()
            Button("Enter") { enter(occurrence) }.controlSize(.small)
                .help("Create this transaction now, dated on its due date.")
            Button("Skip") { skip(occurrence) }.controlSize(.small)
                .help("Skip this occurrence without creating anything.")
        }
    }

    private func scheduleRow(_ schedule: Schedule, workspace: BudgetWorkspace, today: BudgetDate) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(schedule.name).fontWeight(.medium)
                    if schedule.status != .active {
                        Text(schedule.status.rawValue.capitalized).font(.caption2).padding(.horizontal, 5).background(Capsule().fill(.quaternary))
                    }
                }
                Text("\(schedule.recurrence.summary) · \(schedule.payeeName) · \(model.accountName(schedule.accountID))" + (schedule.transferToAccountID.map { " → \(model.accountName($0))" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let next = workspace.nextDueDate(for: schedule.id, asOf: today) {
                Text("next \(next.description)").font(.caption).foregroundStyle(.secondary)
            }
            Text(MoneyFormatting.string(schedule.amountMilliunits, currency: model.budgetCurrency)).monospacedDigit()
        }
        .onTapGesture(count: 2) { editorTarget = .existing(schedule) }
    }

    private func setStatus(_ schedule: Schedule, _ status: ScheduleStatus) {
        let now = model.nowEpoch
        Task { await model.perform { try $0.setScheduleStatus(schedule.id, status: status, nowEpoch: now) } }
    }

    private func enter(_ occurrence: ExpectedOccurrence) {
        let now = model.nowEpoch
        Task {
            let id: TransactionID? = await model.perform { try $0.enterOccurrence(scheduleID: occurrence.scheduleID, dueDate: occurrence.dueDate, nowEpoch: now) }
            if id != nil { model.infoMessage = "Entered the expected transaction for \(occurrence.dueDate.description)." }
        }
    }

    private func skip(_ occurrence: ExpectedOccurrence) {
        let now = model.nowEpoch
        Task { await model.perform { try $0.skipOccurrence(scheduleID: occurrence.scheduleID, dueDate: occurrence.dueDate, nowEpoch: now) } }
    }
}

enum ScheduleEditorTarget: Identifiable {
    case new
    case existing(Schedule)
    var id: String {
        switch self {
        case .new: return "new"
        case .existing(let s): return s.id.description
        }
    }
}

struct ScheduleEditorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let target: ScheduleEditorTarget

    private enum Frequency: String, CaseIterable, Identifiable {
        case once = "Once", daily = "Daily", weekly = "Weekly", monthly = "Monthly", yearly = "Yearly"
        var id: String { rawValue }
    }

    @State private var name = ""
    @State private var accountID: AccountID?
    @State private var isTransfer = false
    @State private var transferToAccountID: AccountID?
    @State private var payee = ""
    @State private var categoryID: CategoryID?
    @State private var isInflow = false
    @State private var amountText = ""
    @State private var toleranceText = "0"
    @State private var frequency: Frequency = .monthly
    @State private var interval = 1
    @State private var weekday = 2
    @State private var monthDay = 1
    @State private var useLastDay = false
    @State private var yearMonth = 1
    @State private var startDate = Date()
    @State private var hasEndDate = false
    @State private var endDate = Date()
    @State private var windowDays = 4
    @State private var weekendPolicy: WeekendPolicy = .exact
    @State private var autoMatch = true
    @State private var memo = ""

    private var existing: Schedule? {
        if case .existing(let s) = target { return s }
        return nil
    }

    private var budgetTimeZone: TimeZone {
        TimeZone(identifier: model.snapshot?.budget.timeZoneIdentifier ?? "UTC") ?? .current
    }

    private var pickerCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = budgetTimeZone
        return calendar
    }

    private var openAccounts: [AccountRow] {
        (model.snapshot?.accounts ?? []).filter { !$0.closed }.sorted { $0.name < $1.name }
    }

    private var spendingCategories: [CategoryRow] {
        (model.snapshot?.categories ?? []).filter { $0.kind == .spending && !$0.hidden && $0.systemKind == nil }.sorted { $0.name < $1.name }
    }

    private var sourceOnBudget: Bool {
        guard let accountID, let account = openAccounts.first(where: { $0.id == accountID }) else { return false }
        return account.onBudget && account.currency == model.budgetCurrency
    }

    private var destinationOnBudget: Bool {
        guard let transferToAccountID, let account = openAccounts.first(where: { $0.id == transferToAccountID }) else { return false }
        return account.onBudget && account.currency == model.budgetCurrency
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(existing == nil ? "New Schedule" : "Edit Schedule").font(.title3.bold())
            Form {
                TextField("Name", text: $name)
                Picker("Account", selection: $accountID) {
                    ForEach(openAccounts, id: \.id) { Text($0.name).tag(Optional($0.id)) }
                }
                Toggle("Transfer to another account", isOn: $isTransfer)
                if isTransfer {
                    Picker("To account", selection: $transferToAccountID) {
                        Text("Choose…").tag(Optional<AccountID>.none)
                        ForEach(openAccounts.filter { $0.id != accountID }, id: \.id) { Text($0.name).tag(Optional($0.id)) }
                    }
                    if sourceOnBudget && !destinationOnBudget && transferToAccountID != nil {
                        Picker("Category (money leaving the plan)", selection: $categoryID) {
                            Text("Choose…").tag(Optional<CategoryID>.none)
                            ForEach(spendingCategories, id: \.id) { Text($0.name).tag(Optional($0.id)) }
                        }
                    }
                } else {
                    TextField("Payee", text: $payee)
                    Picker("Direction", selection: $isInflow) {
                        Text("Outflow").tag(false)
                        Text("Inflow").tag(true)
                    }
                    .pickerStyle(.segmented)
                    if sourceOnBudget && !isInflow {
                        Picker("Category", selection: $categoryID) {
                            Text("None yet").tag(Optional<CategoryID>.none)
                            ForEach(spendingCategories, id: \.id) { Text($0.name).tag(Optional($0.id)) }
                        }
                    }
                }
                TextField("Amount", text: $amountText)
                TextField("Amount may vary by up to", text: $toleranceText)
                    .help("0 means the amount must match exactly; otherwise imports within this much still match.")
                Section("Repeats") {
                    Picker("Frequency", selection: $frequency) {
                        ForEach(Frequency.allCases) { Text($0.rawValue).tag($0) }
                    }
                    switch frequency {
                    case .once: EmptyView()
                    case .daily:
                        Stepper("Every \(interval) day(s)", value: $interval, in: 1...365)
                    case .weekly:
                        Stepper("Every \(interval) week(s)", value: $interval, in: 1...52)
                        Picker("On", selection: $weekday) {
                            ForEach(1...7, id: \.self) { Text(RuleDescriptions.weekdayName($0)).tag($0) }
                        }
                    case .monthly:
                        Stepper("Every \(interval) month(s)", value: $interval, in: 1...24)
                        Toggle("Last day of the month", isOn: $useLastDay)
                        if !useLastDay { Stepper("On day \(monthDay)", value: $monthDay, in: 1...31) }
                    case .yearly:
                        Picker("Month", selection: $yearMonth) {
                            ForEach(1...12, id: \.self) { Text(ReportEngine.monthLabel(BudgetMonth(year: 2000, month: $0)!).prefix(3)).tag($0) }
                        }
                        Stepper("Day \(monthDay)", value: $monthDay, in: 1...31)
                    }
                    DatePicker("Starts", selection: $startDate, displayedComponents: .date)
                        .environment(\.calendar, pickerCalendar).environment(\.timeZone, budgetTimeZone)
                    Toggle("Ends", isOn: $hasEndDate)
                    if hasEndDate {
                        DatePicker("End date", selection: $endDate, displayedComponents: .date)
                            .environment(\.calendar, pickerCalendar).environment(\.timeZone, budgetTimeZone)
                    }
                    Picker("Weekends", selection: $weekendPolicy) {
                        Text("Exact date").tag(WeekendPolicy.exact)
                        Text("Previous business day").tag(WeekendPolicy.previousBusinessDay)
                        Text("Next business day").tag(WeekendPolicy.nextBusinessDay)
                    }
                }
                Section("Matching") {
                    Stepper("Match transactions within ±\(windowDays) day(s)", value: $windowDays, in: 0...30)
                    Toggle("Link unambiguous matches automatically", isOn: $autoMatch)
                    TextField("Memo for entered transactions", text: $memo)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(existing == nil ? "Create" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || amountText.isEmpty || accountID == nil || (!isTransfer && payee.trimmingCharacters(in: .whitespaces).isEmpty))
            }
        }
        .padding(20)
        .frame(width: 560, height: 640)
        .onAppear(perform: load)
    }

    private func load() {
        accountID = openAccounts.first?.id
        guard let schedule = existing else { return }
        name = schedule.name
        accountID = schedule.accountID
        isTransfer = schedule.transferToAccountID != nil
        transferToAccountID = schedule.transferToAccountID
        payee = schedule.payeeName
        categoryID = schedule.categoryID
        isInflow = schedule.amountMilliunits > 0
        amountText = MoneyFormatting.editableString(abs(schedule.amountMilliunits))
        toleranceText = MoneyFormatting.editableString(schedule.amountToleranceMilliunits)
        switch schedule.recurrence {
        case .once: frequency = .once
        case .daily(let n): frequency = .daily; interval = n
        case let .weekly(n, day): frequency = .weekly; interval = n; weekday = day
        case let .monthly(n, day):
            frequency = .monthly; interval = n
            switch day {
            case .lastDay: useLastDay = true
            case .day(let d): monthDay = d
            }
        case let .yearly(m, d): frequency = .yearly; yearMonth = m; monthDay = d
        }
        startDate = pickerCalendar.date(from: DateComponents(year: schedule.startDate.year, month: schedule.startDate.month, day: schedule.startDate.day)) ?? Date()
        if let end = schedule.endDate {
            hasEndDate = true
            endDate = pickerCalendar.date(from: DateComponents(year: end.year, month: end.month, day: end.day)) ?? Date()
        }
        windowDays = schedule.dateWindowDays
        weekendPolicy = schedule.weekendPolicy
        autoMatch = schedule.autoMatch
        memo = schedule.memo ?? ""
    }

    private func budgetDate(_ date: Date) -> BudgetDate? {
        let c = pickerCalendar.dateComponents([.year, .month, .day], from: date)
        guard let y = c.year, let m = c.month, let d = c.day else { return nil }
        return BudgetDate(year: y, month: m, day: d)
    }

    private func save() {
        guard let snapshot = model.snapshot, let accountID, let start = budgetDate(startDate) else { return }
        do {
            let magnitude = try MoneyFormatting.parse(amountText)
            let tolerance = try MoneyFormatting.parse(toleranceText.isEmpty ? "0" : toleranceText)
            let signed = (isTransfer || !isInflow) ? try negChecked(magnitude) : magnitude
            let recurrence: RecurrenceRule
            switch frequency {
            case .once: recurrence = .once
            case .daily: recurrence = .daily(every: interval)
            case .weekly: recurrence = .weekly(every: interval, weekday: weekday)
            case .monthly: recurrence = .monthly(every: interval, day: useLastDay ? .lastDay : .day(monthDay))
            case .yearly: recurrence = .yearly(month: yearMonth, day: monthDay)
            }
            let schedule = Schedule(
                id: existing?.id ?? ScheduleID(),
                budgetID: snapshot.budget.id,
                name: name,
                accountID: accountID,
                payeeName: isTransfer ? "Transfer" : payee,
                categoryID: (isTransfer && !(sourceOnBudget && !destinationOnBudget)) || (!isTransfer && (isInflow || !sourceOnBudget)) ? nil : categoryID,
                transferToAccountID: isTransfer ? transferToAccountID : nil,
                amountMilliunits: signed,
                amountToleranceMilliunits: tolerance,
                recurrence: recurrence,
                startDate: start,
                endDate: hasEndDate ? budgetDate(endDate) : nil,
                status: existing?.status ?? .active,
                dateWindowDays: windowDays,
                weekendPolicy: weekendPolicy,
                autoMatch: autoMatch,
                memo: memo.isEmpty ? nil : memo
            )
            let isExisting = existing != nil
            let now = model.nowEpoch
            Task {
                let done: Bool? = await model.perform { workspace in
                    if isExisting { try workspace.updateSchedule(schedule, nowEpoch: now) } else { _ = try workspace.addSchedule(schedule, nowEpoch: now) }
                    return true
                }
                if done != nil { dismiss() }
            }
        } catch {
            model.actionError = model.friendlyMessage(error)
        }
    }
}

/// Review Queue card for an ambiguous schedule match (D5.3).
struct ScheduleReviewCard: View {
    @Environment(AppModel.self) private var model
    let review: ScheduleMatchReview

    private var schedule: Schedule? { model.snapshot?.schedules.first { $0.id == review.scheduleID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label("\(schedule?.name ?? "Schedule") due \(review.dueDate.description)", systemImage: "calendar.badge.exclamationmark")
                    .font(.headline).foregroundStyle(.orange)
                Spacer()
                Text(MoneyFormatting.string(schedule?.amountMilliunits ?? 0, currency: model.budgetCurrency)).monospacedDigit()
            }
            Text("More than one transaction could be this expected event. Pick the one it is, or dismiss if none apply.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(review.candidateTransactionIDs, id: \.self) { id in
                if let row = model.snapshot?.transactions.first(where: { $0.id == id }) {
                    HStack {
                        Text(row.date.description).monospacedDigit()
                        Text(model.payeeName(row.payeeID))
                        Text(row.importedDescription ?? "").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(MoneyFormatting.string(row.amountMilliunits, currency: model.budgetCurrency)).monospacedDigit()
                        Button("This one") {
                            let now = model.nowEpoch
                            Task { await model.perform { try $0.matchOccurrence(scheduleID: review.scheduleID, dueDate: review.dueDate, transactionID: id, nowEpoch: now) } }
                        }
                        .controlSize(.small)
                    }
                }
            }
            HStack {
                Button("None of these") {
                    let now = model.nowEpoch
                    Task { await model.perform { try $0.dismissScheduleReview(review.id, nowEpoch: now) } }
                }
                .buttonStyle(.bordered)
                Button("Skip this occurrence") {
                    let now = model.nowEpoch
                    Task { await model.perform { try $0.skipOccurrence(scheduleID: review.scheduleID, dueDate: review.dueDate, nowEpoch: now) } }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }
}

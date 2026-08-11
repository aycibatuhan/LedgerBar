import LedgerCore
import SwiftUI

/// §5.2 budget grid: month navigation, RTA header, groups/categories with
/// Budgeted/Activity/Available, current-month assignment editing, and the
/// distinct `setBudgeted` / `moveMoney` primitives (§3.3) surfaced as
/// separately-labeled actions.
struct BudgetGridView: View {
    @Environment(AppModel.self) private var model
    @State private var viewedMonth: BudgetMonth?
    @State private var showMoveMoney = false

    private var current: BudgetMonth? { model.currentMonth }
    private var month: BudgetMonth? { viewedMonth ?? current }

    var body: some View {
        Group {
            if let snapshot = model.snapshot, let month, let current {
                content(snapshot: snapshot, month: month, current: current)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Budget")
    }

    @ViewBuilder
    private func content(snapshot: BudgetWorkspaceSnapshot, month: BudgetMonth, current: BudgetMonth) -> some View {
        let monthSnapshot = model.projection?.month(month)
        let isCurrent = month == current
        let isClosed = snapshot.closedMonths.contains { $0.month == month && $0.status == .closed }
        let isFuture = month > current
        let isPast = month < current

        VStack(spacing: 0) {
            header(month: month, current: current, snapshot: snapshot,
                   monthSnapshot: monthSnapshot, isCurrent: isCurrent,
                   isClosed: isClosed, isFuture: isFuture, isPast: isPast)
            Divider()
            grid(snapshot: snapshot, monthSnapshot: monthSnapshot, editable: isCurrent && !isClosed)
        }
        .sheet(isPresented: $showMoveMoney) {
            MoveMoneySheet(month: month)
        }
    }

    private func header(
        month: BudgetMonth,
        current: BudgetMonth,
        snapshot: BudgetWorkspaceSnapshot,
        monthSnapshot: MonthSnapshot?,
        isCurrent: Bool,
        isClosed: Bool,
        isFuture: Bool,
        isPast: Bool
    ) -> some View {
        let currency = snapshot.budget.currency
        return VStack(spacing: 8) {
            HStack {
                Button {
                    viewedMonth = month.previous
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(month <= snapshot.budget.firstMonth)
                .accessibilityLabel("Previous month")

                Text(MoneyFormatting.monthTitle(month))
                    .font(.title3.bold())
                    .frame(minWidth: 170)

                Button {
                    viewedMonth = month.next
                } label: {
                    Image(systemName: "chevron.right")
                }
                // One month beyond current is viewable, read-only (§5.2).
                .disabled(month >= current.next)
                .accessibilityLabel("Next month")

                if !isCurrent {
                    Button("Today") { viewedMonth = nil }
                        .controlSize(.small)
                }

                Spacer()

                if isCurrent {
                    Button("Move Money…") { showMoveMoney = true }
                        .help("Atomically reallocate between categories or Ready to Assign (§3.3 moveMoney). Direct assignment in the grid is setBudgeted and may over-assign.")
                }
                if isPast {
                    if isClosed {
                        Button("Reopen Month") {
                            Task {
                                await model.perform { try $0.reopenMonth(month, nowEpoch: Int64(Date().timeIntervalSince1970.rounded())) }
                            }
                        }
                    } else {
                        Button("Close Month") {
                            Task {
                                await model.perform { try $0.closeMonth(month, nowEpoch: Int64(Date().timeIntervalSince1970.rounded())) }
                            }
                        }
                    }
                }
            }

            HStack(spacing: 20) {
                if let monthSnapshot {
                    rtaBadge(monthSnapshot.rtaEnd, currency: currency)
                    metric("Assigned", monthSnapshot.totalAssigned, currency)
                    metric("Cash overspending", monthSnapshot.cashOverspendingAtEnd, currency)
                }
                Spacer()
                statusNote(isClosed: isClosed, isFuture: isFuture, isPast: isPast, monthSnapshot: monthSnapshot)
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private func statusNote(isClosed: Bool, isFuture: Bool, isPast: Bool, monthSnapshot: MonthSnapshot?) -> some View {
        if isClosed {
            Label("Closed — read-only until reopened", systemImage: "lock.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if isFuture {
            Label("Future months are read-only in v1", systemImage: "eye")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if isPast {
            let needsReview = (monthSnapshot?.cashOverspendingAtEnd ?? 0) > 0 || (monthSnapshot?.creditOverspendingAtEnd ?? 0) > 0
            Label(
                needsReview ? "Needs review — spending exceeded assignments" : "Past month — allocations read-only",
                systemImage: needsReview ? "exclamationmark.triangle" : "clock.arrow.circlepath"
            )
            .font(.caption)
            .foregroundStyle(needsReview ? .orange : .secondary)
        }
    }

    private func rtaBadge(_ amount: Milliunits, currency: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Ready to Assign").font(.caption).foregroundStyle(.secondary)
            Text(MoneyFormatting.string(amount, currency: currency))
                .font(.title3.bold())
                .foregroundStyle(amount < 0 ? Color.red : Color.green)
                .accessibilityLabel("Ready to assign \(MoneyFormatting.string(amount, currency: currency))\(amount < 0 ? ", over-assigned" : "")")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill((amount < 0 ? Color.red : Color.green).opacity(0.12)))
        .help(amount < 0 ? "Over-assigned: assignments exceed available money (allowed, shown in red)." : "Money available to assign this month.")
    }

    private func metric(_ title: String, _ amount: Milliunits, _ currency: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(MoneyFormatting.string(amount, currency: currency)).font(.callout.weight(.medium))
        }
    }

    private func grid(snapshot: BudgetWorkspaceSnapshot, monthSnapshot: MonthSnapshot?, editable: Bool) -> some View {
        let groups = snapshot.categoryGroups
            .filter { !$0.hidden }
            .sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) }
        return List {
            columnHeadings
            ForEach(groups, id: \.id) { group in
                let rows = categories(in: group, snapshot: snapshot)
                if !rows.isEmpty {
                    Section(group.name) {
                        ForEach(rows, id: \.id) { category in
                            CategoryGridRow(
                                category: category,
                                monthSnapshot: monthSnapshot,
                                currency: snapshot.budget.currency,
                                editable: editable && category.systemKind == nil
                            )
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private var columnHeadings: some View {
        HStack {
            Text("Category").frame(maxWidth: .infinity, alignment: .leading)
            Text("Budgeted").frame(width: 110, alignment: .trailing)
            Text("Activity").frame(width: 110, alignment: .trailing)
            Text("Available").frame(width: 110, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
    }

    private func categories(in group: CategoryGroupRow, snapshot: BudgetWorkspaceSnapshot) -> [CategoryRow] {
        snapshot.categories
            .filter { $0.groupID == group.id && !$0.hidden && $0.kind != .inflow }
            .sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) }
    }
}

private struct CategoryGridRow: View {
    @Environment(AppModel.self) private var model
    let category: CategoryRow
    let monthSnapshot: MonthSnapshot?
    let currency: String
    let editable: Bool

    @State private var editText = ""
    @FocusState private var focused: Bool

    private var values: (budgeted: Milliunits, activity: Milliunits, available: Milliunits, creditDebt: Milliunits) {
        if category.kind == .ccPayment {
            let payment = monthSnapshot?.payments[category.id]
            return (payment?.budgeted ?? 0, payment?.activity ?? 0, payment?.available ?? 0, 0)
        }
        let spending = monthSnapshot?.categories[category.id]
        return (spending?.budgeted ?? 0, spending?.activity ?? 0, spending?.available ?? 0, spending?.creditDebt ?? 0)
    }

    var body: some View {
        let v = values
        HStack {
            HStack(spacing: 6) {
                Text(category.name)
                if v.creditDebt > 0 {
                    Image(systemName: "creditcard.trianglebadge.exclamationmark")
                        .foregroundStyle(.orange)
                        .help("Credit overspending: \(MoneyFormatting.string(v.creditDebt, currency: currency)). It resets next month; the debt stays on the card.")
                        .accessibilityLabel("Credit overspending \(MoneyFormatting.string(v.creditDebt, currency: currency))")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if editable {
                TextField("0", text: $editText)
                    .focused($focused)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 110)
                    .textFieldStyle(.roundedBorder)
                    .onAppear { editText = MoneyFormatting.editableString(v.budgeted) }
                    .onChange(of: v.budgeted) { _, newValue in
                        if !focused { editText = MoneyFormatting.editableString(newValue) }
                    }
                    .onSubmit { commit() }
                    .accessibilityLabel("Budgeted for \(category.name)")
            } else {
                amountCell(v.budgeted)
            }
            amountCell(v.activity)
            amountCell(v.available, colorized: true)
        }
        .padding(.vertical, 1)
    }

    private func amountCell(_ amount: Milliunits, colorized: Bool = false) -> some View {
        Text(MoneyFormatting.string(amount, currency: currency))
            .frame(width: 110, alignment: .trailing)
            .foregroundStyle(colorized ? (amount < 0 ? Color.red : (amount > 0 ? Color.green : Color.secondary)) : Color.primary)
            .monospacedDigit()
    }

    private func commit() {
        guard let month = model.currentMonth else { return }
        do {
            let value = try MoneyFormatting.parse(editText.isEmpty ? "0" : editText)
            let categoryID = category.id
            Task {
                await model.perform { workspace in
                    try workspace.setBudgeted(categoryID: categoryID, month: month, value: value)
                }
            }
        } catch {
            model.actionError = model.friendlyMessage(error)
            editText = MoneyFormatting.editableString(values.budgeted)
        }
    }
}

/// §3.3 moveMoney with its three explicit forms; RTA is a sentinel endpoint.
struct MoveMoneySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let month: BudgetMonth

    private enum Endpoint: Hashable {
        case rta
        case category(CategoryID)
    }

    @State private var source: Endpoint = .rta
    @State private var destination: Endpoint = .rta
    @State private var amountText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Move Money").font(.title3.bold())
            Text("Moves are atomic: RTA → category requires available RTA; category → RTA and category → category are limited by the source's available. This is different from direct assignment, which may over-assign.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Form {
                Picker("From", selection: $source) {
                    Text("Ready to Assign").tag(Endpoint.rta)
                    ForEach(eligibleCategories, id: \.id) { category in
                        Text(label(for: category)).tag(Endpoint.category(category.id))
                    }
                }
                Picker("To", selection: $destination) {
                    Text("Ready to Assign").tag(Endpoint.rta)
                    ForEach(eligibleCategories, id: \.id) { category in
                        Text(label(for: category)).tag(Endpoint.category(category.id))
                    }
                }
                TextField("Amount", text: $amountText)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Move") { move() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(source == destination || amountText.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private var eligibleCategories: [CategoryRow] {
        (model.snapshot?.categories ?? [])
            .filter { !$0.hidden && $0.systemKind == nil && ($0.kind == .spending || $0.kind == .ccPayment) }
            .sorted { $0.name < $1.name }
    }

    private func label(for category: CategoryRow) -> String {
        let available: Milliunits
        if category.kind == .ccPayment {
            available = model.projection?.month(month)?.payments[category.id]?.available ?? 0
        } else {
            available = model.projection?.month(month)?.categories[category.id]?.available ?? 0
        }
        return "\(category.name) (\(MoneyFormatting.string(available, currency: model.budgetCurrency)))"
    }

    private func move() {
        do {
            let amount = try MoneyFormatting.parse(amountText)
            let from: MoveMoneyEndpoint = endpointValue(source)
            let to: MoveMoneyEndpoint = endpointValue(destination)
            let m = month
            let now = Int64(Date().timeIntervalSince1970.rounded())
            Task {
                let moved: Bool? = await model.perform { workspace in
                    try workspace.moveMoney(source: from, destination: to, amount: amount, month: m, nowEpoch: now)
                    return true
                }
                if moved != nil { dismiss() }
            }
        } catch {
            model.actionError = model.friendlyMessage(error)
        }
    }

    private func endpointValue(_ endpoint: Endpoint) -> MoveMoneyEndpoint {
        switch endpoint {
        case .rta: return .rta
        case .category(let id): return .category(id)
        }
    }
}

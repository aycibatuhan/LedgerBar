import AppKit
import LedgerCore
import SwiftUI
import UniformTypeIdentifiers

/// Sidebar header: the active budget and a menu to switch or manage (D8).
struct BudgetSwitcherMenu: View {
    @Environment(AppModel.self) private var model
    @Binding var showManage: Bool

    var body: some View {
        Menu {
            ForEach(model.budgets.filter { !$0.archived }) { budget in
                Button {
                    Task { await model.switchBudget(to: budget.id) }
                } label: {
                    if budget.id == model.snapshot?.budget.id {
                        Label(budget.name, systemImage: "checkmark")
                    } else {
                        Text(budget.name)
                    }
                }
            }
            Divider()
            Button("Manage Budgets…") { showManage = true }
        } label: {
            Label(model.snapshot?.budget.name ?? "Budget", systemImage: "folder")
        }
        .accessibilityLabel("Active budget: \(model.snapshot?.budget.name ?? "")")
        .accessibilityIdentifier("ledgerbar.budget-switcher")
    }
}

/// Create, rename, archive, export, import, and delete budgets. Every
/// budget is an independent data boundary; nothing here moves data between
/// budgets.
struct ManageBudgetsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var showNew = false
    @State private var renameTarget: BudgetSummary?
    @State private var deleteTarget: BudgetSummary?
    @State private var deleteConfirmation = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Budgets").font(.title3.bold())
            Text("Each budget has its own accounts, categories, transactions, rules, schedules, reports, and bank connection. Switching changes what every screen shows.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            List {
                ForEach(model.budgets) { budget in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(budget.name).fontWeight(budget.id == model.snapshot?.budget.id ? .semibold : .regular)
                                if budget.id == model.snapshot?.budget.id {
                                    Text("Active").font(.caption2).padding(.horizontal, 5).background(Capsule().fill(.green.opacity(0.2)))
                                }
                                if budget.archived {
                                    Text("Archived").font(.caption2).padding(.horizontal, 5).background(Capsule().fill(.quaternary))
                                }
                            }
                            Text("\(budget.currency) · from \(budget.firstMonth.description)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if budget.id != model.snapshot?.budget.id && !budget.archived {
                            Button("Switch") { Task { await model.switchBudget(to: budget.id) } }.controlSize(.small)
                        }
                        Menu {
                            Button("Rename…") { renameTarget = budget }
                            Button(budget.archived ? "Unarchive" : "Archive") { Task { await model.setBudgetArchived(budget.id, archived: !budget.archived) } }
                                .disabled(budget.id == model.snapshot?.budget.id && !budget.archived && model.budgets.filter { !$0.archived }.count == 1)
                            Button("Export…") { Task { await model.exportBudget(budget.id) } }
                            Divider()
                            Button("Delete…", role: .destructive) { deleteConfirmation = ""; deleteTarget = budget }
                                .disabled(budget.id == model.snapshot?.budget.id || model.budgets.count == 1)
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .frame(width: 30)
                    }
                    .padding(.vertical, 2)
                }
            }
            .frame(minHeight: 220)
            HStack {
                Button("New Budget…") { showNew = true }
                Button("Import Budget…") { Task { await model.importBudgetFromFile() } }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 460)
        .sheet(isPresented: $showNew) { NewBudgetSheet() }
        .sheet(item: $renameTarget) { budget in BudgetRenameSheet(budget: budget) }
        .alert("Delete “\(deleteTarget?.name ?? "")” permanently?", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })) {
            TextField("Type the budget name to confirm", text: $deleteConfirmation)
            Button("Delete Forever", role: .destructive) {
                if let target = deleteTarget, deleteConfirmation == target.name {
                    Task { await model.deleteBudget(target.id) }
                }
                deleteTarget = nil
            }
            .disabled(deleteConfirmation != deleteTarget?.name)
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("Every account, transaction, rule, schedule, and report in this budget is removed and cannot be recovered. Export it first if in doubt. A budget still connected to SimpleFIN must be disconnected before deletion.")
        }
    }
}

struct BudgetRenameSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let budget: BudgetSummary
    @State private var name: String

    init(budget: BudgetSummary) {
        self.budget = budget
        _name = State(initialValue: budget.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Budget").font(.title3.bold())
            Form { TextField("Name", text: $name) }.formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Rename") {
                    let newName = name
                    Task {
                        await model.renameBudget(budget.id, to: newName)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

/// Creates an additional budget with the same immutable choices as first-run
/// onboarding (currency, time zone, first month), plus a name.
struct NewBudgetSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var currency = Locale.current.currency?.identifier ?? "USD"
    @State private var timeZoneID = TimeZone.current.identifier
    @State private var firstMonthOffset = 0

    private var currentMonthInZone: BudgetMonth? {
        guard let calendar = try? BudgetCalendar(timeZoneIdentifier: timeZoneID) else { return nil }
        return calendar.budgetDate(fromEpoch: model.nowEpoch)?.budgetMonth
    }

    private var firstMonthChoices: [(offset: Int, month: BudgetMonth)] {
        guard var month = currentMonthInZone else { return [] }
        var result: [(Int, BudgetMonth)] = []
        for offset in 0...12 { result.append((offset, month)); month = month.previous }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Budget").font(.title3.bold())
            Text("Currency, time zone, and first month are fixed once the budget is created. The new budget becomes active.")
                .font(.caption).foregroundStyle(.secondary)
            Form {
                TextField("Name", text: $name)
                TextField("Currency (ISO 4217)", text: $currency)
                    .onChange(of: currency) { _, value in currency = String(value.uppercased().prefix(3)) }
                Picker("Time zone", selection: $timeZoneID) {
                    ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) { Text($0).tag($0) }
                }
                Picker("First budget month", selection: $firstMonthOffset) {
                    ForEach(firstMonthChoices, id: \.offset) { choice in
                        Text(MoneyFormatting.monthTitle(choice.month)).tag(choice.offset)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") {
                    guard let choice = firstMonthChoices.first(where: { $0.offset == firstMonthOffset }) else { return }
                    let budgetName = name
                    let selectedCurrency = currency
                    let zone = timeZoneID
                    Task {
                        await model.createBudget(name: budgetName, currency: selectedCurrency, timeZoneIdentifier: zone, firstMonth: choice.month)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || currency.count != 3 || firstMonthChoices.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

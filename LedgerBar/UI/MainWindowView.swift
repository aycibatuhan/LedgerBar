import LedgerCore
import SwiftUI

enum SidebarItem: Hashable {
    case budget
    case review
    case rules
    case reports
    case schedules
    case assistant
    case allAccounts
    case account(AccountID)
}

/// §5.2 full window: NavigationSplitView with the budget grid, an accounts
/// sidebar showing register balances and needs-attention counts, and the
/// per-account register.
struct MainWindowView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: SidebarItem? = .budget
    @State private var showAddAccount = false
    @State private var renameAccountTarget: AccountRow?
    @State private var closeAccountTarget: AccountRow?
    @State private var deleteAccountTarget: AccountRow?
    @State private var deleteAccountConfirmation = ""
    @State private var voidCloseTarget: AccountRow?
    @State private var showManageBudgets = false
    @AppStorage("ledgerbar.showClosedAccounts") private var showClosedAccounts = false

    var body: some View {
        @Bindable var model = model
        Group {
            switch model.phase {
            case .loading:
                ProgressView("Loading budget…")
            case .failed(let message):
                ContentUnavailableView(
                    "LedgerBar could not start",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
            case .onboarding:
                OnboardingView()
            case .ready:
                split
            }
        }
        .alert("Something went wrong", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.actionError ?? "")
        }
        .alert("Done", isPresented: infoBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.infoMessage ?? "")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.actionError != nil },
            set: { if !$0 { model.actionError = nil } }
        )
    }

    private var infoBinding: Binding<Bool> {
        Binding(
            get: { model.infoMessage != nil },
            set: { if !$0 { model.infoMessage = nil } }
        )
    }

    private var split: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    BudgetSwitcherMenu(showManage: $showManageBudgets)
                        .menuStyle(.borderlessButton)
                }
                Section {
                    Label("Budget", systemImage: "chart.pie")
                        .tag(SidebarItem.budget)
                    Label("Review Queue", systemImage: "checklist")
                        .badge(model.openReviewCount)
                        .tag(SidebarItem.review)
                    Label("All Accounts", systemImage: "list.bullet.rectangle")
                        .badge(model.needsCategoryCount + model.stagedCount)
                        .tag(SidebarItem.allAccounts)
                }
                Section("Insights") {
                    Label("Reports", systemImage: "chart.bar.xaxis")
                        .tag(SidebarItem.reports)
                    Label("Schedules", systemImage: "calendar.badge.clock")
                        .badge(model.overdueScheduleCount)
                        .tag(SidebarItem.schedules)
                    Label("Ask LedgerBar", systemImage: "sparkles")
                        .tag(SidebarItem.assistant)
                }
                Section("Automation") {
                    Label("Rules", systemImage: "wand.and.stars")
                        .badge(model.snapshot?.automationRules.count ?? 0)
                        .tag(SidebarItem.rules)
                }
                Section("Accounts") {
                    ForEach(sortedAccounts, id: \.id) { account in
                        accountRow(account)
                            .tag(SidebarItem.account(account.id))
                            .contextMenu { accountMenu(for: account) }
                    }
                    if closedAccountCount > 0 {
                        Button {
                            showClosedAccounts.toggle()
                        } label: {
                            Label(
                                showClosedAccounts
                                    ? "Hide Closed Accounts"
                                    : "Show \(closedAccountCount) Closed Account\(closedAccountCount == 1 ? "" : "s")",
                                systemImage: showClosedAccounts ? "eye.slash" : "lock"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("ledgerbar.toggle-closed-accounts")
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 230, ideal: 260)
            .toolbar {
                ToolbarItem {
                    Button {
                        showAddAccount = true
                    } label: {
                        Label("Add Account", systemImage: "plus")
                    }
                    .accessibilityLabel("Add Account")
                    .accessibilityIdentifier("ledgerbar.add-account")
                }
                ToolbarItem {
                    Menu {
                        Toggle("Show Closed Accounts", isOn: $showClosedAccounts)
                    } label: {
                        Label("Account Options", systemImage: "ellipsis.circle")
                    }
                    .accessibilityLabel("Account Options")
                    .accessibilityIdentifier("ledgerbar.account-options")
                }
            }
        } detail: {
            switch selection {
            case .budget, .none:
                BudgetGridView()
            case .review:
                ReviewQueueView()
            case .rules:
                RulesView()
            case .reports:
                ReportsView()
            case .schedules:
                SchedulesView()
            case .assistant:
                AssistantView()
            case .allAccounts:
                RegisterView(accountID: nil)
            case .account(let id):
                RegisterView(accountID: id)
            }
        }
        .sheet(isPresented: $showAddAccount) {
            AddAccountSheet()
        }
        .sheet(isPresented: $showManageBudgets) {
            ManageBudgetsSheet()
        }
        .onChange(of: model.assistantPrefill) { _, prefill in
            if prefill != nil { selection = .assistant }
        }
        .sheet(item: $renameAccountTarget) { account in
            RenameAccountSheet(account: account)
        }
        .confirmationDialog(
            "Close \(closeAccountTarget?.name ?? "this account")?",
            isPresented: closeDialogBinding,
            titleVisibility: .visible,
            presenting: closeAccountTarget
        ) { account in
            Button("Close Account") { closeAccount(account) }
            Button("Void History and Close…", role: .destructive) { voidCloseTarget = account }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Close keeps every transaction and only stops the account from participating in the budget; it works when the register balance is zero and nothing is staged or waiting for a category. Void History and Close is for a duplicate or mistaken account: it voids all of its transactions first.")
        }
        .alert(
            "Delete “\(deleteAccountTarget?.name ?? "")” permanently?",
            isPresented: Binding(
                get: { deleteAccountTarget != nil },
                set: { if !$0 { deleteAccountTarget = nil } }
            )
        ) {
            TextField("Type the account name to confirm", text: $deleteAccountConfirmation)
            Button("Delete Forever", role: .destructive) {
                if let target = deleteAccountTarget, deleteAccountConfirmation == target.name {
                    let id = target.id
                    Task {
                        if await model.deleteClosedAccount(id), selection == .account(id) {
                            selection = .allAccounts
                        }
                    }
                }
                deleteAccountTarget = nil
            }
            .disabled(deleteAccountConfirmation != deleteAccountTarget?.name)
            Button("Cancel", role: .cancel) { deleteAccountTarget = nil }
        } message: {
            Text(deleteAccountMessage(deleteAccountTarget))
        }
        .confirmationDialog(
            "Void all history of \(voidCloseTarget?.name ?? "this account") and close it?",
            isPresented: voidCloseDialogBinding,
            titleVisibility: .visible,
            presenting: voidCloseTarget
        ) { account in
            Button("Void \(liveRowCount(account)) Transactions and Close", role: .destructive) {
                voidHistoryAndClose(account)
            }
            Button("Cancel", role: .cancel) {}
        } message: { account in
            Text(voidCloseMessage(account))
        }
    }

    private var closeDialogBinding: Binding<Bool> {
        Binding(
            get: { closeAccountTarget != nil },
            set: { if !$0 { closeAccountTarget = nil } }
        )
    }

    private var voidCloseDialogBinding: Binding<Bool> {
        Binding(
            get: { voidCloseTarget != nil },
            set: { if !$0 { voidCloseTarget = nil } }
        )
    }

    private func deleteAccountMessage(_ account: AccountRow?) -> String {
        guard let account else { return "" }
        let rows = (model.snapshot?.transactions ?? []).filter { $0.accountID == account.id }.count
        var text = "The account and all \(rows) of its transactions are removed for good, along with its import history, review items, reconciliations, and schedules."
        if liveRowCount(account) > 0 {
            text += " Some of those transactions still count in past months, so those months will change."
        }
        text += " Rules that only apply to this account are removed. A link to SimpleFIN for it is removed too; linking the bank account again later imports its history fresh. This cannot be undone."
        return text
    }

    private func liveRowCount(_ account: AccountRow) -> Int {
        (model.snapshot?.transactions ?? []).filter {
            $0.accountID == account.id && $0.postingState != .voided
        }.count
    }

    private func voidCloseMessage(_ account: AccountRow) -> String {
        let balance = model.projection?.registerBalances[account.id] ?? 0
        let imported = (model.snapshot?.transactions ?? []).filter {
            $0.accountID == account.id && $0.postingState != .voided && $0.sourceKind == .simplefin
        }.count
        return "Register balance \(MoneyFormatting.string(balance, currency: account.currency)). "
            + "\(imported) imported transactions are voided and keep their import identity so a later sync cannot bring them back; "
            + "the rest, including the opening balance, are removed. Money the account contributed to Ready to Assign disappears with it. "
            + "Transfers must be unpaired first, and a closed month blocks this."
    }

    private func voidHistoryAndClose(_ account: AccountRow) {
        let accountID = account.id
        if model.simplefin?.links.contains(where: { $0.localAccountID == accountID && $0.status == .active }) == true {
            model.actionError = "\(account.name) is still linked to an active SimpleFIN connection. Disconnect SimpleFIN in Settings before voiding this account's history."
            return
        }
        let now = Int64(Date().timeIntervalSince1970.rounded())
        Task {
            let summary: AccountCloseSummary? = await model.perform { workspace in
                try workspace.closeAccountVoidingHistory(accountID: accountID, nowEpoch: now)
            }
            if let summary {
                if selection == .account(accountID) { selection = .allAccounts }
                model.infoMessage = "\(account.name) is closed. \(summary.voidedImportedRows) imported transactions were voided and \(summary.removedLocalRows) local rows removed. Use Show Closed Accounts at the bottom of the account list to see it."
            }
        }
    }

    private var closedAccountCount: Int {
        (model.snapshot?.accounts ?? []).filter(\.closed).count
    }

    private var sortedAccounts: [AccountRow] {
        (model.snapshot?.accounts ?? [])
            .filter { showClosedAccounts || !$0.closed }
            .sorted {
                ($0.closed ? 1 : 0, $0.onBudget ? 0 : 1, $0.name) < ($1.closed ? 1 : 0, $1.onBudget ? 0 : 1, $1.name)
            }
    }

    /// Rename and close are the only account lifecycle actions: the ledger is
    /// never deleted (§2.1), and close is guarded by the engine.
    @ViewBuilder
    private func accountMenu(for account: AccountRow) -> some View {
        if account.closed {
            Text("Closed account")
            Divider()
            Button("Delete Account…", role: .destructive) {
                deleteAccountConfirmation = ""
                deleteAccountTarget = account
            }
        } else {
            Button("Rename…") { renameAccountTarget = account }
            Divider()
            Button("Close Account…") { closeAccountTarget = account }
        }
    }

    private func closeAccount(_ account: AccountRow) {
        let accountID = account.id
        let now = Int64(Date().timeIntervalSince1970.rounded())
        Task {
            let closed: Bool? = await model.perform { workspace in
                try workspace.closeAccount(accountID: accountID, nowEpoch: now)
                return true
            }
            if closed != nil {
                if selection == .account(accountID) { selection = .allAccounts }
                model.infoMessage = "\(account.name) is closed. Its history is kept; use Show Closed Accounts to see it."
            }
        }
    }

    private func accountRow(_ account: AccountRow) -> some View {
        let balance = model.projection?.registerBalances[account.id] ?? 0
        let pending = (model.snapshot?.transactions ?? []).filter {
            $0.accountID == account.id && ($0.postingState == .needsCategory || $0.postingState == .staged)
        }.count
        return HStack {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(account.name)
                    if account.closed {
                        Image(systemName: "lock")
                            .font(.caption2)
                            .accessibilityLabel("Closed account")
                    }
                    if !account.onBudget {
                        Text("Tracking")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(MoneyFormatting.string(balance, currency: account.currency))
                    .font(.caption)
                    .foregroundStyle(balance < 0 ? .red : .secondary)
                    .accessibilityLabel("Register balance \(MoneyFormatting.string(balance, currency: account.currency))")
            }
            Spacer()
            if pending > 0 {
                Text("\(pending)")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.orange.opacity(0.25)))
                    .accessibilityLabel("\(pending) transactions need attention")
            }
        }
    }
}

/// Creates a local account with §2.2/§4.4 opening-balance rules enforced by
/// the mutation service.
struct AddAccountSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var type: AccountType = .checking
    @State private var onBudget = true
    @State private var openingText = "0"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Account").font(.title3.bold())
            Form {
                TextField("Name", text: $name)
                Picker("Type", selection: $type) {
                    Text("Checking").tag(AccountType.checking)
                    Text("Savings").tag(AccountType.savings)
                    Text("Cash").tag(AccountType.cash)
                    Text("Credit Card").tag(AccountType.creditCard)
                    Text("Other (tracking)").tag(AccountType.other)
                }
                Toggle("On budget", isOn: $onBudget)
                    .disabled(type == .other)
                TextField("Opening balance", text: $openingText)
                    .help("A cash opening is a signed inflow to Ready to Assign: positive funds it, negative (an overdrawn account) reduces it. A credit card with existing debt uses a negative opening; a positive card balance is not allowed.")
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onChange(of: type) { _, newValue in
            if newValue == .other { onBudget = false }
        }
    }

    private func create() {
        guard let snapshot = model.snapshot else { return }
        let calendar = try? BudgetCalendar(timeZoneIdentifier: snapshot.budget.timeZoneIdentifier)
        guard let today = calendar?.budgetDate(fromEpoch: model.nowEpoch) else { return }
        do {
            let opening = try MoneyFormatting.parse(openingText.isEmpty ? "0" : openingText)
            let accountName = name
            let accountType = type
            let budgeted = onBudget
            Task {
                let created: AccountID? = await model.perform { workspace in
                    try workspace.addAccount(
                        name: accountName,
                        type: accountType,
                        onBudget: budgeted,
                        openingBalance: opening,
                        openingDate: today,
                        nowEpoch: Int64(Date().timeIntervalSince1970.rounded())
                    )
                }
                if created != nil { dismiss() }
            }
        } catch {
            model.actionError = model.friendlyMessage(error)
        }
    }
}

/// Renames an account. The engine trims the name, rejects duplicates among
/// open accounts, and renames a credit card's payment category with it.
struct RenameAccountSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let account: AccountRow

    @State private var name: String

    init(account: AccountRow) {
        self.account = account
        _name = State(initialValue: account.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Account").font(.title3.bold())
            Form {
                TextField("Name", text: $name)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Rename") { rename() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func rename() {
        let newName = name
        let accountID = account.id
        let now = Int64(Date().timeIntervalSince1970.rounded())
        Task {
            let renamed: Bool? = await model.perform { workspace in
                try workspace.renameAccount(accountID, to: newName, nowEpoch: now)
                return true
            }
            if renamed != nil { dismiss() }
        }
    }
}

import LedgerCore
import SwiftUI

enum SidebarItem: Hashable {
    case budget
    case review
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
                    Label("Budget", systemImage: "chart.pie")
                        .tag(SidebarItem.budget)
                    Label("Review Queue", systemImage: "checklist")
                        .badge(model.openReviewCount)
                        .tag(SidebarItem.review)
                    Label("All Accounts", systemImage: "list.bullet.rectangle")
                        .badge(model.needsCategoryCount + model.stagedCount)
                        .tag(SidebarItem.allAccounts)
                }
                Section("Accounts") {
                    ForEach(sortedAccounts, id: \.id) { account in
                        accountRow(account)
                            .tag(SidebarItem.account(account.id))
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
            }
        } detail: {
            switch selection {
            case .budget, .none:
                BudgetGridView()
            case .review:
                ReviewQueueView()
            case .allAccounts:
                RegisterView(accountID: nil)
            case .account(let id):
                RegisterView(accountID: id)
            }
        }
        .sheet(isPresented: $showAddAccount) {
            AddAccountSheet()
        }
    }

    private var sortedAccounts: [AccountRow] {
        (model.snapshot?.accounts ?? []).sorted {
            ($0.closed ? 1 : 0, $0.onBudget ? 0 : 1, $0.name) < ($1.closed ? 1 : 0, $1.onBudget ? 0 : 1, $1.name)
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
                    .help("Positive cash opening goes to Ready to Assign. A credit card with existing debt uses a negative opening. This cannot be a positive card balance.")
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

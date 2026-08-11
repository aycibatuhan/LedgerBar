import LedgerCore
import SwiftUI

/// §5.2 transaction register: search, workflow filters (“Needs Category”,
/// “Staged/Needs Resolution” — workflow states, not categories), posting and
/// cleared state, approval, manual transfer pairing, staged-row resolution,
/// and reconciliation.
struct RegisterView: View {
    @Environment(AppModel.self) private var model
    let accountID: AccountID?

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case needsCategory = "Needs Category"
        case staged = "Staged/Needs Resolution"
        case unapproved = "Unapproved"
        var id: String { rawValue }
    }

    @State private var filter: Filter = .all
    @State private var search = ""
    @State private var selection = Set<TransactionID>()
    @State private var showAdd = false
    @State private var showReconcile = false
    @State private var categorizeTarget: TransactionID?
    @State private var reimbursementTarget: TransactionID?
    @State private var refundLinkTarget: TransactionID?
    @State private var unpairedTarget: TransactionID?
    @State private var editTarget: TransactionID?
    @State private var deleteTarget: TransactionID?

    struct Entry: Identifiable {
        var row: TransactionRow
        var accountName: String
        var payeeName: String
        var categoryName: String
        var currency: String
        var id: TransactionID { row.id }
    }

    var body: some View {
        VStack(spacing: 0) {
            Table(entries, selection: $selection) {
                TableColumn("Date") { entry in
                    Text(entry.row.date.description).monospacedDigit()
                }
                .width(min: 90, ideal: 95)
                TableColumn("Account") { entry in
                    Text(entry.accountName)
                }
                .width(min: 90, ideal: 120)
                TableColumn("Payee") { entry in
                    Text(entry.payeeName)
                }
                .width(min: 120, ideal: 160)
                TableColumn("Category") { entry in
                    categoryCell(entry)
                }
                .width(min: 120, ideal: 170)
                TableColumn("Memo") { entry in
                    Text(entry.row.memo ?? "").foregroundStyle(.secondary)
                }
                TableColumn("Amount") { entry in
                    Text(MoneyFormatting.string(entry.row.amountMilliunits, currency: entry.currency))
                        .monospacedDigit()
                        .foregroundStyle(entry.row.amountMilliunits < 0 ? Color.primary : Color.green)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 90, ideal: 110)
                TableColumn("Status") { entry in
                    statusCell(entry)
                }
                .width(min: 110, ideal: 150)
            }
            .contextMenu(forSelectionType: TransactionID.self) { ids in
                contextMenu(for: ids)
            }
            Divider()
            footer
        }
        .searchable(text: $search, prompt: "Search payee, memo, amount")
        .navigationTitle(accountID.map { model.accountName($0) } ?? "All Accounts")
        .toolbar { toolbarContent }
        .sheet(isPresented: $showAdd) { AddTransactionSheet(preselectedAccountID: accountID) }
        .sheet(isPresented: $showReconcile) {
            if let accountID { ReconcileSheet(accountID: accountID) }
        }
        .sheet(item: $categorizeTarget) { id in
            CategorizeSheet(transactionID: id, mode: .categorize)
        }
        .sheet(item: $reimbursementTarget) { id in
            CategorizeSheet(transactionID: id, mode: .cashReimbursement)
        }
        .sheet(item: $refundLinkTarget) { id in
            RefundLinkSheet(refundID: id)
        }
        .sheet(item: $unpairedTarget) { id in
            UnpairedTransferResolutionSheet(transactionID: id)
        }
        .sheet(item: $editTarget) { id in
            EditTransactionSheet(transactionID: id)
        }
        .confirmationDialog(
            "Delete this transaction?",
            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let id = deleteTarget {
                    Task {
                        await model.perform { try $0.deleteTransaction(id, nowEpoch: Int64(Date().timeIntervalSince1970.rounded())) }
                    }
                }
                deleteTarget = nil
            }
        } message: {
            Text("An imported transaction is soft-voided and keeps its import identity for deduplication. A manual transaction without dependents is removed.")
        }
    }

    // MARK: - Data

    private var entries: [Entry] {
        guard let snapshot = model.snapshot else { return [] }
        let accountsByID = Dictionary(uniqueKeysWithValues: snapshot.accounts.map { ($0.id, $0) })
        let payeesByID = Dictionary(uniqueKeysWithValues: snapshot.payees.map { ($0.id, $0) })
        let categoriesByID = Dictionary(uniqueKeysWithValues: snapshot.categories.map { ($0.id, $0) })
        let lowered = search.lowercased()

        return snapshot.transactions
            .filter { row in
                guard row.postingState != .voided else { return false }
                if let accountID, row.accountID != accountID { return false }
                switch filter {
                case .all: break
                case .needsCategory: guard row.postingState == .needsCategory else { return false }
                case .staged: guard row.postingState == .staged else { return false }
                case .unapproved: guard !row.approved else { return false }
                }
                if !lowered.isEmpty {
                    let payee = row.payeeID.flatMap { payeesByID[$0]?.displayName } ?? ""
                    let memo = row.memo ?? ""
                    let amount = MoneyFormatting.editableString(row.amountMilliunits)
                    guard payee.lowercased().contains(lowered)
                        || memo.lowercased().contains(lowered)
                        || amount.contains(lowered) else { return false }
                }
                return true
            }
            .sorted {
                if $0.date != $1.date { return $0.date > $1.date }
                if $0.sourceOrderKey != $1.sourceOrderKey { return $1.sourceOrderKey < $0.sourceOrderKey }
                return $1.id < $0.id
            }
            .map { row in
                Entry(
                    row: row,
                    accountName: accountsByID[row.accountID]?.name ?? "?",
                    payeeName: row.payeeID.flatMap { payeesByID[$0]?.displayName } ?? "",
                    categoryName: row.categoryID.flatMap { categoriesByID[$0]?.name } ?? "",
                    currency: accountsByID[row.accountID]?.currency ?? model.budgetCurrency
                )
            }
    }

    private func transaction(_ id: TransactionID) -> TransactionRow? {
        model.snapshot?.transactions.first { $0.id == id }
    }

    // MARK: - Cells

    @ViewBuilder
    private func categoryCell(_ entry: Entry) -> some View {
        if entry.row.transferPairID != nil {
            Label("Transfer", systemImage: "arrow.left.arrow.right").foregroundStyle(.secondary)
        } else if entry.row.postingState == .staged {
            Text("—").foregroundStyle(.secondary)
        } else if entry.categoryName.isEmpty {
            Text(entry.row.categoryID == nil ? "—" : "?").foregroundStyle(.secondary)
        } else {
            Text(entry.categoryName)
        }
    }

    @ViewBuilder
    private func statusCell(_ entry: Entry) -> some View {
        HStack(spacing: 6) {
            switch entry.row.postingState {
            case .needsCategory:
                Label("Needs category", systemImage: "questionmark.circle")
                    .labelStyle(.iconOnly).foregroundStyle(.orange)
                    .help("Needs a category (counted in the budget via Uncategorized)")
            case .staged:
                Label(stageDescription(entry.row.stageReason), systemImage: "tray.full")
                    .labelStyle(.iconOnly).foregroundStyle(.red)
                    .help("Staged: \(stageDescription(entry.row.stageReason)) — excluded from the budget until resolved")
            case .posted:
                EmptyView()
            case .voided:
                Label("Voided", systemImage: "xmark.circle").labelStyle(.iconOnly)
            }
            Text(clearedLabel(entry.row.cleared))
                .font(.caption)
                .foregroundStyle(entry.row.cleared == .reconciled ? .green : .secondary)
            if !entry.row.approved {
                Text("Unapproved")
                    .font(.caption2)
                    .padding(.horizontal, 4)
                    .background(Capsule().fill(.yellow.opacity(0.3)))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func clearedLabel(_ state: ClearedState) -> String {
        switch state {
        case .uncleared: return "Uncleared"
        case .cleared: return "Cleared"
        case .reconciled: return "Reconciled"
        }
    }

    private func stageDescription(_ reason: StageReason?) -> String {
        switch reason {
        case .cardBalanceWouldBecomePositive: return "Would make card balance positive"
        case .crossMonthRefund: return "Refund of a purchase in another month"
        case .missingRefundOrigin: return "Refund with no known origin"
        case .overRefund: return "Refund exceeds refundable amount"
        case .unlinkedCardInflow: return "Unlinked positive card inflow"
        case .cashInflowWithCreditDebt: return "Cash inflow into a credit-overspent category"
        case .transferPairCounterpartyStaged: return "Other transfer leg is staged"
        case .closedMonthImport: return "Imported into a closed month"
        case .transferPairUnpairNeedsCategorization: return "Unpaired leg needs categorization"
        case nil: return "Staged"
        }
    }

    // MARK: - Toolbar and menus

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Picker("Filter", selection: $filter) {
                ForEach(Filter.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.menu)
            .accessibilityLabel("Register filter")

            Button {
                showAdd = true
            } label: {
                Label("Add Transaction", systemImage: "plus")
            }
            .accessibilityIdentifier("ledgerbar.add-transaction")

            if selection.count == 2 {
                Button {
                    let ids = Array(selection)
                    Task {
                        await model.perform {
                            _ = try $0.pairExistingTransactions(ids[0], ids[1], nowEpoch: Int64(Date().timeIntervalSince1970.rounded()))
                        }
                    }
                } label: {
                    Label("Pair Transfer", systemImage: "arrow.left.arrow.right")
                }
                .help("Pair the two selected rows as one transfer (equal/opposite amounts, same month, ±7 days)")
            }

            if let accountID {
                Menu {
                    Button("Reconcile…") { showReconcile = true }
                    Button("Undo Last Reconciliation") {
                        Task {
                            await model.perform {
                                try $0.undoLastReconciliation(accountID: accountID, nowEpoch: Int64(Date().timeIntervalSince1970.rounded()))
                            }
                        }
                    }
                    .disabled(!hasCompletedReconciliation(accountID))
                } label: {
                    Label("Reconcile", systemImage: "checkmark.seal")
                }
                .help("Undo applies only to the most recent completed reconciliation, and only while its rows are unchanged (§3.9).")
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for ids: Set<TransactionID>) -> some View {
        if ids.count == 1, let id = ids.first, let row = transaction(id) {
            singleRowMenu(id: id, row: row)
        } else if ids.count == 2 {
            Button("Pair as Transfer") {
                let pair = Array(ids)
                Task {
                    await model.perform {
                        _ = try $0.pairExistingTransactions(pair[0], pair[1], nowEpoch: Int64(Date().timeIntervalSince1970.rounded()))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func singleRowMenu(id: TransactionID, row: TransactionRow) -> some View {
        let now = Int64(Date().timeIntervalSince1970.rounded())
        if row.sourceKind != .system, row.postingState != .voided {
            Button("Edit Transaction…") { editTarget = id }
                .disabled(row.cleared == .reconciled)
                .help("Edit date, memo, and manual amount through the guarded ledger mutation.")
        }
        if row.postingState == .posted || row.postingState == .needsCategory {
            if row.transferPairID == nil && (row.kind == .normal || row.kind == .refund) {
                Button("Categorize…") { categorizeTarget = id }
            }
            if row.kind == .normal, row.amountMilliunits > 0, row.transferPairID == nil,
               isCashAccount(row.accountID) {
                Button("Classify as Reimbursement…") { reimbursementTarget = id }
            }
        }
        Button(row.approved ? "Mark Unapproved" : "Approve") {
            let target = !row.approved
            Task { await model.perform { try $0.setApproved(transactionID: id, approved: target, nowEpoch: now) } }
        }
        if row.cleared != .reconciled {
            Button(row.cleared == .cleared ? "Mark Uncleared" : "Mark Cleared") {
                let target: ClearedState = row.cleared == .cleared ? .uncleared : .cleared
                Task { await model.perform { try $0.setCleared(transactionID: id, cleared: target, nowEpoch: now) } }
            }
        } else {
            Button("Un-reconcile") {
                Task { await model.perform { try $0.unreconcileTransaction(id, nowEpoch: now) } }
            }
            .help("Required before editing a reconciled row. The past reconciliation record is kept; its undo becomes blocked.")
        }
        if row.postingState == .staged {
            Divider()
            stagedResolutionMenu(id: id, row: row, now: now)
        }
        if let pairID = row.transferPairID {
            Divider()
            Button("Unpair Transfer") {
                Task { await model.perform { try $0.unpairTransferPair(pairID, nowEpoch: now) } }
            }
            Button("Delete Transfer Pair", role: .destructive) {
                Task { await model.perform { try $0.deleteTransferPair(pairID, nowEpoch: now) } }
            }
        } else {
            Divider()
            Button("Delete…", role: .destructive) { deleteTarget = id }
        }
    }

    @ViewBuilder
    private func stagedResolutionMenu(id: TransactionID, row: TransactionRow, now: Int64) -> some View {
        Menu("Resolve Staged Row") {
            if row.stageReason == .transferPairUnpairNeedsCategorization {
                if unpairedLegNeedsCategory(row) {
                    Button("Categorize Unpaired Transfer Leg…") {
                        unpairedTarget = id
                    }
                } else if unpairedLegCanResolveDirectly(row) {
                    Button("Resolve Unpaired Transfer Leg") {
                        Task {
                            await model.perform {
                                try $0.resolveUnpairedTransferLeg(id, nowEpoch: now)
                            }
                        }
                    }
                } else {
                    Text("Positive credit-card legs require a supported card resolution")
                }
            }
            if row.stageReason == .crossMonthRefund {
                Button("Recover to Ready to Assign (cross-month refund)") {
                    Task { await model.perform { try $0.resolveCrossMonthRefund(id, nowEpoch: now) } }
                }
            }
            if row.stageReason == .cashInflowWithCreditDebt {
                Button("Categorize to Ready to Assign") {
                    Task { await model.perform { try $0.resolveCashInflowToRTA(id, nowEpoch: now) } }
                }
            }
            Button("Resolve as Card Debt Adjustment (budget-neutral)") {
                Task { await model.perform { try $0.resolveStagedAsCardDebtAdjustment(id, nowEpoch: now) } }
            }
            if row.amountMilliunits > 0 {
                Button("Link Refund Origin…") { refundLinkTarget = id }
            }
        }
    }

    private func unpairedLegNeedsCategory(_ row: TransactionRow) -> Bool {
        guard let account = model.snapshot?.accounts.first(where: { $0.id == row.accountID }) else { return false }
        return account.onBudget && account.currency == model.budgetCurrency && row.amountMilliunits < 0
    }

    private func unpairedLegCanResolveDirectly(_ row: TransactionRow) -> Bool {
        guard let account = model.snapshot?.accounts.first(where: { $0.id == row.accountID }) else { return false }
        let eligible = account.onBudget && account.currency == model.budgetCurrency
        return !eligible || (row.amountMilliunits > 0 && account.type != .creditCard)
    }

    private func isCashAccount(_ id: AccountID) -> Bool {
        guard let account = model.snapshot?.accounts.first(where: { $0.id == id }) else { return false }
        return account.type.isCashLike && account.onBudget
    }

    private func hasCompletedReconciliation(_ id: AccountID) -> Bool {
        model.snapshot?.reconciliations.contains {
            $0.reconciliation.accountID == id && $0.reconciliation.status == .completed
        } ?? false
    }

    private var footer: some View {
        HStack {
            if let accountID, let balance = model.projection?.registerBalances[accountID] {
                let account = model.snapshot?.accounts.first { $0.id == accountID }
                Text("Register balance: \(MoneyFormatting.string(balance, currency: account?.currency ?? model.budgetCurrency))")
                    .font(.callout)
                let staged = stagedCountForAccount
                if staged > 0 {
                    Text("· \(staged) staged (in register, not in budget)")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            } else {
                Text("\(entries.count) transactions")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(8)
    }

    private var stagedCountForAccount: Int {
        guard let snapshot = model.snapshot else { return 0 }
        return snapshot.transactions.filter {
            $0.accountID == accountID && $0.postingState == .staged
        }.count
    }
}

extension EntityID: Identifiable {
    public var id: UUID { uuid }
}

import LedgerCore
import SwiftUI

/// Manual transaction entry (§2.2.1 constraint matrix) and explicit manual
/// transfer pairs (§3.8).
struct AddTransactionSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let preselectedAccountID: AccountID?

    enum Direction: String, CaseIterable, Identifiable {
        case outflow = "Outflow"
        case inflow = "Inflow"
        var id: String { rawValue }
    }

    @State private var accountID: AccountID?
    @State private var isTransfer = false
    @State private var destinationAccountID: AccountID?
    @State private var direction: Direction = .outflow
    @State private var dateSelection = Date()
    @State private var payee = ""
    @State private var categoryID: CategoryID?
    @State private var onLegCategoryID: CategoryID?
    @State private var amountText = ""
    @State private var memo = ""
    @State private var isSplit = false
    @State private var splitLines: [SplitDraftLine] = [SplitDraftLine(), SplitDraftLine()]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isTransfer ? "New Transfer" : "New Transaction").font(.title3.bold())
            Form {
                Picker("Account", selection: $accountID) {
                    ForEach(openAccounts, id: \.id) { account in
                        Text(account.name).tag(Optional(account.id))
                    }
                }
                Toggle("Transfer between accounts", isOn: $isTransfer)
                if isTransfer {
                    Picker("To account", selection: $destinationAccountID) {
                        Text("Choose…").tag(Optional<AccountID>.none)
                        ForEach(openAccounts.filter { $0.id != accountID }, id: \.id) { account in
                            Text(account.name).tag(Optional(account.id))
                        }
                    }
                    if transferNeedsCategory {
                        Picker(offBudgetDestination ? "Category (money leaving the plan)" : "Category (money entering the plan)", selection: $onLegCategoryID) {
                            Text("Choose…").tag(Optional<CategoryID>.none)
                            ForEach(onLegCategoryChoices, id: \.id) { category in
                                Text(category.name).tag(Optional(category.id))
                            }
                        }
                    }
                } else {
                    Picker("Direction", selection: $direction) {
                        ForEach(Direction.allCases) { d in Text(d.rawValue).tag(d) }
                    }
                    .pickerStyle(.segmented)
                    TextField("Payee", text: $payee)
                    if selectedAccountIsOnBudget {
                        if direction == .outflow {
                            Toggle("Split across categories", isOn: $isSplit)
                        }
                        if isSplit && direction == .outflow {
                            SplitEditor(
                                totalMagnitude: try? MoneyFormatting.parse(amountText),
                                currency: model.budgetCurrency,
                                lines: $splitLines
                            )
                        } else {
                            Picker("Category", selection: $categoryID) {
                                Text(direction == .inflow ? "Inflow: Ready to Assign" : "Choose…")
                                    .tag(Optional<CategoryID>.none)
                                if direction == .outflow {
                                    ForEach(spendingCategories, id: \.id) { category in
                                        Text(category.name).tag(Optional(category.id))
                                    }
                                }
                            }
                        }
                    }
                }
                DatePicker("Date", selection: $dateSelection, displayedComponents: .date)
                    .environment(\.calendar, budgetPickerCalendar)
                    .environment(\.timeZone, budgetTimeZone)
                TextField("Amount", text: $amountText)
                    .help("Enter a positive number; Outflow/Inflow sets the sign.")
                TextField("Memo", text: $memo)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            accountID = preselectedAccountID ?? openAccounts.first?.id
        }
    }

    private var openAccounts: [AccountRow] {
        (model.snapshot?.accounts ?? []).filter { !$0.closed }.sorted { $0.name < $1.name }
    }

    private var selectedAccountIsOnBudget: Bool {
        guard let accountID, let account = openAccounts.first(where: { $0.id == accountID }) else { return false }
        return account.onBudget && account.currency == model.budgetCurrency
    }

    private var spendingCategories: [CategoryRow] {
        (model.snapshot?.categories ?? [])
            .filter { $0.kind == .spending && !$0.hidden && $0.systemKind == nil }
            .sorted { $0.name < $1.name }
    }

    private var offBudgetDestination: Bool {
        guard let destinationAccountID,
              let destination = openAccounts.first(where: { $0.id == destinationAccountID }) else { return false }
        return !destination.onBudget
    }

    /// §3.8: an on↔off pair requires a category on the on-budget leg.
    private var transferNeedsCategory: Bool {
        guard let accountID, let destinationAccountID,
              let source = openAccounts.first(where: { $0.id == accountID }),
              let destination = openAccounts.first(where: { $0.id == destinationAccountID }) else { return false }
        return source.onBudget != destination.onBudget
    }

    private var onLegCategoryChoices: [CategoryRow] {
        // on → off: money leaves the plan via a spending category.
        // off → on: money enters the plan via RTA (picked automatically), so
        // only the spending list is offered when the source is on-budget.
        spendingCategories
    }

    private var splitActive: Bool {
        isSplit && !isTransfer && direction == .outflow && selectedAccountIsOnBudget
    }

    private var draftComponents: [SplitComponent]? {
        guard splitActive, let magnitude = try? MoneyFormatting.parse(amountText), magnitude > 0 else { return nil }
        return SplitEditor.components(splitLines, totalMagnitude: magnitude)
    }

    private var canSave: Bool {
        guard accountID != nil, !amountText.isEmpty else { return false }
        if isTransfer { return destinationAccountID != nil }
        guard !payee.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if splitActive { return draftComponents != nil }
        return true
    }

    private var budgetTimeZone: TimeZone {
        guard let identifier = model.snapshot?.budget.timeZoneIdentifier,
              let timeZone = TimeZone(identifier: identifier) else {
            return .current
        }
        return timeZone
    }

    private var budgetPickerCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = budgetTimeZone
        return calendar
    }

    private var selectedBudgetDate: BudgetDate? {
        let components = budgetPickerCalendar.dateComponents(
            [.year, .month, .day],
            from: dateSelection
        )
        guard let year = components.year,
              let month = components.month,
              let day = components.day else { return nil }
        return BudgetDate(year: year, month: month, day: day)
    }

    private func save() {
        guard let snapshot = model.snapshot, let accountID else { return }
        do {
            guard let date = selectedBudgetDate else { return }
            let magnitude = try MoneyFormatting.parse(amountText)
            guard magnitude > 0 else { throw MoneyParseError.malformed }
            let now = model.nowEpoch

            if isTransfer {
                guard let destinationAccountID else { return }
                // For off→on the on-budget leg is categorized to RTA by the core.
                let sourceIsOnBudget = openAccounts.first { $0.id == accountID }?.onBudget ?? false
                let onLegCategory: CategoryID? = transferNeedsCategory
                    ? (sourceIsOnBudget ? onLegCategoryID : snapshot.rtaCategoryID)
                    : nil
                if transferNeedsCategory && onLegCategory == nil { return }
                Task {
                    let made: TransferPairID? = await model.perform { workspace in
                        try workspace.createManualTransferPair(
                            sourceAccountID: accountID,
                            destinationAccountID: destinationAccountID,
                            amount: magnitude,
                            date: date,
                            onLegCategoryID: onLegCategory,
                            nowEpoch: now
                        )
                    }
                    if made != nil { dismiss() }
                }
            } else {
                let amount = direction == .outflow ? try negChecked(magnitude) : magnitude
                let components = draftComponents
                let category: CategoryID?
                if components != nil {
                    category = nil
                } else if selectedAccountIsOnBudget {
                    category = direction == .inflow ? snapshot.rtaCategoryID : categoryID
                } else {
                    category = nil
                }
                if selectedAccountIsOnBudget && direction == .outflow && category == nil && components == nil {
                    model.actionError = "Choose a category."
                    return
                }
                let payeeName = payee
                let memoText = memo.isEmpty ? nil : memo
                Task {
                    let made: TransactionID? = await model.perform { workspace in
                        try workspace.addManualTransaction(
                            accountID: accountID,
                            date: date,
                            payeeName: payeeName,
                            categoryID: category,
                            amountMilliunits: amount,
                            memo: memoText,
                            splits: components,
                            nowEpoch: now
                        )
                    }
                    if made != nil { dismiss() }
                }
            }
        } catch {
            model.actionError = model.friendlyMessage(error)
        }
    }
}

/// Explicit categorization / cash-reimbursement classification (§3.5.3,
/// §4.3 payee learning happens in the mutation service).
struct CategorizeSheet: View {
    enum Mode {
        case categorize
        case cashReimbursement
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let transactionID: TransactionID
    let mode: Mode

    @State private var categoryID: CategoryID?
    @State private var createRule = false
    @State private var ruleMatchText = ""
    @State private var ruleRenameText = ""

    private var row: TransactionRow? {
        model.snapshot?.transactions.first { $0.id == transactionID }
    }

    /// A rule can be suggested only for an imported row with a raw description.
    private var canSuggestRule: Bool {
        mode == .categorize && row?.importedDescription != nil && (row?.amountMilliunits ?? 0) < 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(mode == .categorize ? "Categorize" : "Classify as Reimbursement").font(.title3.bold())
            if mode == .cashReimbursement {
                Text("A cash reimbursement increases a spending category instead of Ready to Assign. It posts only when the category has no credit overspending; otherwise it is staged.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if row?.isSplit == true {
                Text("This transaction is split. Choosing one category replaces the split; use Edit Split to change the allocation instead.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Form {
                Picker("Category", selection: $categoryID) {
                    Text("Choose…").tag(Optional<CategoryID>.none)
                    ForEach(choices, id: \.id) { category in
                        Text(category.name).tag(Optional(category.id))
                    }
                }
                if canSuggestRule {
                    Toggle("Also create a rule for this imported payee", isOn: $createRule)
                    if createRule {
                        TextField("When imported payee contains", text: $ruleMatchText)
                        TextField("Rename payee to (optional)", text: $ruleRenameText)
                        Text("The rule categorizes future imports that match; it never changes amounts or existing decisions.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Apply") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(categoryID == nil || (createRule && ruleMatchText.trimmingCharacters(in: .whitespaces).isEmpty))
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            ruleMatchText = row?.importedDescription ?? ""
            ruleRenameText = model.payeeName(row?.payeeID)
        }
    }

    private var choices: [CategoryRow] {
        guard let snapshot = model.snapshot, let row else { return [] }
        let spending = snapshot.categories
            .filter { $0.kind == .spending && !$0.hidden && $0.systemKind == nil }
            .sorted { $0.name < $1.name }
        if mode == .cashReimbursement { return spending }
        if row.amountMilliunits > 0 && row.kind == .normal {
            // §4.3: a positive normal row can only point at the inflow category.
            return snapshot.categories.filter { $0.id == snapshot.rtaCategoryID }
        }
        return spending
    }

    private func apply() {
        guard let categoryID else { return }
        let id = transactionID
        let now = model.nowEpoch
        let mode = mode
        let makeRule = createRule && canSuggestRule
        let matchText = ruleMatchText.trimmingCharacters(in: .whitespaces)
        let renameText = ruleRenameText.trimmingCharacters(in: .whitespaces)
        Task {
            let done: Bool? = await model.perform { workspace in
                switch mode {
                case .categorize:
                    try workspace.categorize(transactionID: id, categoryID: categoryID, nowEpoch: now)
                case .cashReimbursement:
                    try workspace.classifyAsCashReimbursement(id, categoryID: categoryID, nowEpoch: now)
                }
                if makeRule {
                    var actions: [RuleAction] = []
                    if !renameText.isEmpty { actions.append(.setPayee(renameText)) }
                    actions.append(.setCategory(categoryID))
                    _ = try workspace.addRule(
                        name: renameText.isEmpty ? matchText : renameText,
                        conditions: [.importedDescription(.contains, matchText)],
                        actions: actions,
                        nowEpoch: now
                    )
                }
                return true
            }
            if done != nil { dismiss() }
        }
    }
}

/// Explicitly resolves a staged leg left by unpairing a blank manual transfer
/// pair (§3.8). Unlike normal categorization, this sheet is allowed to resolve
/// a staged row because the user is supplying the missing standalone intent.
struct UnpairedTransferResolutionSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let transactionID: TransactionID

    @State private var categoryID: CategoryID?

    private var row: TransactionRow? {
        model.snapshot?.transactions.first { $0.id == transactionID }
    }

    private var account: AccountRow? {
        guard let row else { return nil }
        return model.snapshot?.accounts.first { $0.id == row.accountID }
    }

    private var budgetEligible: Bool {
        guard let account else { return false }
        return account.onBudget && account.currency == model.budgetCurrency
    }

    private var requiresSpendingCategory: Bool {
        budgetEligible && (row?.amountMilliunits ?? 0) < 0
    }

    private var choices: [CategoryRow] {
        (model.snapshot?.categories ?? [])
            .filter { $0.kind == .spending && !$0.hidden && $0.systemKind == nil }
            .sorted { $0.name < $1.name }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Resolve Unpaired Transfer Leg").font(.title3.bold())
            if requiresSpendingCategory {
                Text("This leg has no standalone snapshot. Choose the spending category explicitly; it will not receive an automatic sign-based default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Form {
                    Picker("Category", selection: $categoryID) {
                        Text("Choose…").tag(Optional<CategoryID>.none)
                        ForEach(choices, id: \.id) { category in
                            Text(category.name).tag(Optional(category.id))
                        }
                    }
                }
                .formStyle(.grouped)
            } else if budgetEligible {
                Text("This positive on-budget leg will resolve to Inflow: Ready to Assign.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("This off-budget leg will resolve without a budget category.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Resolve") { resolve() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(requiresSpendingCategory && categoryID == nil)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func resolve() {
        let id = transactionID
        let selectedCategoryID = requiresSpendingCategory ? categoryID : nil
        let now = model.nowEpoch
        Task {
            let done: Bool? = await model.perform { workspace in
                try workspace.resolveUnpairedTransferLeg(
                    id,
                    categoryID: selectedCategoryID,
                    nowEpoch: now
                )
                return true
            }
            if done != nil { dismiss() }
        }
    }
}

/// Register editing surface for the fields that v1 permits. The sheet uses
/// the immutable budget calendar and submits every changed field through one
/// BudgetMutationService transaction, so a paired amount/date edit and its
/// replay either succeed together or roll back together (§3.2/§3.8).
struct EditTransactionSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let transactionID: TransactionID

    @State private var dateSelection = Date()
    @State private var amountText = ""
    @State private var memoText = ""

    private var row: TransactionRow? {
        model.snapshot?.transactions.first { $0.id == transactionID }
    }

    private var amountEditable: Bool {
        row?.sourceKind == .manual
    }

    private var budgetTimeZone: TimeZone {
        guard let identifier = model.snapshot?.budget.timeZoneIdentifier,
              let timeZone = TimeZone(identifier: identifier) else {
            return .current
        }
        return timeZone
    }

    private var budgetPickerCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = budgetTimeZone
        return calendar
    }

    private var selectedBudgetDate: BudgetDate? {
        let components = budgetPickerCalendar.dateComponents(
            [.year, .month, .day],
            from: dateSelection
        )
        guard let year = components.year,
              let month = components.month,
              let day = components.day else { return nil }
        return BudgetDate(year: year, month: month, day: day)
    }

    private var parsedAmount: Milliunits? {
        try? MoneyParser.milliunits(fromDecimalString: amountText)
    }

    private var canApply: Bool {
        guard let row,
              row.postingState != .voided,
              row.cleared != .reconciled,
              selectedBudgetDate != nil else { return false }
        return !amountEditable || parsedAmount != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Transaction").font(.title3.bold())
            if let row, row.transferPairID != nil {
                Text("This is a transfer leg. Amount and date changes apply atomically to both legs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !amountEditable {
                Text("Imported amounts are provider-owned and cannot be edited. Date and memo changes remain guarded by the ledger rules.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if row?.cleared == .reconciled {
                Text("Un-reconcile this row before editing it.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Form {
                DatePicker("Date", selection: $dateSelection, displayedComponents: .date)
                    .environment(\.calendar, budgetPickerCalendar)
                    .environment(\.timeZone, budgetTimeZone)
                TextField("Amount", text: $amountText)
                    .disabled(!amountEditable)
                    .help("Enter a signed amount in the budget currency.")
                TextField("Memo", text: $memoText)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canApply)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear(perform: loadInitialValues)
    }

    private func loadInitialValues() {
        guard let row else { return }
        amountText = MoneyFormatting.editableString(row.amountMilliunits)
        memoText = row.memo ?? ""
        dateSelection = budgetPickerCalendar.date(
            from: DateComponents(year: row.date.year, month: row.date.month, day: row.date.day)
        ) ?? Date()
    }

    private func save() {
        guard let row,
              let date = selectedBudgetDate else { return }
        let amount = amountEditable ? parsedAmount : row.amountMilliunits
        guard let amount else { return }
        let memo = memoText.isEmpty ? nil : memoText
        let id = transactionID
        let originalAmount = row.amountMilliunits
        let originalDate = row.date
        let originalMemo = row.memo
        let now = model.nowEpoch
        Task {
            let done: Bool? = await model.perform { workspace in
                if amount != originalAmount {
                    try workspace.updateAmount(
                        transactionID: id,
                        amountMilliunits: amount,
                        nowEpoch: now
                    )
                }
                if date != originalDate {
                    try workspace.updateDate(transactionID: id, date: date, nowEpoch: now)
                }
                if memo != originalMemo {
                    try workspace.updateMemo(transactionID: id, memo: memo, nowEpoch: now)
                }
                return true
            }
            if done != nil { dismiss() }
        }
    }
}

/// Link a staged positive card row to its originating purchase (§3.5.3).
struct RefundLinkSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let refundID: TransactionID

    @State private var originID: TransactionID?

    private var refund: TransactionRow? {
        model.snapshot?.transactions.first { $0.id == refundID }
    }

    private var candidates: [TransactionRow] {
        guard let snapshot = model.snapshot, let refund else { return [] }
        return snapshot.transactions
            .filter {
                $0.accountID == refund.accountID
                    && $0.amountMilliunits < 0
                    && $0.kind == .normal
                    && $0.postingState != .voided
                    && $0.id != refund.id
            }
            .sorted { $0.date > $1.date }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Link Refund Origin").font(.title3.bold())
            Text("A same-month origin posts the refund against its purchase (credit-first). An origin in an earlier month stages it as a cross-month refund with the explicit Ready-to-Assign recovery.")
                .font(.caption)
                .foregroundStyle(.secondary)
            List(candidates, id: \.id, selection: $originID) { candidate in
                HStack {
                    Text(candidate.date.description).monospacedDigit()
                    Text(model.payeeName(candidate.payeeID))
                    Spacer()
                    Text(MoneyFormatting.string(candidate.amountMilliunits, currency: model.budgetCurrency))
                        .monospacedDigit()
                }
                .tag(candidate.id)
            }
            .frame(minHeight: 220)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Link") { link() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(originID == nil)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func link() {
        guard let originID else { return }
        let id = refundID
        let now = model.nowEpoch
        Task {
            let done: Bool? = await model.perform { workspace in
                try workspace.linkRefundOrigin(id, originID: originID, nowEpoch: now)
                return true
            }
            if done != nil { dismiss() }
        }
    }
}

/// §3.9 reconciliation: statement-date membership over cleared rows, one
/// deterministic adjustment, and completion marking rows reconciled.
struct ReconcileSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let accountID: AccountID

    @State private var statementDate = Date()
    @State private var statementBalanceText = ""

    private var account: AccountRow? {
        model.snapshot?.accounts.first { $0.id == accountID }
    }

    private var budgetDate: BudgetDate? {
        let components = budgetPickerCalendar.dateComponents(
            [.year, .month, .day],
            from: statementDate
        )
        guard let year = components.year,
              let month = components.month,
              let day = components.day else { return nil }
        return BudgetDate(year: year, month: month, day: day)
    }

    private var budgetTimeZone: TimeZone {
        guard let identifier = model.snapshot?.budget.timeZoneIdentifier,
              let timeZone = TimeZone(identifier: identifier) else {
            return .current
        }
        return timeZone
    }

    private var budgetPickerCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = budgetTimeZone
        return calendar
    }

    /// §3.9 step 1, computed live for display from the snapshot.
    private var clearedBalance: Milliunits {
        guard let snapshot = model.snapshot, let budgetDate else { return 0 }
        var total: Milliunits = 0
        for row in snapshot.transactions
        where row.accountID == accountID
            && row.postingState != .voided
            && row.date <= budgetDate
            && (row.cleared == .cleared || row.cleared == .reconciled) {
            let (sum, overflow) = total.addingReportingOverflow(row.amountMilliunits)
            if overflow { return total }
            total = sum
        }
        return total
    }

    private var parsedStatement: Milliunits? {
        try? MoneyFormatting.parse(statementBalanceText)
    }

    var body: some View {
        let currency = account?.currency ?? model.budgetCurrency
        let isCard = account?.type == .creditCard
        VStack(alignment: .leading, spacing: 12) {
            Text("Reconcile \(account?.name ?? "")").font(.title3.bold())
            Text(isCard
                 ? "Enter the statement balance as debt owed, e.g. -250 for $250 of debt. A positive card balance cannot be reconciled in v1."
                 : "Enter the statement balance as money held, e.g. 1200.50.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Form {
                DatePicker("Statement date", selection: $statementDate, displayedComponents: .date)
                    .environment(\.calendar, budgetPickerCalendar)
                    .environment(\.timeZone, budgetTimeZone)
                TextField("Statement balance", text: $statementBalanceText)
                LabeledContent("Cleared balance") {
                    Text(MoneyFormatting.string(clearedBalance, currency: currency)).monospacedDigit()
                }
                if let statement = parsedStatement {
                    LabeledContent("Difference") {
                        let (difference, overflow) = statement.subtractingReportingOverflow(clearedBalance)
                        Text(overflow ? "out of range" : MoneyFormatting.string(difference, currency: currency))
                            .monospacedDigit()
                            .foregroundStyle((overflow || difference != 0) ? Color.orange : Color.green)
                    }
                }
            }
            .formStyle(.grouped)
            Text(isCard
                 ? "A nonzero difference creates one Card Debt Adjustment (no category, budget-neutral). It is allowed only while the card stays at or below zero."
                 : "A nonzero difference creates one Reconciliation Balance Adjustment to Ready to Assign (signed).")
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Complete Reconciliation") { complete() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(parsedStatement == nil || budgetDate == nil)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func complete() {
        guard let statement = parsedStatement, let budgetDate else { return }
        let id = accountID
        let now = model.nowEpoch
        Task {
            let outcome: ReconciliationOutcome? = await model.perform { workspace in
                try workspace.completeReconciliation(
                    accountID: id,
                    statementDate: budgetDate,
                    statementBalanceMilliunits: statement,
                    nowEpoch: now
                )
            }
            if let outcome {
                model.infoMessage = "Reconciled. \(outcome.newlyReconciledCount) row(s) newly marked reconciled" +
                    (outcome.adjustmentTransactionID != nil ? "; one adjustment was created." : ".")
                dismiss()
            }
        }
    }
}

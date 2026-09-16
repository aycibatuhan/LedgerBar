import LedgerCore
import SwiftUI

/// Automation rules (docs/DESIGN.md D4): an ordered list with enable
/// toggles, an editor with a live "matches now" preview, and an explicit
/// retroactive apply flow with a mandatory preview.
struct RulesView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: RuleEditorTarget?
    @State private var applyScope: RuleApplyTarget?
    @State private var deleteTarget: AutomationRule?

    private var rules: [AutomationRule] {
        (model.snapshot?.automationRules ?? []).sorted { ($0.sortOrder, $0.id) < ($1.sortOrder, $1.id) }
    }

    var body: some View {
        Group {
            if rules.isEmpty {
                ContentUnavailableView {
                    Label("No rules yet", systemImage: "wand.and.stars")
                } description: {
                    Text("Rules rename payees, categorize, annotate, flag, or split imported transactions as they arrive. They run once at import and never change amounts, dates, accounts, or reconciled rows.")
                } actions: {
                    Button("New Rule…") { editing = .new }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    ForEach(rules) { rule in
                        ruleRow(rule)
                            .contextMenu { ruleMenu(rule) }
                    }
                    .onMove { source, destination in
                        var ordered = rules
                        ordered.move(fromOffsets: source, toOffset: destination)
                        let ids = ordered.map(\.id)
                        let now = model.nowEpoch
                        Task { await model.perform { try $0.reorderRules(ids, nowEpoch: now) } }
                    }
                }
            }
        }
        .navigationTitle("Rules")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    editing = .new
                } label: {
                    Label("New Rule", systemImage: "plus")
                }
                .accessibilityIdentifier("ledgerbar.rules.new")
                Button {
                    applyScope = RuleApplyTarget(ruleIDs: nil)
                } label: {
                    Label("Apply to Existing…", systemImage: "arrow.counterclockwise")
                }
                .disabled(rules.isEmpty)
                .help("Run enabled rules over existing transactions after a preview. Rows you categorized yourself are skipped unless you choose to overwrite them.")
            }
        }
        .sheet(item: $editing) { target in
            RuleEditorSheet(target: target)
        }
        .sheet(item: $applyScope) { target in
            RuleApplySheet(target: target)
        }
        .confirmationDialog(
            "Delete rule “\(deleteTarget?.name ?? "")”?",
            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Rule", role: .destructive) {
                if let rule = deleteTarget {
                    let now = model.nowEpoch
                    Task { await model.perform { try $0.deleteRule(rule.id, nowEpoch: now) } }
                }
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Transactions the rule already changed keep their values and their audit history.")
        }
    }

    private func ruleRow(_ rule: AutomationRule) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(
                get: { rule.enabled },
                set: { enabled in
                    let now = model.nowEpoch
                    Task { await model.perform { try $0.setRuleEnabled(rule.id, enabled: enabled, nowEpoch: now) } }
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .accessibilityLabel("Enable \(rule.name)")
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(rule.name).fontWeight(.medium)
                    if rule.stopAfterMatch {
                        Text("stops").font(.caption2).padding(.horizontal, 4).background(Capsule().fill(.quaternary))
                    }
                }
                Text("If \(rule.matchMode == .all ? "all" : "any"): " + rule.conditions.map { RuleDescriptions.condition($0, model: model) }.joined(separator: rule.matchMode == .all ? " and " : " or "))
                    .font(.caption).foregroundStyle(.secondary)
                Text("Then: " + rule.actions.map { RuleDescriptions.action($0, model: model) }.joined(separator: "; "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(model.snapshot.map { _ in matchCount(rule) } ?? 0) match now")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
        .onTapGesture(count: 2) { editing = .existing(rule) }
    }

    private func matchCount(_ rule: AutomationRule) -> Int {
        guard let snapshot = model.snapshot else { return 0 }
        let context = RuleContext(
            categories: Dictionary(uniqueKeysWithValues: snapshot.categories.map { ($0.id, $0) }),
            accounts: Dictionary(uniqueKeysWithValues: snapshot.accounts.map { ($0.id, $0) }),
            budgetCurrency: snapshot.budget.currency,
            rtaCategoryID: snapshot.rtaCategoryID,
            uncategorizedID: snapshot.uncategorizedID
        )
        _ = context
        let payees = Dictionary(uniqueKeysWithValues: snapshot.payees.map { ($0.id, $0.displayName) })
        return snapshot.transactions.filter { row in
            guard row.postingState != .voided else { return false }
            let subject = RuleSubject(
                importedDescription: row.importedDescription,
                payeeDisplayName: row.payeeID.flatMap { payees[$0] },
                memo: row.memo, accountID: row.accountID, amountMilliunits: row.amountMilliunits,
                date: row.date, sourceKind: row.sourceKind, categoryID: row.categoryID, isSplit: row.isSplit
            )
            return RuleEngine.matches(rule, subject: subject)
        }.count
    }

    @ViewBuilder
    private func ruleMenu(_ rule: AutomationRule) -> some View {
        Button("Edit…") { editing = .existing(rule) }
        Button("Apply This Rule to Existing…") { applyScope = RuleApplyTarget(ruleIDs: [rule.id]) }
        Divider()
        Button("Delete…", role: .destructive) { deleteTarget = rule }
    }
}

enum RuleEditorTarget: Identifiable {
    case new
    case existing(AutomationRule)
    /// Pre-filled from a transaction (categorize sheet suggestion).
    case suggested(name: String, conditions: [RuleCondition], actions: [RuleAction])

    var id: String {
        switch self {
        case .new: return "new"
        case .existing(let rule): return rule.id.description
        case .suggested(let name, _, _): return "suggested-\(name)"
        }
    }
}

struct RuleApplyTarget: Identifiable {
    var ruleIDs: Set<AutomationRuleID>?
    var id: String { ruleIDs?.map(\.description).sorted().joined(separator: ",") ?? "all" }
}

/// Human-readable descriptions shared by the list, editor, and previews.
enum RuleDescriptions {
    @MainActor
    static func condition(_ condition: RuleCondition, model: AppModel) -> String {
        switch condition {
        case let .importedDescription(op, v): return "imported payee \(text(op)) “\(v)”"
        case let .payee(op, v): return "payee \(text(op)) “\(v)”"
        case let .memo(op, v): return "memo \(text(op)) “\(v)”"
        case .account(let id): return "account is \(model.accountName(id))"
        case .amount(let op):
            switch op {
            case .equals(let v): return "amount is \(MoneyFormatting.string(v, currency: model.budgetCurrency))"
            case .lessThan(let v): return "amount < \(MoneyFormatting.string(v, currency: model.budgetCurrency))"
            case .greaterThan(let v): return "amount > \(MoneyFormatting.string(v, currency: model.budgetCurrency))"
            case let .between(a, b): return "amount between \(MoneyFormatting.string(a, currency: model.budgetCurrency)) and \(MoneyFormatting.string(b, currency: model.budgetCurrency))"
            }
        case .direction(let d): return d == .outflow ? "is an outflow" : "is an inflow"
        case .date(let d):
            switch d {
            case let .dayOfMonth(from, to): return "day of month \(from)–\(to)"
            case .weekdays(let days): return "weekday in \(days.map(weekdayName).joined(separator: "/"))"
            case let .range(from, to): return "dated \(from.description) to \(to.description)"
            }
        case .source(let s): return "source is \(s.rawValue)"
        case .category(let id): return id.map { "category is \(model.categoryName($0))" } ?? "has no category"
        }
    }

    @MainActor
    static func action(_ action: RuleAction, model: AppModel) -> String {
        switch action {
        case .setPayee(let name): return "rename payee to “\(name)”"
        case .setCategory(let id): return "categorize as \(model.categoryName(id))"
        case let .setMemo(mode, text): return "\(mode.rawValue) memo “\(text)”"
        case .setFlag(let color): return color.map { "flag \($0.rawValue)" } ?? "clear flag"
        case .setApproved(let a): return a ? "approve" : "mark unapproved"
        case .split(let specs):
            return "split: " + specs.map { spec in
                let share: String
                switch spec.share {
                case .fixed(let m): share = MoneyFormatting.string(m, currency: model.budgetCurrency)
                case .basisPoints(let bp): share = "\(Double(bp) / 100)%"
                }
                return "\(model.categoryName(spec.categoryID)) \(share)"
            }.joined(separator: ", ")
        }
    }

    static func text(_ op: RuleTextOperator) -> String {
        switch op {
        case .contains: return "contains"
        case .equals: return "is"
        case .startsWith: return "starts with"
        case .endsWith: return "ends with"
        case .wildcard: return "matches"
        }
    }

    static func weekdayName(_ day: Int) -> String {
        ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][max(0, min(6, day - 1))]
    }
}

// MARK: - Editor

/// Draft condition row. Text values, amounts, and dates are entered as text
/// and validated on save.
struct RuleConditionDraft: Identifiable, Equatable {
    enum Field: String, CaseIterable, Identifiable {
        case importedDescription = "Imported payee"
        case payee = "Payee"
        case memo = "Memo"
        case account = "Account"
        case amount = "Amount"
        case direction = "Direction"
        case dayOfMonth = "Day of month"
        case source = "Source"
        var id: String { rawValue }
    }
    enum AmountOp: String, CaseIterable, Identifiable {
        case equals = "is", lessThan = "is less than", greaterThan = "is more than", between = "is between"
        var id: String { rawValue }
    }
    let id = UUID()
    var field: Field = .importedDescription
    var textOperator: RuleTextOperator = .contains
    var text = ""
    var accountID: AccountID?
    var amountOp: AmountOp = .between
    var amountA = ""
    var amountB = ""
    var direction: RuleDirection = .outflow
    var dayFrom = "1"
    var dayTo = "31"
    var source: RuleSource = .imported

    func condition() throws -> RuleCondition {
        switch field {
        case .importedDescription: return .importedDescription(textOperator, text)
        case .payee: return .payee(textOperator, text)
        case .memo: return .memo(textOperator, text)
        case .account:
            guard let accountID else { throw MutationError.ruleInvalid }
            return .account(accountID)
        case .amount:
            let a = try MoneyFormatting.parse(amountA)
            switch amountOp {
            case .equals: return .amount(.equals(a))
            case .lessThan: return .amount(.lessThan(a))
            case .greaterThan: return .amount(.greaterThan(a))
            case .between: return .amount(.between(a, try MoneyFormatting.parse(amountB)))
            }
        case .direction: return .direction(direction)
        case .dayOfMonth:
            guard let from = Int(dayFrom), let to = Int(dayTo) else { throw MutationError.ruleInvalid }
            return .date(.dayOfMonth(from: from, to: to))
        case .source: return .source(source)
        }
    }

    static func from(_ condition: RuleCondition) -> RuleConditionDraft? {
        var draft = RuleConditionDraft()
        switch condition {
        case let .importedDescription(op, v): draft.field = .importedDescription; draft.textOperator = op; draft.text = v
        case let .payee(op, v): draft.field = .payee; draft.textOperator = op; draft.text = v
        case let .memo(op, v): draft.field = .memo; draft.textOperator = op; draft.text = v
        case .account(let id): draft.field = .account; draft.accountID = id
        case .amount(let op):
            draft.field = .amount
            switch op {
            case .equals(let v): draft.amountOp = .equals; draft.amountA = MoneyFormatting.editableString(v)
            case .lessThan(let v): draft.amountOp = .lessThan; draft.amountA = MoneyFormatting.editableString(v)
            case .greaterThan(let v): draft.amountOp = .greaterThan; draft.amountA = MoneyFormatting.editableString(v)
            case let .between(a, b):
                draft.amountOp = .between
                draft.amountA = MoneyFormatting.editableString(a)
                draft.amountB = MoneyFormatting.editableString(b)
            }
        case .direction(let d): draft.field = .direction; draft.direction = d
        case let .date(.dayOfMonth(from, to)): draft.field = .dayOfMonth; draft.dayFrom = String(from); draft.dayTo = String(to)
        case .date: return nil // weekday/range conditions are engine-only for now
        case .source(let s): draft.field = .source; draft.source = s
        case .category: return nil
        }
        return draft
    }
}

struct RuleActionDraft: Identifiable, Equatable {
    enum Kind: String, CaseIterable, Identifiable {
        case setCategory = "Categorize as"
        case setPayee = "Rename payee to"
        case setMemo = "Memo"
        case setFlag = "Flag"
        case setApproved = "Approval"
        case split = "Split by percent"
        var id: String { rawValue }
    }
    let id = UUID()
    var kind: Kind = .setCategory
    var categoryID: CategoryID?
    var text = ""
    var memoMode: RuleMemoMode = .append
    var flag: FlagColor? = .blue
    var approved = true
    var splitLines: [(categoryID: CategoryID?, percentText: String)] = [(nil, "50"), (nil, "50")]

    static func == (l: RuleActionDraft, r: RuleActionDraft) -> Bool { l.id == r.id }

    func action() throws -> RuleAction {
        switch kind {
        case .setCategory:
            guard let categoryID else { throw MutationError.ruleInvalid }
            return .setCategory(categoryID)
        case .setPayee: return .setPayee(text)
        case .setMemo: return .setMemo(memoMode, text)
        case .setFlag: return .setFlag(flag)
        case .setApproved: return .setApproved(approved)
        case .split:
            let specs = try splitLines.map { line -> RuleSplitSpec in
                guard let categoryID = line.categoryID,
                      let percent = Decimal(string: line.percentText, locale: Locale(identifier: "en_US_POSIX")),
                      percent > 0 else { throw MutationError.ruleInvalid }
                let basisPoints = NSDecimalNumber(decimal: percent * 100).intValue
                return RuleSplitSpec(categoryID: categoryID, share: .basisPoints(basisPoints))
            }
            return .split(specs)
        }
    }

    static func from(_ action: RuleAction) -> RuleActionDraft {
        var draft = RuleActionDraft()
        switch action {
        case .setCategory(let id): draft.kind = .setCategory; draft.categoryID = id
        case .setPayee(let name): draft.kind = .setPayee; draft.text = name
        case let .setMemo(mode, text): draft.kind = .setMemo; draft.memoMode = mode; draft.text = text
        case .setFlag(let color): draft.kind = .setFlag; draft.flag = color
        case .setApproved(let a): draft.kind = .setApproved; draft.approved = a
        case .split(let specs):
            draft.kind = .split
            draft.splitLines = specs.map { spec in
                switch spec.share {
                case .basisPoints(let bp): return (spec.categoryID, "\(Decimal(bp) / 100)")
                case .fixed(let m): return (spec.categoryID, MoneyFormatting.editableString(m))
                }
            }
        }
        return draft
    }
}

struct RuleEditorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let target: RuleEditorTarget

    @State private var name = ""
    @State private var matchMode: RuleMatchMode = .all
    @State private var stopAfterMatch = false
    @State private var conditions: [RuleConditionDraft] = [RuleConditionDraft()]
    @State private var actions: [RuleActionDraft] = [RuleActionDraft()]
    @State private var validationMessage: String?

    private var existing: AutomationRule? {
        if case .existing(let rule) = target { return rule }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(existing == nil ? "New Rule" : "Edit Rule").font(.title3.bold())
            Form {
                TextField("Name", text: $name)
                Picker("Match", selection: $matchMode) {
                    Text("All conditions").tag(RuleMatchMode.all)
                    Text("Any condition").tag(RuleMatchMode.any)
                }
                .pickerStyle(.segmented)
                Section("If") {
                    ForEach($conditions) { $draft in
                        RuleConditionRow(draft: $draft, onRemove: {
                            conditions.removeAll { $0.id == draft.id }
                        }, removable: conditions.count > 1)
                    }
                    Button { conditions.append(RuleConditionDraft()) } label: { Label("Add Condition", systemImage: "plus.circle") }
                        .buttonStyle(.borderless)
                }
                Section("Then") {
                    ForEach($actions) { $draft in
                        RuleActionRow(draft: $draft, onRemove: {
                            actions.removeAll { $0.id == draft.id }
                        }, removable: actions.count > 1)
                    }
                    Button { actions.append(RuleActionDraft()) } label: { Label("Add Action", systemImage: "plus.circle") }
                        .buttonStyle(.borderless)
                }
                Toggle("Stop processing further rules after this one matches", isOn: $stopAfterMatch)
            }
            .formStyle(.grouped)
            if let validationMessage {
                Text(validationMessage).font(.caption).foregroundStyle(.red)
            }
            Text("Rules run once when a transaction is imported, in the order shown in the Rules list. Category actions that do not fit a transaction's sign are skipped and reported, never forced.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(previewSummary).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                Button(existing == nil ? "Create Rule" : "Save Rule") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 640, height: 560)
        .onAppear(perform: load)
    }

    private var previewSummary: String {
        guard let snapshot = model.snapshot, let draftRule = try? buildRule(budgetID: snapshot.budget.id) else {
            return "Complete the conditions to see how many existing transactions match."
        }
        let payees = Dictionary(uniqueKeysWithValues: snapshot.payees.map { ($0.id, $0.displayName) })
        let count = snapshot.transactions.filter { row in
            row.postingState != .voided && RuleEngine.matches(draftRule, subject: RuleSubject(
                importedDescription: row.importedDescription, payeeDisplayName: row.payeeID.flatMap { payees[$0] },
                memo: row.memo, accountID: row.accountID, amountMilliunits: row.amountMilliunits, date: row.date,
                sourceKind: row.sourceKind, categoryID: row.categoryID, isSplit: row.isSplit
            ))
        }.count
        return "\(count) existing transaction(s) match these conditions."
    }

    private func load() {
        switch target {
        case .new:
            break
        case .existing(let rule):
            name = rule.name
            matchMode = rule.matchMode
            stopAfterMatch = rule.stopAfterMatch
            conditions = rule.conditions.compactMap(RuleConditionDraft.from)
            if conditions.isEmpty { conditions = [RuleConditionDraft()] }
            actions = rule.actions.map(RuleActionDraft.from)
        case let .suggested(suggestedName, suggestedConditions, suggestedActions):
            name = suggestedName
            conditions = suggestedConditions.compactMap(RuleConditionDraft.from)
            actions = suggestedActions.map(RuleActionDraft.from)
        }
    }

    private func buildRule(budgetID: BudgetID) throws -> AutomationRule {
        AutomationRule(
            id: existing?.id ?? AutomationRuleID(),
            budgetID: budgetID,
            name: name,
            enabled: existing?.enabled ?? true,
            sortOrder: existing?.sortOrder ?? 0,
            matchMode: matchMode,
            conditions: try conditions.map { try $0.condition() },
            actions: try actions.map { try $0.action() },
            stopAfterMatch: stopAfterMatch
        )
    }

    private func save() {
        guard let snapshot = model.snapshot else { return }
        do {
            let rule = try buildRule(budgetID: snapshot.budget.id)
            let now = model.nowEpoch
            let isExisting = existing != nil
            Task {
                let done: Bool? = await model.perform { workspace in
                    if isExisting {
                        try workspace.updateRule(rule, nowEpoch: now)
                    } else {
                        _ = try workspace.addRule(
                            name: rule.name, matchMode: rule.matchMode, conditions: rule.conditions,
                            actions: rule.actions, stopAfterMatch: rule.stopAfterMatch, nowEpoch: now
                        )
                    }
                    return true
                }
                if done != nil { dismiss() }
            }
        } catch {
            validationMessage = model.friendlyMessage(error)
        }
    }
}

private struct RuleConditionRow: View {
    @Environment(AppModel.self) private var model
    @Binding var draft: RuleConditionDraft
    let onRemove: () -> Void
    let removable: Bool

    var body: some View {
        HStack(spacing: 8) {
            Picker("Field", selection: $draft.field) {
                ForEach(RuleConditionDraft.Field.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .frame(width: 150)
            switch draft.field {
            case .importedDescription, .payee, .memo:
                Picker("Operator", selection: $draft.textOperator) {
                    ForEach(RuleTextOperator.allCases, id: \.self) { Text(RuleDescriptions.text($0)).tag($0) }
                }
                .labelsHidden()
                .frame(width: 120)
                TextField("Text", text: $draft.text).textFieldStyle(.roundedBorder)
            case .account:
                Picker("Account", selection: $draft.accountID) {
                    Text("Choose…").tag(Optional<AccountID>.none)
                    ForEach(model.snapshot?.accounts ?? [], id: \.id) { Text($0.name).tag(Optional($0.id)) }
                }
                .labelsHidden()
            case .amount:
                Picker("Operator", selection: $draft.amountOp) {
                    ForEach(RuleConditionDraft.AmountOp.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 130)
                TextField("Amount", text: $draft.amountA).textFieldStyle(.roundedBorder).frame(width: 90)
                if draft.amountOp == .between {
                    Text("and")
                    TextField("Amount", text: $draft.amountB).textFieldStyle(.roundedBorder).frame(width: 90)
                }
            case .direction:
                Picker("Direction", selection: $draft.direction) {
                    Text("Outflow").tag(RuleDirection.outflow)
                    Text("Inflow").tag(RuleDirection.inflow)
                }
                .labelsHidden()
            case .dayOfMonth:
                TextField("From", text: $draft.dayFrom).textFieldStyle(.roundedBorder).frame(width: 50)
                Text("to")
                TextField("To", text: $draft.dayTo).textFieldStyle(.roundedBorder).frame(width: 50)
            case .source:
                Picker("Source", selection: $draft.source) {
                    Text("Imported (any)").tag(RuleSource.imported)
                    Text("SimpleFIN").tag(RuleSource.simplefin)
                    Text("File").tag(RuleSource.file)
                    Text("Manual").tag(RuleSource.manual)
                }
                .labelsHidden()
            }
            Spacer(minLength: 0)
            Button { onRemove() } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .disabled(!removable)
                .accessibilityLabel("Remove condition")
        }
    }
}

private struct RuleActionRow: View {
    @Environment(AppModel.self) private var model
    @Binding var draft: RuleActionDraft
    let onRemove: () -> Void
    let removable: Bool

    private var spendingCategories: [CategoryRow] {
        (model.snapshot?.categories ?? [])
            .filter { $0.kind == .spending && !$0.hidden && $0.systemKind == nil }
            .sorted { $0.name < $1.name }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Picker("Action", selection: $draft.kind) {
                    ForEach(RuleActionDraft.Kind.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 150)
                switch draft.kind {
                case .setCategory:
                    Picker("Category", selection: $draft.categoryID) {
                        Text("Choose…").tag(Optional<CategoryID>.none)
                        ForEach(spendingCategories, id: \.id) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .labelsHidden()
                case .setPayee:
                    TextField("New payee name", text: $draft.text).textFieldStyle(.roundedBorder)
                case .setMemo:
                    Picker("Mode", selection: $draft.memoMode) {
                        ForEach(RuleMemoMode.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 100)
                    TextField("Memo text", text: $draft.text).textFieldStyle(.roundedBorder)
                case .setFlag:
                    Picker("Flag", selection: $draft.flag) {
                        Text("None").tag(Optional<FlagColor>.none)
                        ForEach(FlagColor.allCases, id: \.self) { Text($0.rawValue.capitalized).tag(Optional($0)) }
                    }
                    .labelsHidden()
                case .setApproved:
                    Toggle("Approve automatically", isOn: $draft.approved)
                case .split:
                    Text("Percentages must total 100").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button { onRemove() } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                    .disabled(!removable)
                    .accessibilityLabel("Remove action")
            }
            if draft.kind == .split {
                ForEach(draft.splitLines.indices, id: \.self) { index in
                    HStack {
                        Picker("Category", selection: Binding(
                            get: { draft.splitLines[index].categoryID },
                            set: { draft.splitLines[index].categoryID = $0 }
                        )) {
                            Text("Choose…").tag(Optional<CategoryID>.none)
                            ForEach(spendingCategories, id: \.id) { Text($0.name).tag(Optional($0.id)) }
                        }
                        .labelsHidden()
                        TextField("%", text: Binding(
                            get: { draft.splitLines[index].percentText },
                            set: { draft.splitLines[index].percentText = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                        Text("%")
                        Button {
                            if draft.splitLines.count > 2 { draft.splitLines.remove(at: index) }
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .disabled(draft.splitLines.count <= 2)
                    }
                }
                Button { draft.splitLines.append((nil, "0")) } label: { Label("Add Split Line", systemImage: "plus.circle") }
                    .buttonStyle(.borderless)
            }
        }
    }
}

// MARK: - Retroactive apply

struct RuleApplySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let target: RuleApplyTarget

    @State private var accountID: AccountID?
    @State private var overwriteUserEdits = false
    @State private var onlyUncategorized = false
    @State private var preview: [RulePreviewItem] = []
    @State private var loaded = false
    @State private var applying = false

    private var scope: RuleApplicationScope {
        RuleApplicationScope(
            accountID: accountID,
            ruleIDs: target.ruleIDs,
            overwriteUserEdits: overwriteUserEdits,
            includeCategorized: !onlyUncategorized
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Apply Rules to Existing Transactions").font(.title3.bold())
            Form {
                Picker("Account", selection: $accountID) {
                    Text("All accounts").tag(Optional<AccountID>.none)
                    ForEach((model.snapshot?.accounts ?? []).filter { !$0.closed }, id: \.id) { Text($0.name).tag(Optional($0.id)) }
                }
                Toggle("Only transactions still needing a category", isOn: $onlyUncategorized)
                Toggle("Also change transactions I categorized or edited myself", isOn: $overwriteUserEdits)
            }
            .formStyle(.grouped)
            .onChange(of: accountID) { _, _ in refresh() }
            .onChange(of: overwriteUserEdits) { _, _ in refresh() }
            .onChange(of: onlyUncategorized) { _, _ in refresh() }
            Divider()
            if preview.isEmpty {
                Text(loaded ? "No transactions would change." : "Loading preview…")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 140)
            } else {
                Text("\(preview.count) transaction(s) would change:").font(.callout)
                List(preview) { item in
                    previewRow(item)
                }
                .frame(minHeight: 200)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(applying ? "Applying…" : "Apply \(preview.count) Change(s)") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(preview.isEmpty || applying)
            }
        }
        .padding(20)
        .frame(width: 620, height: 520)
        .task { refresh() }
    }

    @ViewBuilder
    private func previewRow(_ item: RulePreviewItem) -> some View {
        if let row = model.snapshot?.transactions.first(where: { $0.id == item.transactionID }) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(row.date.description).monospacedDigit()
                    Text(model.payeeName(row.payeeID))
                    Spacer()
                    Text(MoneyFormatting.string(row.amountMilliunits, currency: model.budgetCurrency)).monospacedDigit()
                }
                Text(changeDescription(row: row, proposal: item.proposal))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func changeDescription(row: TransactionRow, proposal: RuleProposal) -> String {
        var parts: [String] = []
        if let payee = proposal.payeeName { parts.append("payee → \(payee)") }
        if let splits = proposal.splits {
            parts.append("split into \(splits.count) categories")
        } else if let category = proposal.categoryID {
            parts.append("\(model.categoryName(row.categoryID).isEmpty ? "no category" : model.categoryName(row.categoryID)) → \(model.categoryName(category))")
        }
        if case .some(let memo) = proposal.memo { parts.append("memo → \(memo ?? "")") }
        if case .some(let flag) = proposal.flagColor { parts.append("flag → \(flag?.rawValue ?? "none")") }
        if let approved = proposal.approved { parts.append(approved ? "approve" : "unapprove") }
        if !proposal.skipped.isEmpty { parts.append("\(proposal.skipped.count) action(s) skipped") }
        return parts.joined(separator: "; ")
    }

    private func refresh() {
        let scope = scope
        Task {
            preview = await model.previewRules(scope: scope)
            loaded = true
        }
    }

    private func apply() {
        applying = true
        let scope = scope
        let now = model.nowEpoch
        Task {
            let summary: RuleApplicationSummary? = await model.perform { try $0.applyRules(scope: scope, nowEpoch: now) }
            applying = false
            if let summary {
                model.infoMessage = "Rules changed \(summary.changedRows) of \(summary.consideredRows) transaction(s)." + (summary.skippedActions > 0 ? " \(summary.skippedActions) action(s) were skipped as incompatible." : "")
                dismiss()
            }
        }
    }
}

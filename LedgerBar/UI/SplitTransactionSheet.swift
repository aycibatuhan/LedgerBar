import LedgerCore
import SwiftUI

/// One editable split line in the UI: a category and a positive magnitude.
/// The engine receives signed components; the sheet keeps entry positive so
/// the user never types minus signs.
struct SplitDraftLine: Identifiable, Equatable {
    let id = UUID()
    var categoryID: CategoryID?
    var amountText: String = ""
    var memo: String = ""
}

/// Reusable split editor (D3 UI): shows the running remainder, adds and
/// removes lines, and reports validity. Used by the split sheet and by the
/// Add Transaction sheet.
struct SplitEditor: View {
    @Environment(AppModel.self) private var model
    let totalMagnitude: Milliunits?
    let currency: String
    @Binding var lines: [SplitDraftLine]

    private var categories: [CategoryRow] {
        (model.snapshot?.categories ?? [])
            .filter { $0.kind == .spending && !$0.hidden && $0.systemKind == nil }
            .sorted { $0.name < $1.name }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach($lines) { $line in
                HStack(spacing: 8) {
                    Picker("Category", selection: $line.categoryID) {
                        Text("Choose…").tag(Optional<CategoryID>.none)
                        ForEach(categories, id: \.id) { category in
                            Text(category.name).tag(Optional(category.id))
                        }
                    }
                    .labelsHidden()
                    .frame(minWidth: 160)
                    TextField("Amount", text: $line.amountText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                        .multilineTextAlignment(.trailing)
                    TextField("Memo", text: $line.memo)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        lines.removeAll { $0.id == line.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(lines.count <= 2)
                    .accessibilityLabel("Remove split line")
                }
            }
            HStack {
                Button {
                    lines.append(SplitDraftLine())
                } label: {
                    Label("Add Line", systemImage: "plus.circle")
                }
                .buttonStyle(.borderless)
                Spacer()
                remainderLabel
            }
        }
    }

    @ViewBuilder
    private var remainderLabel: some View {
        if let totalMagnitude {
            let assigned = SplitEditor.assignedMagnitude(lines)
            let remainder = totalMagnitude - (assigned ?? 0)
            if assigned == nil {
                Text("Enter valid amounts").font(.caption).foregroundStyle(.orange)
            } else if remainder == 0 {
                Label("Fully allocated", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green)
            } else {
                Text("Remaining: \(MoneyFormatting.string(remainder, currency: currency))")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .monospacedDigit()
            }
        }
    }

    /// Sum of the positive line magnitudes, or nil if any line is malformed.
    static func assignedMagnitude(_ lines: [SplitDraftLine]) -> Milliunits? {
        var total: Milliunits = 0
        for line in lines {
            guard let value = try? MoneyFormatting.parse(line.amountText), value > 0 else { return nil }
            let (sum, overflow) = total.addingReportingOverflow(value)
            if overflow { return nil }
            total = sum
        }
        return total
    }

    /// Signed components for an outflow parent of `totalMagnitude`, or nil if
    /// the draft is incomplete. The engine re-validates everything.
    static func components(_ lines: [SplitDraftLine], totalMagnitude: Milliunits) -> [SplitComponent]? {
        guard lines.count >= 2, assignedMagnitude(lines) == totalMagnitude else { return nil }
        var result: [SplitComponent] = []
        for line in lines {
            guard let categoryID = line.categoryID,
                  let magnitude = try? MoneyFormatting.parse(line.amountText), magnitude > 0 else { return nil }
            result.append(SplitComponent(
                categoryID: categoryID,
                amountMilliunits: -magnitude,
                memo: line.memo.isEmpty ? nil : line.memo
            ))
        }
        return result
    }

    static func lines(from components: [SplitComponent]?) -> [SplitDraftLine] {
        guard let components, !components.isEmpty else { return [SplitDraftLine(), SplitDraftLine()] }
        return components.map { component in
            var line = SplitDraftLine()
            line.categoryID = component.categoryID
            line.amountText = MoneyFormatting.editableString(-component.amountMilliunits)
            line.memo = component.memo ?? ""
            return line
        }
    }
}

/// Splits an existing outflow across categories, or edits its split. The
/// parent keeps its bank identity, amount, date, and payee (D3).
struct SplitTransactionSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let transactionID: TransactionID

    @State private var lines: [SplitDraftLine] = []

    private var row: TransactionRow? {
        model.snapshot?.transactions.first { $0.id == transactionID }
    }

    private var currency: String {
        guard let row, let account = model.snapshot?.accounts.first(where: { $0.id == row.accountID }) else {
            return model.budgetCurrency
        }
        return account.currency
    }

    private var totalMagnitude: Milliunits? {
        guard let row, row.amountMilliunits < 0 else { return nil }
        return -row.amountMilliunits
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(row?.isSplit == true ? "Edit Split" : "Split Transaction").font(.title3.bold())
            if let row {
                Text("\(model.payeeName(row.payeeID)) · \(row.date.description) · \(MoneyFormatting.string(row.amountMilliunits, currency: currency))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text("Allocate the total across categories. The transaction stays one bank event; only its budget allocation changes. Leave a line uncategorized by choosing Uncategorized to finish later.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SplitEditor(totalMagnitude: totalMagnitude, currency: currency, lines: $lines)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save Split") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(components == nil)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear { lines = SplitEditor.lines(from: row?.splits) }
    }

    private var components: [SplitComponent]? {
        guard let totalMagnitude else { return nil }
        return SplitEditor.components(lines, totalMagnitude: totalMagnitude)
    }

    private func save() {
        guard let components else { return }
        let id = transactionID
        let now = model.nowEpoch
        Task {
            let done: Bool? = await model.perform { workspace in
                try workspace.setSplits(transactionID: id, components: components, nowEpoch: now)
                return true
            }
            if done != nil { dismiss() }
        }
    }
}

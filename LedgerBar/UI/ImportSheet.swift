import AppKit
import LedgerCore
import SwiftUI
import UniformTypeIdentifiers

/// File import (docs/DESIGN.md D6): choose a file and target account, map
/// CSV columns (or accept the guessed mapping), review every row's duplicate
/// status and decision, then commit one audited batch. Nothing is written
/// until the final Import button.
struct ImportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let preselectedAccountID: AccountID?

    private enum Step { case pick, mapping, preview }

    @State private var step: Step = .pick
    @State private var fileURL: URL?
    @State private var fileData: Data?
    @State private var format: ImportFormat?
    @State private var accountID: AccountID?
    @State private var csvRows: [[String]] = []
    @State private var mapping: CSVImportMapping?
    @State private var mappingName = ""
    @State private var selectedMappingID: ImportMappingID?
    @State private var preview: [ImportPreviewRow] = []
    @State private var issues: [ImportIssue] = []
    @State private var errorText: String?
    @State private var working = false

    private var openAccounts: [AccountRow] {
        (model.snapshot?.accounts ?? []).filter { !$0.closed }.sorted { $0.name < $1.name }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Import Transactions").font(.title3.bold())
                Spacer()
                Text("Budget: \(model.snapshot?.budget.name ?? "")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            switch step {
            case .pick: pickStep
            case .mapping: mappingStep
            case .preview: previewStep
            }
            if let errorText {
                Text(errorText).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(20)
        .frame(width: 760, height: 580)
        .onAppear { accountID = preselectedAccountID ?? openAccounts.first?.id }
    }

    // MARK: Step 1

    private var pickStep: some View {
        Form {
            Picker("Into account", selection: $accountID) {
                ForEach(openAccounts, id: \.id) { Text($0.name).tag(Optional($0.id)) }
            }
            LabeledContent("File") {
                HStack {
                    Text(fileURL?.lastPathComponent ?? "No file chosen").foregroundStyle(fileURL == nil ? .secondary : .primary)
                    Button("Choose…") { chooseFile() }
                }
            }
            if let format {
                LabeledContent("Format") { Text(format.rawValue.uppercased()) }
            }
            Text("CSV, OFX, and QFX exports are supported. Rows are matched against existing transactions before anything is written: exact repeats are skipped and near matches are shown for you to decide.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.commaSeparatedText, UTType.plainText, UTType(filenameExtension: "ofx") ?? .data, UTType(filenameExtension: "qfx") ?? .data, .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        activateApp()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= 25_000_000 else { errorText = "That file is larger than 25 MB."; return }
            fileURL = url
            fileData = data
            format = ImportFormat.detect(fileName: url.lastPathComponent, data: data)
            errorText = format == nil ? "The file format could not be recognized. Use a .csv, .ofx, or .qfx export." : nil
            if format == .csv, let text = CSVParser.decode(data) {
                let delimiter = CSVParser.guessDelimiter(text)
                csvRows = CSVParser.parse(text, delimiter: delimiter)
                let header = csvRows.first ?? []
                let fingerprint = CSVImportMapping.headerFingerprint(header)
                if let saved = savedMappings.first(where: { $0.headerFingerprint == fingerprint }) {
                    mapping = saved.mapping
                    selectedMappingID = saved.id
                    mappingName = saved.name
                } else {
                    mapping = CSVParser.guessMapping(header: header, sampleRows: Array(csvRows.dropFirst().prefix(20)), delimiter: delimiter)
                        ?? CSVImportMapping(hasHeader: true, delimiter: delimiter, dateColumn: 0, dateFormat: "MM/dd/yyyy", amountLayout: .signed(column: 1), payeeColumn: 2)
                }
            }
        } catch {
            errorText = "The file could not be read."
        }
    }

    private var savedMappings: [ImportMappingRow] {
        (model.snapshot?.importMappings ?? []).sorted { $0.name < $1.name }
    }

    // MARK: Step 2 (CSV)

    @ViewBuilder
    private var mappingStep: some View {
        if let binding = Binding($mapping) {
            CSVMappingEditor(mapping: binding, rows: csvRows, savedMappings: savedMappings,
                             selectedMappingID: $selectedMappingID, mappingName: $mappingName)
        } else {
            Text("No mapping available.")
        }
    }

    // MARK: Step 3

    private var previewStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                statPill("\(preview.filter { $0.decision == .import }.count) to import", color: .green)
                statPill("\(preview.filter { if case .duplicate = $0.status { return true } else { return false } }.count) duplicates", color: .secondary)
                statPill("\(preview.filter { if case .possibleDuplicate = $0.status { return true } else { return false } }.count) possible duplicates", color: .orange)
                if !issues.isEmpty { statPill("\(issues.count) rows skipped (unreadable)", color: .red) }
                Spacer()
                if preview.contains(where: { if case .possibleDuplicate = $0.status { return true } else { return false } }) {
                    Button("Import all possible duplicates") {
                        for index in preview.indices {
                            if case .possibleDuplicate = preview[index].status { preview[index].decision = .import }
                        }
                    }
                    .controlSize(.small)
                }
            }
            Table(preview) {
                TableColumn("Import") { row in
                    Toggle("", isOn: Binding(
                        get: { row.decision == .import },
                        set: { on in
                            if let index = preview.firstIndex(where: { $0.id == row.id }) {
                                preview[index].decision = on ? .import : .skip
                            }
                        }
                    ))
                    .labelsHidden()
                    .disabled({ if case .duplicate = row.status { return true } else { return false } }())
                }
                .width(50)
                TableColumn("Date") { row in Text(row.row.date.description).monospacedDigit() }.width(90)
                TableColumn("Description") { row in Text(row.row.description) }
                TableColumn("Amount") { row in
                    Text(MoneyFormatting.string(row.row.amountMilliunits, currency: model.budgetCurrency))
                        .monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(100)
                TableColumn("Status") { row in statusText(row) }
                .width(min: 180)
            }
            if !issues.isEmpty {
                DisclosureGroup("Skipped rows (\(issues.count))") {
                    ForEach(issues) { issue in
                        Text("Line \(issue.lineNumber): \(issue.detail)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
            }
        }
    }

    private func statPill(_ text: String, color: Color) -> some View {
        Text(text).font(.caption).padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.15)))
    }

    @ViewBuilder
    private func statusText(_ row: ImportPreviewRow) -> some View {
        switch row.status {
        case .new:
            Text("New").foregroundStyle(.green)
        case let .duplicate(existing, reason):
            let why: String = {
                switch reason {
                case .externalID: return "same bank ID"
                case .fingerprint: return "already imported"
                case .withinFile: return "repeated in file"
                }
            }()
            Text("Duplicate · \(why)" + (existing.map { existingSummary($0) } ?? ""))
                .foregroundStyle(.secondary).font(.caption)
        case .possibleDuplicate(let candidates):
            Text("Possibly \(existingSummary(candidates[0]))").foregroundStyle(.orange).font(.caption)
        }
    }

    private func existingSummary(_ id: TransactionID) -> String {
        guard let row = model.snapshot?.transactions.first(where: { $0.id == id }) else { return "" }
        return " → \(row.date.description) \(model.payeeName(row.payeeID)) (\(row.sourceKind.rawValue))"
    }

    // MARK: Footer / navigation

    private var footer: some View {
        HStack {
            if step != .pick {
                Button("Back") { step = step == .preview && format == .csv ? .mapping : .pick; errorText = nil }
            }
            Spacer()
            Button("Cancel") { dismiss() }
            switch step {
            case .pick:
                Button(format == .csv ? "Next: Map Columns" : "Next: Preview") { advanceFromPick() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(fileData == nil || format == nil || accountID == nil)
            case .mapping:
                Button("Next: Preview") { buildPreview() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(mapping == nil)
            case .preview:
                Button(working ? "Importing…" : "Import \(preview.filter { $0.decision == .import }.count) Transactions") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || !preview.contains { $0.decision == .import })
            }
        }
    }

    private func advanceFromPick() {
        errorText = nil
        if format == .csv { step = .mapping } else { buildPreview() }
    }

    private func buildPreview() {
        guard let data = fileData, let format, let accountID, let snapshot = model.snapshot else { return }
        do {
            let records = try ImportPipeline.parse(data: data, format: format, csvMapping: mapping)
            let normalized = ImportPipeline.normalize(
                records, format: format, csvMapping: mapping,
                firstMonth: snapshot.budget.firstMonth, currentMonth: snapshot.budget.lastObservedBudgetMonth
            )
            issues = normalized.issues
            let workspace = try BudgetWorkspace(snapshot: snapshot)
            preview = workspace.classifyImportRows(normalized.rows, accountID: accountID)
            if normalized.rows.isEmpty {
                errorText = "No importable rows were found. Check the column mapping and date format."
                return
            }
            errorText = nil
            step = .preview
        } catch {
            errorText = model.friendlyMessage(error)
        }
    }

    private func commit() {
        guard let accountID, let format else { return }
        working = true
        let rows = preview
        let fileName = fileURL?.lastPathComponent ?? "import"
        let now = model.nowEpoch
        let saveMapping = format == .csv ? mapping : nil
        let saveName = mappingName.trimmingCharacters(in: .whitespaces)
        let header = csvRows.first ?? []
        Task {
            let summary: ImportBatchSummary? = await model.perform { workspace in
                let summary = try workspace.commitImportBatch(accountID: accountID, format: format, fileName: fileName, rows: rows, nowEpoch: now)
                if let saveMapping, !saveName.isEmpty {
                    _ = try workspace.saveImportMapping(
                        name: saveName, headerFingerprint: CSVImportMapping.headerFingerprint(header),
                        mapping: saveMapping, nowEpoch: now
                    )
                }
                return summary
            }
            working = false
            if let summary {
                var parts = ["Imported \(summary.importedCount) transaction(s); \(summary.skippedCount) skipped."]
                if summary.needsCategoryCount > 0 { parts.append("\(summary.needsCategoryCount) need a category.") }
                if summary.stagedCount > 0 { parts.append("\(summary.stagedCount) landed in a closed month and are staged.") }
                model.infoMessage = parts.joined(separator: " ")
                dismiss()
            }
        }
    }
}

/// CSV column mapping with a live sample of the first rows.
private struct CSVMappingEditor: View {
    @Binding var mapping: CSVImportMapping
    let rows: [[String]]
    let savedMappings: [ImportMappingRow]
    @Binding var selectedMappingID: ImportMappingID?
    @Binding var mappingName: String

    private enum Layout: String, CaseIterable, Identifiable {
        case signed = "One signed amount column"
        case debitCredit = "Separate debit and credit columns"
        case amountWithType = "Amount plus a type column"
        var id: String { rawValue }
    }

    private var header: [String] {
        guard let first = rows.first else { return [] }
        return first.enumerated().map { index, name in
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            return mapping.hasHeader && !trimmed.isEmpty ? "\(index + 1): \(trimmed)" : "Column \(index + 1)"
        }
    }

    private var layout: Layout {
        switch mapping.amountLayout {
        case .signed: return .signed
        case .debitCredit: return .debitCredit
        case .amountWithType: return .amountWithType
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Saved mapping", selection: $selectedMappingID) {
                    Text("None").tag(Optional<ImportMappingID>.none)
                    ForEach(savedMappings) { Text($0.name).tag(Optional($0.id)) }
                }
                .onChange(of: selectedMappingID) { _, newValue in
                    if let saved = savedMappings.first(where: { $0.id == newValue }) {
                        mapping = saved.mapping
                        mappingName = saved.name
                    }
                }
                TextField("Save this mapping as…", text: $mappingName).textFieldStyle(.roundedBorder).frame(width: 200)
            }
            Form {
                Toggle("First row is a header", isOn: $mapping.hasHeader)
                columnPicker("Date column", selection: $mapping.dateColumn)
                TextField("Date format", text: $mapping.dateFormat)
                    .help("Unicode pattern, e.g. MM/dd/yyyy, yyyy-MM-dd, dd.MM.yyyy")
                columnPicker("Payee / description column", selection: $mapping.payeeColumn)
                optionalColumnPicker("Memo column", selection: $mapping.memoColumn)
                optionalColumnPicker("Transaction ID column", selection: $mapping.externalIDColumn)
                Picker("Amount layout", selection: Binding(
                    get: { layout },
                    set: { newLayout in
                        switch newLayout {
                        case .signed: mapping.amountLayout = .signed(column: 0)
                        case .debitCredit: mapping.amountLayout = .debitCredit(debit: 0, credit: 1)
                        case .amountWithType: mapping.amountLayout = .amountWithType(amount: 0, type: 1, outflowValues: ["debit", "dr", "withdrawal"])
                        }
                    }
                )) {
                    ForEach(Layout.allCases) { Text($0.rawValue).tag($0) }
                }
                amountLayoutFields
                Toggle("Invert sign (file lists outflows as positive)", isOn: $mapping.invertSign)
                Picker("Decimal separator", selection: $mapping.decimalSeparator) {
                    Text(". (1,234.56)").tag(".")
                    Text(", (1.234,56)").tag(",")
                }
            }
            .formStyle(.grouped)
            Text("Sample (first rows)").font(.caption.weight(.semibold))
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                    ForEach(Array(rows.prefix(4).enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                Text(cell).font(.caption).lineLimit(1).frame(maxWidth: 160, alignment: .leading)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 90)
        }
    }

    @ViewBuilder
    private var amountLayoutFields: some View {
        switch mapping.amountLayout {
        case .signed(let column):
            columnPicker("Amount column", selection: Binding(get: { column }, set: { mapping.amountLayout = .signed(column: $0) }))
        case let .debitCredit(debit, credit):
            columnPicker("Debit (outflow) column", selection: Binding(get: { debit }, set: { mapping.amountLayout = .debitCredit(debit: $0, credit: credit) }))
            columnPicker("Credit (inflow) column", selection: Binding(get: { credit }, set: { mapping.amountLayout = .debitCredit(debit: debit, credit: $0) }))
        case let .amountWithType(amount, type, outflowValues):
            columnPicker("Amount column", selection: Binding(get: { amount }, set: { mapping.amountLayout = .amountWithType(amount: $0, type: type, outflowValues: outflowValues) }))
            columnPicker("Type column", selection: Binding(get: { type }, set: { mapping.amountLayout = .amountWithType(amount: amount, type: $0, outflowValues: outflowValues) }))
            TextField("Outflow values (comma separated)", text: Binding(
                get: { outflowValues.joined(separator: ", ") },
                set: { mapping.amountLayout = .amountWithType(amount: amount, type: type, outflowValues: $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }) }
            ))
        }
    }

    private func columnPicker(_ title: String, selection: Binding<Int>) -> some View {
        Picker(title, selection: selection) {
            ForEach(Array(header.enumerated()), id: \.offset) { index, name in Text(name).tag(index) }
        }
    }

    private func optionalColumnPicker(_ title: String, selection: Binding<Int?>) -> some View {
        Picker(title, selection: selection) {
            Text("None").tag(Optional<Int>.none)
            ForEach(Array(header.enumerated()), id: \.offset) { index, name in Text(name).tag(Optional(index)) }
        }
    }
}

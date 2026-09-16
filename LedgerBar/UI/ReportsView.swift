import Charts
import LedgerCore
import SwiftUI

/// Reports (docs/DESIGN.md D7): a configurable definition, evaluated by the
/// core engine and rendered with Swift Charts plus a table. Saved reports
/// are budget-scoped rows; presets are unsaved definitions.
struct ReportsView: View {
    @Environment(AppModel.self) private var model
    @State private var definition = ReportDefinition(kind: .spendingByCategory, range: .relative(.last12Months))
    @State private var selectedReportID: ReportID?
    @State private var showFilters = false
    @State private var showSaveAs = false
    @State private var saveName = ""
    @State private var renameTarget: ReportRow?
    @State private var drillRow: ReportTableRow?

    private var savedReports: [ReportRow] {
        (model.snapshot?.reports ?? []).sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) }
    }

    private var result: ReportResult? {
        guard let snapshot = model.snapshot else { return nil }
        return ReportEngine.evaluate(definition, snapshot: snapshot, projection: model.projection)
    }

    var body: some View {
        HSplitView {
            sidebar.frame(minWidth: 180, idealWidth: 200, maxWidth: 260)
            VStack(spacing: 0) {
                configurationBar
                Divider()
                if let result {
                    ReportContentView(result: result, currency: model.budgetCurrency, onDrill: { drillRow = $0 })
                } else {
                    ProgressView()
                }
            }
        }
        .navigationTitle(selectedReportID.flatMap { id in savedReports.first { $0.id == id }?.name } ?? "Reports")
        .toolbar { toolbarContent }
        .sheet(isPresented: $showSaveAs) { saveAsSheet }
        .sheet(item: $renameTarget) { report in
            ReportRenameSheet(report: report)
        }
        .sheet(item: $drillRow) { row in
            ReportDrillSheet(row: row, definition: definition)
        }
        .popover(isPresented: $showFilters) {
            ReportFiltersPopover(filters: $definition.filters)
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $selectedReportID) {
            Section("Presets") {
                ForEach(ReportKind.allCases, id: \.self) { kind in
                    Button {
                        selectedReportID = nil
                        definition = ReportDefinition(kind: kind, range: definition.range)
                    } label: {
                        Label(kind.title, systemImage: icon(for: kind))
                    }
                    .buttonStyle(.plain)
                }
            }
            Section("Saved") {
                if savedReports.isEmpty {
                    Text("Save a configured report to keep it here.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(savedReports) { report in
                    Text(report.name)
                        .tag(report.id)
                        .contextMenu {
                            Button("Rename…") { renameTarget = report }
                            Button("Duplicate") {
                                let now = model.nowEpoch
                                Task { await model.perform { try $0.duplicateReport(report.id, nowEpoch: now) } }
                            }
                            Divider()
                            Button("Delete", role: .destructive) {
                                Task { await model.perform { try $0.deleteReport(report.id) } }
                                if selectedReportID == report.id { selectedReportID = nil }
                            }
                        }
                }
            }
        }
        .onChange(of: selectedReportID) { _, newValue in
            if let report = savedReports.first(where: { $0.id == newValue }) {
                definition = report.definition
            }
        }
    }

    private func icon(for kind: ReportKind) -> String {
        switch kind {
        case .spendingByCategory: return "chart.bar"
        case .spendingByGroup: return "square.grid.2x2"
        case .spendingByPayee: return "storefront"
        case .spendingByAccount: return "creditcard"
        case .spendingOverTime: return "chart.bar.xaxis"
        case .incomeVsSpending: return "arrow.up.arrow.down"
        case .netWorth: return "chart.line.uptrend.xyaxis"
        case .budgetVsActual: return "target"
        }
    }

    // MARK: Configuration

    private var configurationBar: some View {
        HStack(spacing: 10) {
            Picker("Report", selection: $definition.kind) {
                ForEach(ReportKind.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .frame(maxWidth: 200)
            Picker("Range", selection: rangeBinding) {
                ForEach(RelativePeriod.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .frame(maxWidth: 160)
            if definition.kind.isTimeSeries {
                Picker("By", selection: $definition.granularity) {
                    ForEach(ReportGranularity.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .frame(maxWidth: 110)
            }
            Picker("Chart", selection: $definition.visualization) {
                ForEach(availableVisualizations, id: \.self) { Text($0.title).tag($0) }
            }
            .frame(maxWidth: 130)
            if definition.kind == .spendingOverTime || definition.kind == .netWorth {
                Toggle(definition.kind == .netWorth ? "By account" : "By category", isOn: $definition.breakdownByCategory)
                    .toggleStyle(.checkbox)
            }
            if !definition.kind.isTimeSeries || definition.kind == .spendingOverTime {
                Toggle("Compare previous", isOn: $definition.comparePreviousPeriod).toggleStyle(.checkbox)
            }
            Button {
                showFilters = true
            } label: {
                Label(filterSummary, systemImage: "line.3.horizontal.decrease.circle")
            }
            Spacer()
        }
        .padding(10)
        .onChange(of: definition.kind) { _, kind in
            if !availableVisualizations.contains(definition.visualization) { definition.visualization = kind.defaultVisualization }
        }
        .onChange(of: definition.breakdownByCategory) { _, _ in
            // The breakdown toggle changes the chart menu (bar ↔ stacked bar);
            // keep the selection inside it so the picker never shows blank.
            if !availableVisualizations.contains(definition.visualization) {
                definition.visualization = availableVisualizations.first ?? definition.kind.defaultVisualization
            }
        }
    }

    private var availableVisualizations: [ReportVisualization] {
        switch definition.kind {
        case .spendingByCategory, .spendingByGroup, .spendingByPayee, .spendingByAccount: return [.bar, .donut, .table]
        case .spendingOverTime: return definition.breakdownByCategory ? [.stackedBar, .line, .table] : [.bar, .line, .area, .table]
        case .incomeVsSpending, .budgetVsActual: return [.bar, .line, .table]
        case .netWorth: return [.line, .area, .bar, .table]
        }
    }

    private var rangeBinding: Binding<RelativePeriod> {
        Binding(
            get: { if case .relative(let period) = definition.range { return period } else { return .last12Months } },
            set: { definition.range = .relative($0) }
        )
    }

    private var filterSummary: String {
        var parts: [String] = []
        if let accounts = definition.filters.accountIDs { parts.append("\(accounts.count) account(s)") }
        if let categories = definition.filters.categoryIDs { parts.append("\(categories.count) categor(ies)") }
        if let groups = definition.filters.groupIDs { parts.append("\(groups.count) group(s)") }
        if let text = definition.filters.searchText, !text.isEmpty { parts.append("“\(text)”") }
        if definition.filters.includeStaged { parts.append("staged") }
        return parts.isEmpty ? "Filters" : parts.joined(separator: ", ")
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            if let id = selectedReportID, let saved = savedReports.first(where: { $0.id == id }), saved.definition != definition {
                Button("Save Changes") {
                    let now = model.nowEpoch
                    let current = definition
                    Task { await model.perform { try $0.updateReportDefinition(id, definition: current, nowEpoch: now) } }
                }
            }
            Button {
                saveName = selectedReportID.flatMap { id in savedReports.first { $0.id == id }?.name }.map { $0 + " copy" } ?? definition.kind.title
                showSaveAs = true
            } label: {
                Label("Save As…", systemImage: "square.and.arrow.down")
            }
        }
    }

    private var saveAsSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save Report").font(.title3.bold())
            Form { TextField("Name", text: $saveName) }.formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { showSaveAs = false }
                Button("Save") {
                    let name = saveName
                    let current = definition
                    let now = model.nowEpoch
                    Task {
                        let id: ReportID? = await model.perform { try $0.saveReport(name: name, definition: current, nowEpoch: now) }
                        if let id { selectedReportID = id; showSaveAs = false }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(saveName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

// MARK: - Content

struct ReportContentView: View {
    let result: ReportResult
    let currency: String
    var onDrill: ((ReportTableRow) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 18) {
                metric("Total", result.totalMilliunits)
                if let previous = result.previousTotalMilliunits {
                    metric(result.definition.kind == .budgetVsActual ? "Budgeted" : (result.definition.kind == .netWorth ? "Start" : "Previous"), previous)
                    let (delta, overflow) = result.totalMilliunits.subtractingReportingOverflow(previous)
                    if !overflow { metric("Change", delta, colorized: true) }
                }
                Spacer()
                Text("\(result.months.lowerBound.description) – \(result.months.upperBound.description)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            if result.definition.visualization != .table {
                ReportChart(result: result, currency: currency)
                    .frame(minHeight: 220, idealHeight: 260)
                    .padding(.horizontal, 12)
            }
            Table(result.rows) {
                TableColumn(result.definition.kind.isTimeSeries ? "Series" : "Item") { row in
                    Text(row.label)
                }
                TableColumn(result.definition.kind == .budgetVsActual ? "Spent" : "Amount") { row in
                    Text(MoneyFormatting.string(row.valueMilliunits, currency: currency))
                        .monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(110)
                TableColumn(result.definition.kind == .budgetVsActual ? "Budgeted" : "Previous") { row in
                    Text(row.previousValueMilliunits.map { MoneyFormatting.string($0, currency: currency) } ?? "")
                        .monospacedDigit().foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(110)
                TableColumn("Change") { row in
                    if let delta = row.deltaMilliunits, result.definition.kind != .budgetVsActual {
                        Text(MoneyFormatting.string(delta, currency: currency))
                            .monospacedDigit()
                            .foregroundStyle(delta > 0 ? .red : (delta < 0 ? .green : .secondary))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    } else if result.definition.kind == .budgetVsActual, let budgeted = row.previousValueMilliunits {
                        let (left, overflow) = budgeted.subtractingReportingOverflow(row.valueMilliunits)
                        Text(overflow ? "" : MoneyFormatting.string(left, currency: currency))
                            .monospacedDigit().foregroundStyle(left < 0 ? .red : .secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .width(110)
                TableColumn("Count") { row in
                    Text(row.count > 0 ? "\(row.count)" : "").foregroundStyle(.secondary)
                }
                .width(60)
                TableColumn("") { row in
                    if !row.lineIDs.isEmpty {
                        Button("Transactions") { onDrill?(row) }.controlSize(.small)
                    }
                }
                .width(110)
            }
            HStack {
                Text(result.semanticsNote).font(.caption2).foregroundStyle(.secondary)
                if !result.excludedAccountNames.isEmpty {
                    Text("Excluded (other currency): \(result.excludedAccountNames.joined(separator: ", "))")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }

    private func metric(_ title: String, _ amount: Milliunits, colorized: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(MoneyFormatting.string(amount, currency: currency))
                .font(.title3.weight(.semibold))
                .foregroundStyle(colorized ? (amount > 0 ? Color.red : (amount < 0 ? Color.green : Color.primary)) : Color.primary)
                .monospacedDigit()
        }
    }
}

/// Chart rendering with Swift Charts. Values are converted to Double only
/// for drawing; every number shown as text comes from milliunits.
struct ReportChart: View {
    let result: ReportResult
    let currency: String

    private struct Datum: Identifiable {
        let id: String
        let series: String
        let period: String
        let periodIndex: Int
        let value: Double
    }

    private var data: [Datum] {
        if result.definition.kind.isTimeSeries {
            return result.series.flatMap { series in
                series.points.map { point in
                    Datum(id: "\(series.key)-\(point.periodIndex)", series: series.label,
                          period: result.periods.indices.contains(point.periodIndex) ? result.periods[point.periodIndex].label : "",
                          periodIndex: point.periodIndex, value: Double(point.valueMilliunits) / 1000)
                }
            }
        }
        return result.rows.enumerated().map { index, row in
            Datum(id: row.key, series: row.label, period: row.label, periodIndex: index, value: Double(row.valueMilliunits) / 1000)
        }
    }

    var body: some View {
        let visualization = result.definition.visualization
        Chart(data) { datum in
            switch visualization {
            case .line:
                LineMark(x: .value("Period", datum.period), y: .value("Amount", datum.value))
                    .foregroundStyle(by: .value("Series", datum.series))
                    .symbol(by: .value("Series", datum.series))
            case .area:
                AreaMark(x: .value("Period", datum.period), y: .value("Amount", datum.value))
                    .foregroundStyle(by: .value("Series", datum.series))
                    .opacity(0.6)
            case .donut:
                SectorMark(angle: .value("Amount", max(datum.value, 0)), innerRadius: .ratio(0.55), angularInset: 1)
                    .foregroundStyle(by: .value("Item", datum.series))
            case .stackedBar:
                BarMark(x: .value("Period", datum.period), y: .value("Amount", datum.value))
                    .foregroundStyle(by: .value("Series", datum.series))
            case .bar, .table:
                if result.definition.kind.isTimeSeries {
                    BarMark(x: .value("Period", datum.period), y: .value("Amount", datum.value))
                        .foregroundStyle(by: .value("Series", datum.series))
                        .position(by: .value("Series", datum.series))
                } else {
                    BarMark(x: .value("Amount", datum.value), y: .value("Item", datum.period))
                        .foregroundStyle(.tint)
                }
            }
        }
        .chartXAxis(visualization == .donut ? .hidden : .automatic)
        .chartYAxis(visualization == .donut ? .hidden : .automatic)
        .chartLegend(result.series.count > 1 || visualization == .donut ? .visible : .hidden)
        .accessibilityLabel("\(result.title) chart")
    }
}

struct ReportRenameSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let report: ReportRow
    @State private var name: String

    init(report: ReportRow) {
        self.report = report
        _name = State(initialValue: report.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Report").font(.title3.bold())
            Form { TextField("Name", text: $name) }.formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Rename") {
                    let newName = name
                    let now = model.nowEpoch
                    Task {
                        let done: Bool? = await model.perform { try $0.renameReport(report.id, to: newName, nowEpoch: now); return true }
                        if done != nil { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

/// Provenance: the transactions behind one report row.
struct ReportDrillSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let row: ReportTableRow
    let definition: ReportDefinition

    private var lines: [CategoryLine] {
        guard let snapshot = model.snapshot else { return [] }
        let ids = Set(row.lineIDs)
        return snapshot.categoryLines().filter { ids.contains($0.id) }.sorted { $0.date > $1.date }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(row.label): \(MoneyFormatting.string(row.valueMilliunits, currency: model.budgetCurrency))").font(.title3.bold())
            Text("\(lines.count) contributing line(s)" + (row.lineIDs.count >= 500 ? " (first 500 shown)" : "")).font(.caption).foregroundStyle(.secondary)
            Table(lines) {
                TableColumn("Date") { Text($0.date.description).monospacedDigit() }.width(90)
                TableColumn("Account") { line in Text(model.accountName(line.accountID)) }
                TableColumn("Payee") { line in Text(model.payeeName(line.payeeID)) }
                TableColumn("Category") { line in Text(model.categoryName(line.categoryID)) }
                TableColumn("Amount") { line in
                    Text(MoneyFormatting.string(line.amountMilliunits, currency: model.budgetCurrency))
                        .monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(100)
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .frame(width: 720, height: 460)
    }
}

/// Filter editor for a report definition.
struct ReportFiltersPopover: View {
    @Environment(AppModel.self) private var model
    @Binding var filters: ReportFilters
    @State private var searchText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Filters").font(.headline)
            Form {
                Section("Accounts") {
                    ForEach((model.snapshot?.accounts ?? []).sorted { $0.name < $1.name }, id: \.id) { account in
                        Toggle(account.name, isOn: setBinding(\.accountIDs, account.id))
                    }
                }
                Section("Category groups") {
                    ForEach((model.snapshot?.categoryGroups ?? []).filter { !$0.hidden }.sorted { $0.sortOrder < $1.sortOrder }, id: \.id) { group in
                        Toggle(group.name, isOn: setBinding(\.groupIDs, group.id))
                    }
                }
                Section("Categories") {
                    ForEach((model.snapshot?.categories ?? []).filter { $0.kind == .spending && !$0.hidden && $0.systemKind == nil }.sorted { $0.name < $1.name }, id: \.id) { category in
                        Toggle(category.name, isOn: setBinding(\.categoryIDs, category.id))
                    }
                }
                Section("Text") {
                    TextField("Payee, memo, or imported description contains", text: $searchText)
                        .onSubmit { filters.searchText = searchText.isEmpty ? nil : searchText }
                }
                Section("Semantics") {
                    Toggle("Include staged rows", isOn: $filters.includeStaged)
                    Toggle("Count openings and adjustments as income", isOn: $filters.includeOpeningsAndAdjustmentsAsIncome)
                    Toggle("Only approved transactions", isOn: $filters.onlyApproved)
                }
            }
            .formStyle(.grouped)
            HStack {
                Button("Clear All") { filters = ReportFilters(); searchText = "" }
                Spacer()
            }
        }
        .padding(14)
        .frame(width: 360, height: 520)
        .onAppear { searchText = filters.searchText ?? "" }
    }

    /// A toggle over an optional set filter: nil means "all"; turning any
    /// item on narrows to the checked set; turning the last one off clears.
    private func setBinding<ID: Hashable>(_ keyPath: WritableKeyPath<ReportFilters, Set<ID>?>, _ id: ID) -> Binding<Bool> {
        Binding(
            get: { filters[keyPath: keyPath]?.contains(id) ?? false },
            set: { on in
                var set = filters[keyPath: keyPath] ?? []
                if on { set.insert(id) } else { set.remove(id) }
                filters[keyPath: keyPath] = set.isEmpty ? nil : set
            }
        )
    }
}

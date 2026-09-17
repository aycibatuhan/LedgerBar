import LedgerCore
import SwiftUI

/// Ask LedgerBar (docs/LOCAL-AI.md A14): a private, local conversation
/// over the active budget. Every number comes from a tool call whose
/// results are inspectable under "Sources"; proposals need an explicit
/// Apply.
struct AssistantView: View {
    @Environment(\.openSettings) private var openSettings
    @Environment(AppModel.self) private var model
    @State private var question = ""
    @State private var showSettingsHint = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if model.assistantTurns.isEmpty && model.assistantLive == nil {
                            emptyState
                        }
                        ForEach(model.assistantTurns) { turn in
                            turnView(turn)
                                .id(turn.id)
                        }
                        if let live = model.assistantLive {
                            liveView(live).id("live")
                        }
                    }
                    .padding(16)
                }
                .onChange(of: model.assistantTurns.count) { _, _ in
                    withAnimation { proxy.scrollTo(model.assistantTurns.last?.id, anchor: .bottom) }
                }
                .onChange(of: model.assistantLive?.tokens) { _, _ in
                    proxy.scrollTo("live", anchor: .bottom)
                }
            }
            Divider()
            inputBar
        }
        .sheet(item: Binding(get: { model.assistantDrill }, set: { model.assistantDrill = $0 })) { drill in
            AssistantProvenanceSheet(result: drill)
        }
        .navigationTitle("Ask LedgerBar")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    Task { await model.clearAssistantHistory() }
                } label: { Label("Clear Conversation", systemImage: "trash") }
                    .disabled(model.assistantTurns.isEmpty)
                Button {
                    bringWindowToFront(matching: isSettingsWindow) { openSettings() }
                } label: { Label("Assistant Settings", systemImage: "gearshape") }
            }
        }
        .onAppear {
            inputFocused = true
            if let prefill = model.assistantPrefill { question = prefill; model.assistantPrefill = nil }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield").foregroundStyle(.green)
            Text(model.assistantStatusLine).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text("Budget: \(model.snapshot?.budget.name ?? "")").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ask about your money. Everything is answered from this budget's own ledger, on this Mac.")
                .font(.callout)
            Text("Try:").font(.caption).foregroundStyle(.secondary)
            ForEach(["How much did I spend on groceries last month?", "Compare dining this year with last year", "What subscriptions am I paying for?", "What is due next week?", "Graph my spending by month for the last 6 months", "What transactions are still uncategorized?"], id: \.self) { sample in
                Button(sample) { question = sample; submit() }
                    .buttonStyle(.link)
                    .font(.callout)
            }
        }
        .padding(.bottom, 8)
    }

    private func turnView(_ turn: AssistantTurn) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Image(systemName: "person.circle").foregroundStyle(.secondary)
                Text(turn.question).textSelection(.enabled)
            }
            HStack(alignment: .top) {
                Image(systemName: "sparkles").foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 8) {
                    Text(turn.answer).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    ForEach(Array(turn.toolResults.enumerated()), id: \.offset) { _, result in
                        if let definition = result.reportDefinition, let snapshot = model.snapshot {
                            ReportContentView(result: ReportEngine.evaluate(definition, snapshot: snapshot, projection: model.projection), currency: model.budgetCurrency)
                                .frame(minHeight: 320)
                                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                        }
                        if let proposal = result.proposal {
                            ProposalCard(action: proposal)
                        }
                    }
                    if !turn.toolResults.isEmpty {
                        DisclosureGroup {
                            ForEach(Array(turn.toolResults.enumerated()), id: \.offset) { _, result in
                                sourceRow(result)
                            }
                        } label: {
                            Text("Sources · \(turn.toolResults.count) tool call(s)" + (turn.usedModel.map { " · \($0)" } ?? " · structured answer"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private func liveView(_ live: AssistantLiveState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Image(systemName: "person.circle").foregroundStyle(.secondary)
                Text(live.question)
            }
            HStack(alignment: .top) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 4) {
                    if !live.status.isEmpty { Text(live.status).font(.caption).foregroundStyle(.secondary) }
                    ForEach(live.calls, id: \.id) { call in
                        Text("→ \(call.name)").font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    if !live.tokens.isEmpty { Text(live.tokens).fixedSize(horizontal: false, vertical: true) }
                }
            }
            Button("Cancel") { model.cancelAssistant() }.controlSize(.small)
        }
        .padding(12)
        .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 10))
    }

    private func sourceRow(_ result: AssistantToolResult) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(result.name).font(.caption.monospaced())
                if let error = result.error { Text(error.message).font(.caption).foregroundStyle(.red) }
                if result.truncated { Text("truncated").font(.caption2).foregroundStyle(.orange) }
                Spacer()
                if !result.provenanceLineIDs.isEmpty {
                    Button("Show \(result.provenanceLineIDs.count) transaction(s)") { model.assistantDrill = result }
                        .controlSize(.small)
                }
            }
            Text(result.payload.serialized(pretty: true).prefix(1_200) + (result.payload.serialized().count > 1_200 ? "…" : ""))
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(14)
        }
        .padding(6)
    }

    private var inputBar: some View {
        HStack {
            TextField("Ask about your budget…", text: $question, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .focused($inputFocused)
                .onSubmit { submit() }
                .accessibilityIdentifier("ledgerbar.assistant.input")
            Button("Ask") { submit() }
                .keyboardShortcut(.defaultAction)
                .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty || model.assistantLive != nil)
        }
        .padding(10)
    }

    private func submit() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        question = ""
        Task { await model.askAssistant(text) }
    }
}

/// A drafted change with its dry-run preview and an explicit Apply (A4).
struct ProposalCard: View {
    @Environment(AppModel.self) private var model
    let action: ProposedAction
    @State private var applied = false

    private var preview: ProposalPreview? {
        guard let snapshot = model.snapshot, let workspace = try? BudgetWorkspace(snapshot: snapshot) else { return nil }
        return workspace.previewProposal(action)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(action.title, systemImage: action.isModification ? "pencil.and.outline" : "doc.badge.plus").font(.headline)
            if let preview {
                ForEach(preview.lines, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                if let error = preview.error {
                    Text("Cannot apply: \(error)").font(.caption).foregroundStyle(.red)
                }
            }
            HStack {
                if applied {
                    Label("Applied", systemImage: "checkmark.circle").foregroundStyle(.green).font(.caption)
                } else {
                    Button(action.isModification ? "Apply Change" : "Save") {
                        Task {
                            if await model.applyProposal(action) { applied = true }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(preview?.isApplicable != true)
                    Text(action.isModification ? "Nothing changes until you apply. The change goes through the same checks as manual edits." : "")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// The category lines behind one tool result (A7 explainability).
struct AssistantProvenanceSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let result: AssistantToolResult

    private var lines: [CategoryLine] {
        guard let snapshot = model.snapshot else { return [] }
        let ids = Set(result.provenanceLineIDs)
        return snapshot.categoryLines().filter { ids.contains($0.id) }.sorted { $0.date > $1.date }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Transactions behind “\(result.name)”").font(.title3.bold())
            Table(lines) {
                TableColumn("Date") { Text($0.date.description).monospacedDigit() }.width(90)
                TableColumn("Account") { line in Text(model.accountName(line.accountID)) }
                TableColumn("Payee") { line in Text(model.payeeName(line.payeeID)) }
                TableColumn("Category") { line in Text(model.categoryName(line.categoryID)) }
                TableColumn("Amount") { line in
                    Text(MoneyFormatting.string(line.amountMilliunits, currency: model.budgetCurrency)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(100)
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .frame(width: 720, height: 440)
    }
}

/// Settings → Assistant (A12/A14).
struct AssistantSettingsPane: View {
    @Environment(AppModel.self) private var model
    @State private var settings = AssistantSettings()
    @State private var models: [LocalModelInfo] = []
    @State private var probing = false
    @State private var probeMessage: String?
    @State private var showAdvanced = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Assistant").font(.title3.bold())
                Text("Questions are answered on this Mac from this budget's ledger. LedgerBar only talks to a model server on this computer (127.0.0.1 / localhost); a remote address is refused. No question, transaction, or answer leaves the machine.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Form {
                    Toggle("Enable Ask LedgerBar", isOn: $settings.enabled)
                    Picker("Runtime", selection: $settings.runtimeKind) {
                        ForEach(LocalRuntimeKind.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    if settings.runtimeKind != .none {
                        TextField("Local endpoint", text: $settings.endpoint)
                            .help("Must be a loopback address such as http://127.0.0.1:11434")
                        HStack {
                            Picker("Model", selection: $settings.model) {
                                Text(settings.model.isEmpty ? "Choose…" : settings.model).tag(settings.model)
                                ForEach(models.filter { $0.name != settings.model }) { info in
                                    Text(info.name + (info.supportsTools == true ? " (tools)" : "")).tag(info.name)
                                }
                            }
                            Button(probing ? "Checking…" : "Check Server") { Task { await probe() } }.disabled(probing)
                        }
                        if let probeMessage { Text(probeMessage).font(.caption).foregroundStyle(.secondary) }
                    } else {
                        Text("Without a model, Ask LedgerBar still answers common questions (totals, comparisons, uncategorized, upcoming) with fixed, structured logic.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle("Save conversation history in the local database", isOn: $settings.saveHistory)
                    DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                        Stepper("Keep model loaded for \(settings.keepAliveSeconds) s after a question", value: $settings.keepAliveSeconds, in: 0...3600, step: 60)
                        Stepper("Max answer tokens: \(settings.maxTokens)", value: $settings.maxTokens, in: 256...8192, step: 256)
                        Stepper("Max tool rounds per question: \(settings.maxToolRounds)", value: $settings.maxToolRounds, in: 1...16)
                        HStack { Text("Temperature"); Slider(value: $settings.temperature, in: 0...1); Text(String(format: "%.1f", settings.temperature)).monospacedDigit() }
                    }
                }
                .formStyle(.grouped)
                HStack {
                    Button("Save Settings") { Task { await model.saveAssistantSettings(settings) } }
                        .buttonStyle(.borderedProminent)
                    Button("Clear Conversation History") { Task { await model.clearAssistantHistory() } }
                    Button("Unload Model Now") { Task { await model.unloadAssistantModel() } }
                        .disabled(settings.runtimeKind == .none || settings.model.isEmpty)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Storage").font(.headline)
                    Text("Conversation history (if enabled): the LedgerBar database, per budget. Model files: managed by the runtime you chose (for Ollama, ~/.ollama/models). LedgerBar downloads nothing.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(20)
        }
        .onAppear { settings = model.assistantSettings }
    }

    private func probe() async {
        probing = true
        defer { probing = false }
        do {
            guard let runtime = try settings.makeRuntime() else { probeMessage = "No runtime selected."; return }
            let found = try await runtime.listModels()
            models = found
            let toolCapable = found.filter { $0.supportsTools == true }.map(\.name)
            probeMessage = found.isEmpty
                ? "Server reachable, but no models are installed. Pull one with the runtime (e.g. `ollama pull llama3.1`)."
                : "Server reachable: \(found.count) model(s)." + (toolCapable.isEmpty ? " None report tool calling; the assistant will use the JSON fallback." : " Tool-capable: \(toolCapable.joined(separator: ", ")).")
            if settings.model.isEmpty, let first = toolCapable.first ?? found.first?.name { settings.model = first }
        } catch let error as LocalEndpointError {
            switch error {
            case .notLoopback(let host): probeMessage = "Refused: \(host) is not a local address. Only 127.0.0.1, ::1, or localhost are allowed."
            case .invalidURL: probeMessage = "Enter a valid http://127.0.0.1:PORT address."
            }
        } catch {
            probeMessage = "The local server did not respond (\(error))."
        }
    }
}

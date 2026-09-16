import Foundation
import LedgerCore
import Observation

/// Live state of an in-flight assistant question, for the UI.
struct AssistantLiveState: Equatable {
    var question: String
    var status: String = ""
    var tokens: String = ""
    var calls: [AssistantToolCall] = []
}

extension AppModel {

    // MARK: - Settings (docs/LOCAL-AI.md A12)

    func loadAssistantSettings() async {
        if let raw = try? await service.appSetting(AssistantSettings.settingKey),
           let decoded = try? JSONDecoder().decode(AssistantSettings.self, from: Data(raw.utf8)) {
            assistantSettings = decoded
        }
        assistantSession = nil
    }

    func saveAssistantSettings(_ settings: AssistantSettings) async {
        // Refuse a non-loopback endpoint before it is ever stored.
        if settings.runtimeKind != .none {
            do { _ = try LocalEndpointPolicy.validate(settings.endpoint) } catch {
                actionError = "Only a local endpoint (127.0.0.1, ::1, or localhost) can be used."
                return
            }
        }
        do {
            let data = try JSONEncoder().encode(settings)
            try await service.setAppSetting(AssistantSettings.settingKey, value: String(decoding: data, as: UTF8.self), nowEpoch: nowEpoch)
            assistantSettings = settings
            assistantSession = nil
            if !settings.saveHistory, let budgetID = snapshot?.budget.id {
                try await service.saveAssistantTranscript(nil, budgetID: budgetID, nowEpoch: nowEpoch)
            }
            infoMessage = "Assistant settings saved."
        } catch {
            actionError = friendlyMessage(error)
        }
    }

    var assistantStatusLine: String {
        guard assistantSettings.enabled else { return "Assistant disabled — enable it in Settings → Assistant." }
        switch assistantSettings.runtimeKind {
        case .none: return "Local only · structured answers (no model configured)"
        case .ollama, .openAICompatible:
            let model = assistantSettings.model.isEmpty ? "no model chosen" : assistantSettings.model
            return "Local only · \(assistantSettings.runtimeKind == .ollama ? "Ollama" : "local server") · \(model) · \(assistantSettings.endpoint)"
        }
    }

    // MARK: - Session lifecycle

    private func session(for budgetID: BudgetID) async -> AssistantSession {
        if let existing = assistantSession, assistantSessionBudgetID == budgetID { return existing }
        let runtime = try? assistantSettings.makeRuntime()
        let transcript = assistantSettings.saveHistory ? try? await service.loadAssistantTranscript(budgetID: budgetID) : nil
        let created = AssistantSession(runtime: runtime, settings: assistantSettings, transcript: transcript)
        assistantSession = created
        assistantSessionBudgetID = budgetID
        assistantTurns = await created.turns
        return created
    }

    func askAssistant(_ question: String) async {
        guard assistantSettings.enabled else {
            actionError = "Enable the assistant in Settings → Assistant first."
            return
        }
        guard let snapshot, assistantLive == nil else { return }
        guard let calendar = try? BudgetCalendar(timeZoneIdentifier: snapshot.budget.timeZoneIdentifier),
              let today = calendar.budgetDate(fromEpoch: nowEpoch) else { return }
        let session = await session(for: snapshot.budget.id)
        assistantLive = AssistantLiveState(question: question)
        let projection = self.projection
        let now = nowEpoch
        let task = Task { @MainActor in
            for await event in await session.ask(question, snapshot: snapshot, projection: projection, today: today, nowEpoch: now) {
                switch event {
                case .status(let text): assistantLive?.status = text
                case .token(let token): assistantLive?.tokens += token
                case .toolCall(let call): assistantLive?.calls.append(call)
                case .toolResult: break
                case .answer: break
                case .failed(let reason): actionError = reason
                case .done: break
                }
            }
            assistantTurns = await session.turns
            assistantLive = nil
            if assistantSettings.saveHistory {
                try? await service.saveAssistantTranscript(await session.transcript(budgetID: snapshot.budget.id), budgetID: snapshot.budget.id, nowEpoch: now)
            }
        }
        assistantTask = task
        await task.value
        assistantTask = nil
    }

    func cancelAssistant() {
        assistantTask?.cancel()
        assistantTask = nil
        assistantLive = nil
    }

    func clearAssistantHistory() async {
        if let session = assistantSession { await session.clearHistory() }
        assistantTurns = []
        if let budgetID = snapshot?.budget.id {
            try? await service.saveAssistantTranscript(nil, budgetID: budgetID, nowEpoch: nowEpoch)
        }
    }

    func unloadAssistantModel() async {
        guard let runtime = try? assistantSettings.makeRuntime() else { return }
        await runtime.unload(model: assistantSettings.model)
        infoMessage = "Asked the local runtime to unload \(assistantSettings.model)."
    }

    /// Applies a drafted change after the user confirmed it (A4). Goes
    /// through `perform`, so validation, replay, and audit are the same as
    /// for a manual edit.
    func applyProposal(_ action: ProposedAction) async -> Bool {
        let now = nowEpoch
        let done: Bool? = await perform { workspace in
            try workspace.applyProposal(action, nowEpoch: now)
            return true
        }
        if done != nil { infoMessage = "\(action.title): applied." }
        return done != nil
    }

    /// Called on budget switch so no conversation crosses budgets.
    func resetAssistantForBudgetChange() {
        cancelAssistant()
        assistantSession = nil
        assistantSessionBudgetID = nil
        assistantTurns = []
    }
}

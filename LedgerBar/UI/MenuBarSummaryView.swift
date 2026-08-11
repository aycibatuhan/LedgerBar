import AppKit
import LedgerCore
import SwiftUI

/// §5.1: intentionally read-only menu-bar popover. Shows current-month RTA,
/// assigned, activity, needs-category/staged counts, sync state, and the two
/// actions (“Sync Now”, “Open LedgerBar”, Settings, Quit).
struct MenuBarSummaryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let snapshot = model.snapshot,
               let month = model.projection?.month(snapshot.budget.lastObservedBudgetMonth) {
                let currency = snapshot.budget.currency
                Text(MoneyFormatting.monthTitle(month.month))
                    .font(.headline)
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    summaryRow("Ready to Assign", month.rtaEnd, currency, emphasize: true)
                    summaryRow("Assigned", month.totalAssigned, currency)
                    summaryRow("Activity", monthActivity(month), currency)
                }
                HStack(spacing: 12) {
                    Label("\(model.needsCategoryCount) need a category", systemImage: "questionmark.circle")
                    Label("\(model.stagedCount) staged", systemImage: "tray.full")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Divider()
                syncStatus
            } else if model.phase == .onboarding {
                Text("Welcome to LedgerBar")
                    .font(.headline)
                Text("Open the app to create your first budget.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if case .failed(let message) = model.phase {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
            } else {
                ProgressView().controlSize(.small)
            }

            Divider()
            HStack {
                Button("Sync Now") {
                    Task { await model.syncNow() }
                }
                .disabled(model.syncing || model.simplefin?.activeCredentialPin == nil)
                Spacer()
                Button("Open LedgerBar") {
                    openWindow(id: "main")
                    activateApp()
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("ledgerbar.open-window")
                SettingsLink {
                    Image(systemName: "gearshape")
                }
                .help("Open Settings")
                .accessibilityLabel("Open Settings")
                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Image(systemName: "power")
                }
                .help("Quit LedgerBar")
                .accessibilityLabel("Quit LedgerBar")
            }
        }
        .padding(14)
        .frame(width: 320)
        .task { await model.bootstrapIfNeeded() }
    }

    @ViewBuilder
    private var syncStatus: some View {
        VStack(alignment: .leading, spacing: 2) {
            if model.syncing {
                Label("Syncing…", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
            } else if let state = model.simplefin {
                if let last = state.lastSuccessfulSyncAtEpoch {
                    Text("Last sync: \(Date(timeIntervalSince1970: TimeInterval(last)).formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if state.credentialDisconnectPending {
                    Text("SimpleFIN disconnect pending")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if state.credentialAuthorizationRevoked {
                    Text("SimpleFIN reconnect required")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text(state.status == .active ? "Connected — not yet synced" : "SimpleFIN disconnected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let error = state.lastErrorRedacted {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(3)
                }
            } else {
                Text("SimpleFIN not connected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let summary = model.lastSyncSummary {
                Text(summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
    }

    private func summaryRow(_ title: String, _ amount: Milliunits, _ currency: String, emphasize: Bool = false) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(emphasize ? .primary : .secondary)
            Text(MoneyFormatting.string(amount, currency: currency))
                .fontWeight(emphasize ? .semibold : .regular)
                .foregroundStyle(amount < 0 ? Color.red : (emphasize ? Color.green : Color.primary))
                .gridColumnAlignment(.trailing)
        }
        .font(emphasize ? .body : .callout)
    }

    private func monthActivity(_ month: MonthSnapshot) -> Milliunits {
        // Signed direct+synthetic activity across spending and payment
        // categories, for display only (checked arithmetic guards the engine;
        // the popover clamps rather than crashing on display overflow).
        var total: Milliunits = 0
        for snapshot in month.categories.values {
            let (sum, overflow) = total.addingReportingOverflow(snapshot.activity)
            if overflow { return total }
            total = sum
        }
        for snapshot in month.payments.values {
            let (sum, overflow) = total.addingReportingOverflow(snapshot.activity)
            if overflow { return total }
            total = sum
        }
        return total
    }
}

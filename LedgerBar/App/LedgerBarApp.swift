import AppKit
import LedgerCore
import SwiftUI

/// Native macOS menu-bar budgeting app (§5). The menu-bar popover is a
/// read-only summary; the full window is a `NavigationSplitView`. All budget
/// writes flow through the single `BudgetMutationService` actor.
@main
struct LedgerBarApp: App {
    @State private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    init() {
        do {
            _model = State(initialValue: try AppModel.production())
        } catch {
            _model = State(initialValue: AppModel.failed(message: "The local database could not be opened."))
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarSummaryView()
                .environment(model)
        } label: {
            Image(nsImage: BrandGlyph.menuBarImage)
        }
        .menuBarExtraStyle(.window)

        Window("LedgerBar", id: "main") {
            MainWindowView()
                .environment(model)
                .task { await model.bootstrapIfNeeded() }
                .frame(minWidth: 900, minHeight: 560)
        }

        Settings {
            SettingsView()
                .environment(model)
                .task { await model.bootstrapIfNeeded() }
        }
    }
}

/// Brings the full window forward from the menu-bar popover using the current
/// activation API (§5.1; the deprecated `activate(ignoringOtherApps:)` is
/// intentionally not used).
@MainActor
func activateApp() {
    NSApplication.shared.activate()
}

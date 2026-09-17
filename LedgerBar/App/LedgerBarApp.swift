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

/// Opens (or re-focuses) a window and makes sure it ends up in front. Opening
/// from the menu-bar popover does not activate the app on its own, so a window
/// that was already open would otherwise stay behind other apps. The window is
/// looked up after the open request has been processed, un-minimized if
/// needed, and ordered front.
@MainActor
func bringWindowToFront(matching isTarget: @escaping @MainActor (NSWindow) -> Bool, open: () -> Void) {
    NSApplication.shared.activate()
    open()
    func raise() {
        for window in NSApplication.shared.windows where isTarget(window) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }
    DispatchQueue.main.async { raise() }
    // A newly created window may appear a runloop turn later.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { raise() }
}

@MainActor
func isSettingsWindow(_ window: NSWindow) -> Bool {
    window.identifier?.rawValue == "com_apple_SwiftUI_Settings_window"
}

@MainActor
func isMainWindow(_ window: NSWindow) -> Bool {
    window.identifier?.rawValue == "main" || window.identifier?.rawValue.hasPrefix("main-") == true
}

import XCTest

final class LedgerBarUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testMenuBarOpensOnboardingAndCreatesLocalBudget() throws {
        let app = XCUIApplication()
        // Relative overrides are resolved inside the app's sandboxed
        // Application Support directory by AppModel.production().
        app.launchEnvironment["LEDGERBAR_DB_PATH"] =
            "LedgerBar/UITests/\(UUID().uuidString).sqlite"
        app.launch()
        defer { app.terminate() }

        // LedgerBar is intentionally LSUIElement/menu-bar-only. Open the
        // read-only menu-bar popover, then use its documented Open LedgerBar
        // action to bring the native Window scene forward.
        let statusItem = app.menuBars.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: 10), "LedgerBar menu-bar item did not appear")
        statusItem.click()

        let openLedgerBar = app.buttons["ledgerbar.open-window"]
        XCTAssertTrue(openLedgerBar.waitForExistence(timeout: 5), "Open LedgerBar action did not appear")
        openLedgerBar.click()

        let onboardingTitle = app.staticTexts["Create your first budget"]
        XCTAssertTrue(onboardingTitle.waitForExistence(timeout: 10), "Onboarding window did not appear")
        XCTAssertTrue(app.textFields["ledgerbar.onboarding.currency"].exists)
        let createBudget = app.buttons["ledgerbar.onboarding.create-budget"]
        XCTAssertTrue(createBudget.isEnabled)

        createBudget.click()

        XCTAssertTrue(app.staticTexts["Budget"].waitForExistence(timeout: 10), "Budget view did not appear")
        XCTAssertTrue(app.staticTexts["All Accounts"].exists)
        XCTAssertTrue(app.buttons["ledgerbar.add-account"].exists)
    }
}

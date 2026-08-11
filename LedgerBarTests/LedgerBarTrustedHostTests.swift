import Foundation
import XCTest
@testable import LedgerBar
import LedgerCore

@MainActor
final class LedgerBarTrustedHostTests: XCTestCase {
    func testExplicitTrustedHostPersistsBeforeFirstClaim() async throws {
        let store = try LedgerWorkspaceStore.inMemory()
        let model = AppModel(
            store: store,
            credentials: InMemorySimpleFINCredentialStore()
        )
        await model.createBudget(
            currency: "USD",
            timeZoneIdentifier: "UTC",
            firstMonth: BudgetMonth(string: "2025-01")!
        )
        let betaHost = try SimpleFINHost(host: "beta-bridge.simplefin.org")

        try await model.rememberTrustedHost(betaHost)

        XCTAssertEqual(model.simplefin?.status, .disconnected)
        XCTAssertEqual(model.simplefin?.extraTrustedHosts, [betaHost])
    }

    func testTrustedHostConfirmationBootstrapsBudgetWhenSettingsOpenFirst() async throws {
        let store = try LedgerWorkspaceStore.inMemory()
        let creator = AppModel(
            store: store,
            credentials: InMemorySimpleFINCredentialStore()
        )
        await creator.createBudget(
            currency: "USD",
            timeZoneIdentifier: "UTC",
            firstMonth: BudgetMonth(string: "2025-01")!
        )

        // A Settings scene can be opened without the main Window scene having
        // bootstrapped this new AppModel instance first.
        let settingsModel = AppModel(
            store: store,
            credentials: InMemorySimpleFINCredentialStore()
        )
        let betaHost = try SimpleFINHost(host: "beta-bridge.simplefin.org")

        try await settingsModel.rememberTrustedHost(betaHost)

        XCTAssertEqual(settingsModel.phase, .ready)
        XCTAssertEqual(settingsModel.simplefin?.extraTrustedHosts, [betaHost])
    }

    func testTrustedHostConfirmationUsesCapturedValuesAfterAlertDismissal() async throws {
        let store = try LedgerWorkspaceStore.inMemory()
        let creator = AppModel(
            store: store,
            credentials: InMemorySimpleFINCredentialStore()
        )
        await creator.createBudget(
            currency: "USD",
            timeZoneIdentifier: "UTC",
            firstMonth: BudgetMonth(string: "2025-01")!
        )

        let model = AppModel(
            store: store,
            credentials: InMemorySimpleFINCredentialStore()
        )
        let betaHost = try SimpleFINHost(host: "beta-bridge.simplefin.org")

        // Simulate the alert binding clearing the pending fields before the
        // asynchronous button task starts. The captured arguments must still
        // persist the explicit host confirmation.
        model.pendingSetupToken = nil
        model.pendingTrustedHost = nil
        await model.trustPendingSetupHostAndRetry(
            setupToken: "synthetic-invalid-setup-token",
            host: betaHost
        )

        XCTAssertEqual(model.simplefin?.extraTrustedHosts, [betaHost])
    }
}

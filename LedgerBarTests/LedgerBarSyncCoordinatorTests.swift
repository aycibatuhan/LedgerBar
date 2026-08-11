import Foundation
import XCTest
@testable import LedgerBar
import LedgerCore

final class LedgerBarSyncCoordinatorTests: XCTestCase {
    private struct Fixture {
        var service: BudgetMutationService
        var credentialStore: InMemorySimpleFINCredentialStore
        var coordinator: SyncCoordinator
        var connectionPin: SimpleFINConnectionPin
    }

    /// Three active links over an in-memory store, a synthetic credential, and
    /// a coordinator whose clock is pinned to 1_735_689_603.
    private func makeThreeLinkFixture() async throws -> Fixture {
        let store = try LedgerWorkspaceStore.inMemory()
        let service = BudgetMutationService(store: store)
        _ = try await service.createBudget(
            name: "Retry-After",
            currency: "USD",
            timeZoneIdentifier: "UTC",
            firstMonth: BudgetMonth(string: "2025-01")!,
            currentMonth: BudgetMonth(string: "2025-01")!,
            nowEpoch: 1_735_689_600
        )

        let accountIDs = try await service.transact(nowEpoch: 1_735_689_601) { workspace in
            try ["One", "Two", "Three"].map { name in
                try workspace.addAccount(
                    name: name,
                    type: .checking,
                    onBudget: true,
                    currency: "USD",
                    openingBalance: 0,
                    openingDate: BudgetDate(string: "2025-01-01")!,
                    nowEpoch: 1_735_689_600
                )
            }
        }

        let links = accountIDs.map { accountID in
            SimpleFINAccountLink(
                connectionKey: "conn:primary",
                remoteAccountID: "remote-\(accountID.description)",
                localAccountID: accountID,
                lastSuccessfulPostedEpoch: 1_735_689_600
            )
        }
        try await service.updateSimpleFINState(nowEpoch: 1_735_689_602) { state in
            state = SimpleFINConnectionState(
                status: .active,
                keychainItemID: "synthetic-keychain-item",
                baseHost: "bridge.simplefin.org",
                basePort: 443,
                credentialGeneration: 1,
                createdAtEpoch: 1_735_689_600,
                links: links
            )
        }

        let host = try SimpleFINHost(host: SimpleFINURLValidator.officialBridgeHost)
        let credential = try SimpleFINCredential(
            host: host,
            opaquePercentEncodedPathPrefix: "/access/v1/synthetic",
            existingQueryItems: [],
            existingPercentEncodedQuery: nil,
            username: "synthetic-user",
            password: "synthetic-password",
            approvedHost: host
        )
        let credentialStore = InMemorySimpleFINCredentialStore()
        try credentialStore.save(credential, itemID: "synthetic-keychain-item")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RetryAfterURLProtocol.self]
        let coordinator = SyncCoordinator(
            urlSession: URLSession(configuration: configuration),
            nowEpochProvider: { 1_735_689_603 }
        )
        return Fixture(
            service: service,
            credentialStore: credentialStore,
            coordinator: coordinator,
            connectionPin: SimpleFINConnectionPin(itemID: "synthetic-keychain-item", credentialGeneration: 1)
        )
    }

    func testRetryAfterStopsRemainingLinksInCurrentPass() async throws {
        RetryAfterURLProtocol.reset()
        defer { RetryAfterURLProtocol.reset() }

        let fixture = try await makeThreeLinkFixture()
        let summary = try await fixture.coordinator.syncNow(
            service: fixture.service,
            credentials: fixture.credentialStore,
            connectionPin: fixture.connectionPin,
            nowEpoch: 1_735_689_603
        )

        XCTAssertEqual(RetryAfterURLProtocol.requestCount, 1)
        XCTAssertTrue(summary.linkErrorMessages.contains("Sync is deferred until the server-provided retry time."))
        let finalState = try await fixture.service.simpleFINState()
        XCTAssertEqual(finalState?.retryNotBeforeEpoch, 1_735_693_203)
    }

    /// An oversized Retry-After (larger than Int64) must saturate the durable
    /// deferral instead of being dropped, and must still stop the current
    /// pass after the first request.
    func testOversizedRetryAfterSaturatesDeferralInsteadOfSkipping() async throws {
        RetryAfterURLProtocol.reset(retryAfterValue: "99999999999999999999")
        defer { RetryAfterURLProtocol.reset() }

        let fixture = try await makeThreeLinkFixture()
        let summary = try await fixture.coordinator.syncNow(
            service: fixture.service,
            credentials: fixture.credentialStore,
            connectionPin: fixture.connectionPin,
            nowEpoch: 1_735_689_603
        )

        XCTAssertEqual(RetryAfterURLProtocol.requestCount, 1)
        XCTAssertTrue(summary.linkErrorMessages.contains("Sync is deferred until the server-provided retry time."))
        let finalState = try await fixture.service.simpleFINState()
        XCTAssertEqual(finalState?.retryNotBeforeEpoch, 1_735_689_603 + 86_400)
    }
}

private final class RetryAfterURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requests = 0
    nonisolated(unsafe) private static var retryAfterValue = "3600"

    static var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return requests
    }

    static func reset(retryAfterValue: String = "3600") {
        lock.lock(); defer { lock.unlock() }
        requests = 0
        self.retryAfterValue = retryAfterValue
    }

    private static var currentRetryAfterValue: String {
        lock.lock(); defer { lock.unlock() }
        return retryAfterValue
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requests += 1
        Self.lock.unlock()

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 429,
            httpVersion: "HTTP/1.1",
            headerFields: ["Retry-After": Self.currentRetryAfterValue, "Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

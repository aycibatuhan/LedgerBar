import Foundation
import Testing
@testable import LedgerCore

@Suite("M5.8.1 SimpleFIN diagnostic and identity boundaries")
struct SimpleFINM581Tests {
    private func credentialShapedDiagnostics() -> (messages: [String], rawMarkers: [String]) {
        let opaque = String(repeating: "Q7", count: 18)
        let passphrase = ["unit", "fixture", "value", "2468"].joined(separator: "-")
        let access = ["ht", "tps", "://", "fixture-user", ":", passphrase,
                      "@", "example.invalid", "/access"].joined()
        let messages = [
            "Institution maintenance window until 04:00 UTC.",
            "Access URL: \(access)",
            "Authorization: Basic \(opaque)",
            "Authorization: Bearer \(opaque)",
            "token=\(opaque) api-key=\(opaque)",
            "password=\"\(passphrase)\" secret=\(passphrase)",
            "connection-string=\(access)"
        ]
        return (messages, [opaque, passphrase, access, "fixture-user"])
    }

    private func expectNoRawMarkers(
        _ messages: [String],
        markers: [String],
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(
            messages.allSatisfy { message in
                markers.allSatisfy { !message.contains($0) }
            },
            sourceLocation: sourceLocation
        )
    }

    private func link(
        connectionKey: String,
        remoteAccountID: String,
        status: SimpleFINLinkStatus = .paused,
        pauseReason: SimpleFINLinkPauseReason? = nil
    ) -> SimpleFINAccountLink {
        SimpleFINAccountLink(
            connectionKey: connectionKey,
            remoteAccountID: remoteAccountID,
            localAccountID: AccountID(),
            status: status,
            pauseReason: pauseReason
        )
    }

    private func encodedAsLegacyState(
        _ state: SimpleFINConnectionState,
        disconnect: [String],
        authorization: [String]
    ) throws -> Data {
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any]
        )
        object.removeValue(forKey: "linkIdentityEncodingVersion")
        object["disconnectPausedLinkIdentities"] = disconnect
        object["authRevokedLinkIdentitiesAwaitingReconnect"] = authorization
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    @Test("provider messages are redacted once at the response boundary and remain useful")
    func providerResponseRedaction() throws {
        let fixture = credentialShapedDiagnostics()
        let response = try SimpleFINAccountsResponse(
            accounts: [],
            errors: fixture.messages
        )

        #expect(response.errors.first == "Institution maintenance window until 04:00 UTC.")
        #expect(response.errors.dropFirst().allSatisfy {
            $0.contains(SimpleFINDiagnosticRedactor.replacement)
        })
        #expect(response.errors.allSatisfy {
            $0.count <= SimpleFINDiagnosticRedactor.maximumMessageLength
        })
        expectNoRawMarkers(response.errors, markers: fixture.rawMarkers)

        let outwardSummary = SimpleFINDiagnosticRedactor.summary(response.errors)
        #expect(outwardSummary.contains("Institution maintenance window"))
        #expect(outwardSummary.count <= SimpleFINDiagnosticRedactor.maximumSummaryLength)
        expectNoRawMarkers([outwardSummary], markers: fixture.rawMarkers)
        expectNoRawMarkers(
            [SimpleFINDiagnosticRedactor.summary(fixture.messages)],
            markers: fixture.rawMarkers
        )

        let bounded = SimpleFINDiagnosticRedactor.redact(
            String(repeating: "ordinary diagnostic text ", count: 400)
        )
        #expect(bounded.count == SimpleFINDiagnosticRedactor.maximumMessageLength)
        let many = SimpleFINDiagnosticRedactor.redact(
            (0..<(SimpleFINDiagnosticRedactor.maximumDiagnosticCount + 3)).map {
                "Benign provider message \($0)."
            }
        )
        #expect(many.count == SimpleFINDiagnosticRedactor.maximumDiagnosticCount + 1)
        #expect(many.last == "Additional provider diagnostics omitted.")
    }

    @Test("initial-link protocol errors and recurring outcomes expose only redacted provider values")
    func outwardProviderErrorsAreRedacted() throws {
        let fixture = credentialShapedDiagnostics()
        let response = try SimpleFINAccountsResponse(accounts: [], errors: fixture.messages)

        do {
            _ = try SimpleFINSynchronizer.validateInitialLinkResponse(
                response: response,
                connectionKey: "conn:fixture",
                remoteAccountID: "account-fixture",
                accountType: .checking,
                signNormalization: .normal,
                calendar: BudgetCalendar(timeZoneIdentifier: "UTC"),
                nowEpoch: testEpoch
            )
            Issue.record("Expected provider-reported initial-link rejection.")
        } catch SimpleFINProtocolError.providerReportedErrors(let messages) {
            #expect(!messages.isEmpty)
            expectNoRawMarkers(messages, markers: fixture.rawMarkers)
            expectNoRawMarkers(
                [SimpleFINDiagnosticRedactor.summary(messages)],
                markers: fixture.rawMarkers
            )
        }

        var workspace = try makeWorkspace()
        let accountID = try workspace.addAccount(
            name: "Fixture checking",
            type: .checking,
            onBudget: true,
            openingBalance: 0,
            openingDate: date("2025-01-01"),
            nowEpoch: testEpoch
        )
        var recurringLink = SimpleFINAccountLink(
            connectionKey: "conn:fixture",
            remoteAccountID: "account-fixture",
            localAccountID: accountID,
            lastSuccessfulPostedEpoch: testEpoch
        )
        let outcome = try SimpleFINSyncEngine.applyAccountSync(
            response: response,
            link: &recurringLink,
            window: .recurring(requestStartEpoch: testEpoch - 1),
            workspace: &workspace,
            nowEpoch: testEpoch
        )
        #expect(!outcome.providerErrors.isEmpty)
        expectNoRawMarkers(outcome.providerErrors, markers: fixture.rawMarkers)
    }

    @Test("serialized connection diagnostics cannot persist raw provider material")
    func persistedDiagnosticsAreRedacted() throws {
        let fixture = credentialShapedDiagnostics()
        let raw = fixture.messages.joined(separator: " ")
        var storedLink = link(connectionKey: "conn:fixture", remoteAccountID: "account-fixture")
        storedLink.recordSyncError(raw)
        var state = SimpleFINConnectionState(
            status: .active,
            keychainItemID: "fixture-item",
            baseHost: "example.invalid",
            basePort: 443,
            credentialGeneration: 1,
            createdAtEpoch: testEpoch,
            links: [storedLink]
        )
        state.recordConnectionSyncError(raw)
        #expect(state.lastErrorRedacted?.contains(SimpleFINDiagnosticRedactor.replacement) == true)
        storedLink.pause(reason: .protocolError, message: raw)
        #expect(storedLink.lastErrorRedacted?.contains(SimpleFINDiagnosticRedactor.replacement) == true)
        state.links = [storedLink]

        let encoded = try JSONEncoder().encode(state)
        let serialized = String(decoding: encoded, as: UTF8.self)
        expectNoRawMarkers([serialized], markers: fixture.rawMarkers)

        let decoded = try JSONDecoder().decode(SimpleFINConnectionState.self, from: encoded)
        expectNoRawMarkers(
            [decoded.lastErrorRedacted, decoded.links.first?.lastErrorRedacted].compactMap { $0 },
            markers: fixture.rawMarkers
        )
        #expect(decoded.lastErrorRedacted?.contains(SimpleFINDiagnosticRedactor.replacement) == true)
        #expect(decoded.links.first?.lastErrorRedacted?.contains(SimpleFINDiagnosticRedactor.replacement) == true)
    }

    @Test("canonical remote-link identity is a pinned injective UTF-8 tuple")
    func canonicalIdentityIsInjective() throws {
        let first = SimpleFINAccountLink.identity(
            connectionKey: "conn:a|b",
            remoteAccountID: "c"
        )
        let second = SimpleFINAccountLink.identity(
            connectionKey: "conn:a",
            remoteAccountID: "b|c"
        )
        #expect(first == "simplefin-link:v1:8:conn:a|b1:c")
        #expect(second == "simplefin-link:v1:6:conn:a3:b|c")
        #expect(first != second)
        #expect(
            SimpleFINAccountLink.identity(connectionKey: "é", remoteAccountID: "x")
                == "simplefin-link:v1:2:é1:x"
        )

        let response = try SimpleFINAccountsResponse(accounts: [
            SimpleFINRemoteAccount(
                id: "c", currency: "USD", balance: "0", connectionID: "a|b"
            ),
            SimpleFINRemoteAccount(
                id: "b|c", currency: "USD", balance: "0", connectionID: "a"
            )
        ])
        #expect(response.accounts.count == 2)

        let firstLink = link(connectionKey: "conn:a|b", remoteAccountID: "c")
        let secondLink = link(connectionKey: "conn:a", remoteAccountID: "b|c")
        let state = SimpleFINConnectionState(
            status: .active,
            keychainItemID: "fixture-item",
            baseHost: "example.invalid",
            basePort: 443,
            credentialGeneration: 1,
            createdAtEpoch: testEpoch,
            links: [firstLink, secondLink]
        )
        #expect(state.linksByIdentity.count == 2)
        #expect(state.linksByIdentity[firstLink.identity] == firstLink)
        #expect(state.linksByIdentity[secondLink.identity] == secondLink)
    }

    @Test("legacy reconnect provenance migrates only through an unambiguous decoded-link match")
    func legacyProvenanceMigrationAndReconnect() throws {
        let disconnected = link(connectionKey: "conn:one", remoteAccountID: "account-one")
        let authorization = link(
            connectionKey: "conn:two",
            remoteAccountID: "account-two",
            pauseReason: .authRevoked
        )
        let current = SimpleFINConnectionState(
            status: .active,
            keychainItemID: "fixture-item",
            baseHost: "example.invalid",
            basePort: 443,
            credentialGeneration: 2,
            createdAtEpoch: testEpoch,
            links: [disconnected, authorization],
            disconnectPausedLinkIdentities: [disconnected.identity],
            authRevokedLinkIdentitiesAwaitingReconnect: [authorization.identity]
        )
        let legacy = try encodedAsLegacyState(
            current,
            disconnect: ["conn:one|account-one"],
            authorization: ["conn:two|account-two"]
        )
        var decoded = try JSONDecoder().decode(SimpleFINConnectionState.self, from: legacy)

        #expect(decoded.disconnectPausedLinkIdentities == [disconnected.identity])
        #expect(decoded.authRevokedLinkIdentitiesAwaitingReconnect == [authorization.identity])
        decoded = try JSONDecoder().decode(
            SimpleFINConnectionState.self,
            from: JSONEncoder().encode(decoded)
        )
        #expect(decoded.disconnectPausedLinkIdentities == [disconnected.identity])
        #expect(decoded.authRevokedLinkIdentitiesAwaitingReconnect == [authorization.identity])
        #expect(decoded.reactivateLinksAfterIdentityMatch([
            disconnected.identity, authorization.identity
        ]) == [disconnected.identity, authorization.identity].sorted())
        #expect(decoded.link(identity: disconnected.identity)?.status == .active)
        #expect(decoded.link(identity: authorization.identity)?.status == .active)

        let roundTripped = try JSONDecoder().decode(
            SimpleFINConnectionState.self,
            from: JSONEncoder().encode(decoded)
        )
        #expect(roundTripped.disconnectPausedLinkIdentities.isEmpty)
        #expect(roundTripped.authRevokedLinkIdentitiesAwaitingReconnect.isEmpty)
    }

    @Test("ambiguous and unknown legacy provenance cannot reactivate a different link")
    func ambiguousLegacyProvenanceStaysInert() throws {
        let first = link(connectionKey: "conn:a|b", remoteAccountID: "c")
        let second = link(connectionKey: "conn:a", remoteAccountID: "b|c")
        let current = SimpleFINConnectionState(
            status: .active,
            keychainItemID: "fixture-item",
            baseHost: "example.invalid",
            basePort: 443,
            credentialGeneration: 2,
            createdAtEpoch: testEpoch,
            links: [first, second],
            disconnectPausedLinkIdentities: [first.identity]
        )

        let ambiguous = try encodedAsLegacyState(
            current,
            disconnect: ["conn:a|b|c"],
            authorization: []
        )
        var decodedAmbiguous = try JSONDecoder().decode(
            SimpleFINConnectionState.self,
            from: ambiguous
        )
        #expect(!decodedAmbiguous.disconnectPausedLinkIdentities.contains(first.identity))
        #expect(!decodedAmbiguous.disconnectPausedLinkIdentities.contains(second.identity))
        #expect(decodedAmbiguous.reactivateLinksAfterIdentityMatch([
            first.identity, second.identity
        ]).isEmpty)
        #expect(decodedAmbiguous.links.allSatisfy { $0.status == .paused })

        let unknown = try encodedAsLegacyState(
            current,
            disconnect: [first.identity],
            authorization: []
        )
        var decodedUnknown = try JSONDecoder().decode(SimpleFINConnectionState.self, from: unknown)
        #expect(!decodedUnknown.disconnectPausedLinkIdentities.contains(first.identity))
        #expect(decodedUnknown.reactivateLinksAfterIdentityMatch([first.identity]).isEmpty)
        #expect(decodedUnknown.link(identity: first.identity)?.status == .paused)
    }

    @Test("reconnect matching respects canonical component boundaries")
    func reconnectMatchingUsesCanonicalIdentity() {
        let first = link(connectionKey: "conn:a|b", remoteAccountID: "c")
        let second = link(connectionKey: "conn:a", remoteAccountID: "b|c")
        var state = SimpleFINConnectionState(
            status: .active,
            keychainItemID: "fixture-item",
            baseHost: "example.invalid",
            basePort: 443,
            credentialGeneration: 2,
            createdAtEpoch: testEpoch,
            links: [first, second],
            disconnectPausedLinkIdentities: [first.identity, second.identity]
        )

        #expect(state.reactivateLinksAfterIdentityMatch([second.identity]) == [second.identity])
        #expect(state.link(identity: first.identity)?.status == .paused)
        #expect(state.link(identity: second.identity)?.status == .active)
        #expect(state.disconnectPausedLinkIdentities == [first.identity])
    }
}

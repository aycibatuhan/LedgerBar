import Foundation
import Testing
@testable import LedgerCore

@Suite("M5.8.2 SimpleFIN provider-error and diagnostic hardening")
struct SimpleFINM582Tests {
    private enum FixtureError: Error { case missingState }
    private let cursor: Int64 = testEpoch + 10 * 86_400

    private func rawDiagnosticFixture() -> (messages: [String], markers: [String]) {
        let opaque = String(repeating: "M582", count: 12)
        let password = ["synthetic", "credential", "fixture", "582"].joined(separator: "-")
        let accessURL = [
            "ht", "tps", "://", "fixture-user", ":", password,
            "@", "example.invalid", "/access"
        ].joined()
        return (
            [
                "Institution maintenance is delaying account data.",
                "Access URL: \(accessURL)",
                "Authorization: Basic \(opaque)"
            ],
            [opaque, password, accessURL, "fixture-user"]
        )
    }

    @Test("manual resume cannot bypass an unresolved snapshot discrepancy")
    func manualResumeDoesNotBypassSnapshotDiscrepancy() {
        let link = SimpleFINAccountLink(
            connectionKey: "conn:m582-resume",
            remoteAccountID: "account-m582-resume",
            localAccountID: AccountID(),
            status: .paused,
            pauseReason: .snapshotDiscrepancy
        )
        let state = SimpleFINConnectionState(
            status: .active,
            keychainItemID: "synthetic-item-reference",
            baseHost: "example.invalid",
            basePort: 443,
            credentialGeneration: 1,
            createdAtEpoch: testEpoch,
            links: [link]
        )

        #expect(!state.canManuallyResumeLink(identity: link.identity))
    }

    private func encodedCurrentState(
        _ state: SimpleFINConnectionState,
        disconnect: [String],
        authorization: [String]
    ) throws -> Data {
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any]
        )
        object["linkIdentityEncodingVersion"] = 1
        object["disconnectPausedLinkIdentities"] = disconnect
        object["authRevokedLinkIdentitiesAwaitingReconnect"] = authorization
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    @Test("recurring provider errors preserve workspace, imports, cursor, and connection success state")
    func recurringProviderErrorIsDiagnosticOnly() throws {
        let fixture = rawDiagnosticFixture()
        var workspace = try makeWorkspace(timeZone: "UTC")
        let accountID = try workspace.addAccount(
            name: "Linked checking",
            type: .checking,
            onBudget: true,
            openingBalance: usd(100),
            openingDate: date("2025-01-01"),
            nowEpoch: testEpoch
        )
        var link = SimpleFINAccountLink(
            connectionKey: "conn:m582",
            remoteAccountID: "account-m582",
            localAccountID: accountID,
            lastSuccessfulPostedEpoch: cursor
        )
        link.recordSyncError("A prior per-link diagnostic.")

        // Every response field would mutate or pause the link if evaluated:
        // malformed balance, future row, new import, and mismatched currency.
        let response = try SimpleFINAccountsResponse(
            accounts: [SimpleFINRemoteAccount(
                id: "account-m582",
                currency: "EUR",
                balance: "not-a-balance",
                balanceDateEpoch: cursor + 86_400,
                connectionID: "m582",
                transactions: [SimpleFINRemoteTransaction(
                    id: "would-import",
                    amount: "-12.34",
                    postedEpoch: cursor + 365 * 86_400
                )]
            )],
            errors: fixture.messages
        )
        let workspaceBefore = workspace
        let linkBefore = link

        let outcome = try SimpleFINSyncEngine.applyAccountSync(
            response: response,
            link: &link,
            window: .recurring(requestStartEpoch: cursor - 5 * 86_400),
            workspace: &workspace,
            nowEpoch: cursor + 86_400
        )

        #expect(outcome == SimpleFINAccountSyncOutcome(providerErrors: response.errors))
        #expect(workspace == workspaceBefore)
        #expect(workspace.simpleFINImports.isEmpty)
        #expect(link == linkBefore)
        #expect(link.lastSuccessfulPostedEpoch == cursor)
        #expect(outcome.hasProviderErrors)
        #expect(outcome.providerErrors.first?.contains("Institution maintenance") == true)
        for marker in fixture.markers {
            #expect(outcome.providerErrors.allSatisfy { !$0.contains(marker) })
        }

        let priorSuccess = cursor - 1
        var state = SimpleFINConnectionState(
            status: .active,
            keychainItemID: "synthetic-item-reference",
            baseHost: "example.invalid",
            basePort: 443,
            credentialGeneration: 7,
            createdAtEpoch: testEpoch,
            lastSuccessfulSyncAtEpoch: priorSuccess,
            lastErrorRedacted: "A prior connection diagnostic.",
            links: [link]
        )
        let priorConnectionError = state.lastErrorRedacted

        // This is the exact provider-error persistence path used by the
        // coordinator. It mutates only the per-link diagnostic.
        let recordedProviderErrors = state.recordProviderErrors(
            outcome.providerErrors,
            forLinkIdentity: link.identity
        )
        #expect(recordedProviderErrors)
        #expect(state.lastSuccessfulSyncAtEpoch == priorSuccess)
        #expect(state.lastErrorRedacted == priorConnectionError)
        #expect(state.link(identity: link.identity)?.lastSuccessfulPostedEpoch == cursor)
        let visibleLinkError = try #require(state.link(identity: link.identity)?.lastErrorRedacted)
        #expect(visibleLinkError.contains("Institution maintenance"))
        #expect(visibleLinkError.count <= SimpleFINDiagnosticRedactor.maximumMessageLength)
        for marker in fixture.markers {
            #expect(!visibleLinkError.contains(marker))
        }
    }

    @Test("private-set diagnostic mutation APIs redact before in-memory observation")
    func diagnosticMutationPathsRedactImmediately() throws {
        let fixture = rawDiagnosticFixture()
        let raw = fixture.messages.joined(separator: " ")
        var link = SimpleFINAccountLink(
            connectionKey: "conn:m582",
            remoteAccountID: "account-m582",
            localAccountID: AccountID(),
            lastErrorRedacted: raw
        )
        var state = SimpleFINConnectionState(
            status: .active,
            keychainItemID: "synthetic-item-reference",
            baseHost: "example.invalid",
            basePort: 443,
            credentialGeneration: 1,
            createdAtEpoch: testEpoch,
            lastErrorRedacted: raw,
            links: [link]
        )
        var outcome = SimpleFINAccountSyncOutcome(providerErrors: fixture.messages)

        link.recordSyncError(raw)
        state.recordCredentialLifecycleError(raw)
        outcome.replaceProviderErrors(with: fixture.messages)

        let visible = [link.lastErrorRedacted, state.lastErrorRedacted].compactMap { $0 }
            + outcome.providerErrors
        #expect(visible.allSatisfy { $0.count <= SimpleFINDiagnosticRedactor.maximumMessageLength })
        #expect(visible.contains { $0.contains(SimpleFINDiagnosticRedactor.replacement) })
        for marker in fixture.markers {
            #expect(visible.allSatisfy { !$0.contains(marker) })
        }

        link.clearSyncError()
        state.clearCredentialLifecycleError()
        #expect(link.lastErrorRedacted == nil)
        #expect(state.lastErrorRedacted == nil)
    }

    @Test("provider-error persistence commits only the redacted per-link diagnostic")
    func providerErrorPersistencePath() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledgerbar-m582-provider-error-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try LedgerWorkspaceStore(
            databaseURL: directory.appendingPathComponent("LedgerBar.sqlite")
        )
        let service = BudgetMutationService(store: store)
        _ = try await service.createBudget(
            name: "M5.8.2",
            currency: "USD",
            timeZoneIdentifier: "UTC",
            firstMonth: month("2025-01"),
            currentMonth: month("2025-01"),
            nowEpoch: testEpoch
        )
        let accountID = try await service.transact(nowEpoch: testEpoch) { workspace in
            try workspace.addAccount(
                name: "Linked checking",
                type: .checking,
                onBudget: true,
                openingBalance: usd(100),
                openingDate: date("2025-01-01"),
                nowEpoch: testEpoch
            )
        }
        let link = SimpleFINAccountLink(
            connectionKey: "conn:m582",
            remoteAccountID: "account-m582",
            localAccountID: accountID,
            lastSuccessfulPostedEpoch: cursor
        )
        let priorSuccess = cursor - 10
        _ = try await service.updateSimpleFINState(nowEpoch: testEpoch) { stored in
            stored = SimpleFINConnectionState(
                status: .active,
                keychainItemID: "synthetic-item-reference",
                baseHost: "example.invalid",
                basePort: 443,
                credentialGeneration: 4,
                createdAtEpoch: testEpoch,
                lastSuccessfulSyncAtEpoch: priorSuccess,
                lastErrorRedacted: "A prior connection diagnostic.",
                links: [link]
            )
        }
        let pin = try #require(try await service.simpleFINState()?.activeCredentialPin)
        let snapshotBefore = try #require(await service.currentSnapshot())
        let connectionErrorBefore = try await service.simpleFINState()?.lastErrorRedacted
        let fixture = rawDiagnosticFixture()
        let response = try SimpleFINAccountsResponse(
            accounts: [SimpleFINRemoteAccount(
                id: "account-m582",
                currency: "USD",
                balance: "75.00",
                connectionID: "m582",
                transactions: [SimpleFINRemoteTransaction(
                    id: "must-not-import",
                    amount: "-25.00",
                    postedEpoch: cursor + 86_400
                )]
            )],
            errors: fixture.messages
        )

        let outcome = try await service.syncTransact(
            nowEpoch: cursor + 86_400,
            expectedCredentialPin: pin
        ) { workspace, state in
            guard var storedLink = state.link(identity: link.identity) else {
                throw FixtureError.missingState
            }
            let outcome = try SimpleFINSyncEngine.applyAccountSync(
                response: response,
                link: &storedLink,
                window: .recurring(requestStartEpoch: cursor - 5 * 86_400),
                workspace: &workspace,
                nowEpoch: cursor + 86_400
            )
            guard outcome.hasProviderErrors,
                  state.recordProviderErrors(
                    outcome.providerErrors,
                    forLinkIdentity: link.identity
                  ) else {
                throw FixtureError.missingState
            }
            return outcome
        }

        #expect(outcome.hasProviderErrors)
        #expect(await service.currentSnapshot() == snapshotBefore)
        let persisted = try #require(try await service.simpleFINState())
        #expect(persisted.lastSuccessfulSyncAtEpoch == priorSuccess)
        #expect(persisted.lastErrorRedacted == connectionErrorBefore)
        #expect(persisted.link(identity: link.identity)?.lastSuccessfulPostedEpoch == cursor)
        #expect(persisted.link(identity: link.identity)?.lastErrorRedacted != nil)
        #expect(persisted.links.count == 1)
        #expect(snapshotBefore.simpleFINImports.isEmpty)
        #expect((await service.currentSnapshot())?.simpleFINImports.isEmpty == true)
        for marker in fixture.markers {
            #expect(persisted.link(identity: link.identity)?.lastErrorRedacted?.contains(marker) == false)
        }
    }

    @Test("current-version unknown and ambiguous provenance remains inert across round trips")
    func currentVersionProvenanceValidation() throws {
        let live = SimpleFINAccountLink(
            connectionKey: "conn:live",
            remoteAccountID: "account-live",
            localAccountID: AccountID(),
            status: .paused
        )
        let unknown = SimpleFINAccountLink.identity(
            connectionKey: "conn:unknown",
            remoteAccountID: "account-unknown"
        )
        let base = SimpleFINConnectionState(
            status: .active,
            keychainItemID: "synthetic-item-reference",
            baseHost: "example.invalid",
            basePort: 443,
            credentialGeneration: 2,
            createdAtEpoch: testEpoch,
            links: [live],
            disconnectPausedLinkIdentities: [live.identity]
        )
        var decoded = try JSONDecoder().decode(
            SimpleFINConnectionState.self,
            from: encodedCurrentState(
                base,
                disconnect: [live.identity, unknown],
                authorization: []
            )
        )
        #expect(decoded.disconnectPausedLinkIdentities.contains(live.identity))
        #expect(!decoded.disconnectPausedLinkIdentities.contains(unknown))
        let inertUnknown = try #require(
            decoded.disconnectPausedLinkIdentities.first {
                $0.hasPrefix("simplefin-link:unmatched:v1:")
            }
        )
        #expect(decoded.reactivateLinksAfterIdentityMatch([live.identity, unknown]) == [live.identity])
        #expect(decoded.link(identity: live.identity)?.status == .active)
        #expect(!decoded.hasLinksAwaitingReconnectValidation)
        #expect(decoded.disconnectPausedLinkIdentities == [inertUnknown])

        let roundTripped = try JSONDecoder().decode(
            SimpleFINConnectionState.self,
            from: JSONEncoder().encode(decoded)
        )
        #expect(roundTripped.disconnectPausedLinkIdentities == [inertUnknown])
        #expect(!roundTripped.hasLinksAwaitingReconnectValidation)

        // Duplicate decoded links make an otherwise canonical marker
        // ambiguous, so it cannot reactivate either copy.
        let duplicateBase = SimpleFINConnectionState(
            status: .active,
            keychainItemID: "synthetic-item-reference",
            baseHost: "example.invalid",
            basePort: 443,
            credentialGeneration: 2,
            createdAtEpoch: testEpoch,
            links: [live, live]
        )
        var duplicateDecoded = try JSONDecoder().decode(
            SimpleFINConnectionState.self,
            from: encodedCurrentState(
                duplicateBase,
                disconnect: [live.identity],
                authorization: []
            )
        )
        #expect(!duplicateDecoded.disconnectPausedLinkIdentities.contains(live.identity))
        #expect(duplicateDecoded.reactivateLinksAfterIdentityMatch([live.identity]).isEmpty)
        #expect(duplicateDecoded.links.allSatisfy { $0.status == .paused })
        #expect(!duplicateDecoded.hasLinksAwaitingReconnectValidation)
    }

    @Test("final sync status is bounded independently of account cardinality")
    func finalSyncStatusIsBounded() {
        let fixture = rawDiagnosticFixture()
        let fragments = ["Imported 3 transaction(s) across 2 account(s)."]
            + (0..<2_000).map { index in
                "Account \(index) failed: \(fixture.messages[1])"
            }
        let summary = SimpleFINDiagnosticRedactor.statusSummary(fragments)

        #expect(summary.hasPrefix("Imported 3 transaction(s) across 2 account(s)."))
        #expect(summary.count == SimpleFINDiagnosticRedactor.maximumSummaryLength)
        #expect(summary.contains(SimpleFINDiagnosticRedactor.replacement))
        for marker in fixture.markers {
            #expect(!summary.contains(marker))
        }
    }

    @Test("capture credential gate rejects a durably revoked authorization")
    func captureUsesActiveCredentialPinGate() throws {
        var state = SimpleFINConnectionState(
            status: .active,
            keychainItemID: "synthetic-item-reference",
            baseHost: "example.invalid",
            basePort: 443,
            credentialGeneration: 1,
            createdAtEpoch: testEpoch
        )
        #expect(state.activeCredentialPin?.itemID == "synthetic-item-reference")

        state.markCredentialAuthorizationRevoked()
        #expect(state.credentialAuthorizationRevoked)
        #expect(state.activeCredentialPin == nil)
    }
}

import Foundation

/// Durable, non-secret replacement intent for the Keychain/SQLite lifecycle.
/// The credential itself never enters this value; only its opaque item
/// identifier and the already-permitted connection host metadata are stored.
public struct SimpleFINCredentialReplacementIntent: Codable, Sendable, Equatable {
    public var itemID: String
    public var baseHost: String
    public var basePort: Int

    public init(itemID: String, baseHost: String, basePort: Int) {
        self.itemID = itemID
        self.baseHost = baseHost
        self.basePort = basePort
    }
}

/// Ephemeral identity for one active credential generation. Network work pins
/// this value before leaving the database actor and must match it again before
/// committing a response. It contains only an opaque Keychain reference.
public struct SimpleFINConnectionPin: Sendable, Equatable {
    public var itemID: String
    public var credentialGeneration: Int

    public init(itemID: String, credentialGeneration: Int) {
        self.itemID = itemID
        self.credentialGeneration = credentialGeneration
    }
}

public enum SimpleFINConnectionPinError: Error, Equatable, Sendable {
    case connectionChanged
}

public enum SimpleFINLinkInvariantError: Error, Equatable, Sendable {
    case localAccountAlreadyLinked
}

/// Durable SimpleFIN connection metadata for the single v1 connection.
/// Persisted in SQLite (`simplefin_state`); the credential itself lives only
/// in the Keychain item referenced by `keychainItemID`. Disconnect keeps this
/// row (status `disconnected`, `keychainItemID = nil`) so links, cursors, and
/// import identity survive as tombstones; reconnect increments
/// `credentialGeneration` and never creates a second connection.
public struct SimpleFINConnectionState: Codable, Sendable, Equatable {
    private static let currentLinkIdentityEncodingVersion = 1

    public enum Status: String, Codable, Sendable {
        case active
        case disconnected
    }

    public var status: Status
    public var keychainItemID: String?
    public var baseHost: String
    public var basePort: Int
    public var credentialGeneration: Int
    public var createdAtEpoch: Int64
    public var lastSuccessfulSyncAtEpoch: Int64?
    /// Connection-wide HTTP backoff gate. A server-provided Retry-After is
    /// durable so an app restart cannot immediately repeat a throttled pass.
    public var retryNotBeforeEpoch: Int64?
    /// Sanitized error summary only — never URLs, userinfo, tokens, or hosts
    /// combined with credentials.
    public private(set) var lastErrorRedacted: String?
    public var links: [SimpleFINAccountLink]
    /// Hosts the user explicitly approved beyond the official bridge host.
    public var extraTrustedHosts: [SimpleFINHost]
    /// Replacement intent is persisted before the corresponding Keychain
    /// save. This keeps a newly saved item reachable if promotion fails.
    public var pendingCredentialReplacement: SimpleFINCredentialReplacementIntent?
    /// Superseded item identifiers remain durable until deletion and the
    /// follow-up persistence update have both succeeded.
    public var keychainItemIDsPendingDeletion: [String]
    /// A disconnect first sets this gate while retaining all item references.
    /// Sync must stop, but the primary reference is not cleared until its
    /// deletion succeeds.
    public var credentialDisconnectPending: Bool
    /// A 401/403 rejects the current credential generation without pretending
    /// that its Keychain deletion has completed. This durable gate invalidates
    /// every response pinned to that generation and clears only when a newly
    /// claimed credential is promoted.
    public var credentialAuthorizationRevoked: Bool
    /// Link identities that were active when a full disconnect completed.
    /// Their nullable §2.1 pause reason is left untouched, so this separate,
    /// non-secret provenance distinguishes disconnect pauses from pre-existing
    /// hard pauses without adding a new pause-reason enum value.
    public var disconnectPausedLinkIdentities: [String]
    /// `authRevoked` links become eligible for identity-matched reactivation
    /// only when a new credential generation is promoted. A clean discovery
    /// using the same revoked generation must never clear the hard pause.
    public var authRevokedLinkIdentitiesAwaitingReconnect: [String]
    /// Explicitly versions the persisted provenance arrays. State blobs that
    /// predate this field contain delimiter identities and are migrated only
    /// when exactly one decoded link matches the legacy value.
    private var linkIdentityEncodingVersion: Int

    public init(
        status: Status,
        keychainItemID: String?,
        baseHost: String,
        basePort: Int,
        credentialGeneration: Int,
        createdAtEpoch: Int64,
        lastSuccessfulSyncAtEpoch: Int64? = nil,
        retryNotBeforeEpoch: Int64? = nil,
        lastErrorRedacted: String? = nil,
        links: [SimpleFINAccountLink] = [],
        extraTrustedHosts: [SimpleFINHost] = [],
        pendingCredentialReplacement: SimpleFINCredentialReplacementIntent? = nil,
        keychainItemIDsPendingDeletion: [String] = [],
        credentialDisconnectPending: Bool = false,
        credentialAuthorizationRevoked: Bool = false,
        disconnectPausedLinkIdentities: [String] = [],
        authRevokedLinkIdentitiesAwaitingReconnect: [String] = []
    ) {
        self.status = status
        self.keychainItemID = keychainItemID
        self.baseHost = baseHost
        self.basePort = basePort
        self.credentialGeneration = credentialGeneration
        self.createdAtEpoch = createdAtEpoch
        self.lastSuccessfulSyncAtEpoch = lastSuccessfulSyncAtEpoch
        self.retryNotBeforeEpoch = retryNotBeforeEpoch
        self.lastErrorRedacted = lastErrorRedacted.map { SimpleFINDiagnosticRedactor.redact($0) }
        self.links = links
        self.extraTrustedHosts = extraTrustedHosts
        self.pendingCredentialReplacement = pendingCredentialReplacement
        self.keychainItemIDsPendingDeletion = keychainItemIDsPendingDeletion
        self.credentialDisconnectPending = credentialDisconnectPending
        self.credentialAuthorizationRevoked = credentialAuthorizationRevoked
        self.disconnectPausedLinkIdentities = Self.validateCurrentProvenance(
            disconnectPausedLinkIdentities,
            links: links
        )
        self.authRevokedLinkIdentitiesAwaitingReconnect = Self.validateCurrentProvenance(
            authRevokedLinkIdentitiesAwaitingReconnect,
            links: links
        )
        self.linkIdentityEncodingVersion = Self.currentLinkIdentityEncodingVersion
    }

    enum CodingKeys: String, CodingKey {
        case status
        case keychainItemID
        case baseHost
        case basePort
        case credentialGeneration
        case createdAtEpoch
        case lastSuccessfulSyncAtEpoch
        case retryNotBeforeEpoch
        case lastErrorRedacted
        case links
        case extraTrustedHosts
        case pendingCredentialReplacement
        case keychainItemIDsPendingDeletion
        case credentialDisconnectPending
        case credentialAuthorizationRevoked
        case disconnectPausedLinkIdentities
        case authRevokedLinkIdentitiesAwaitingReconnect
        case linkIdentityEncodingVersion
    }

    /// State blobs from before the retryable credential lifecycle have no
    /// recovery fields. Decode them with empty/default recovery state.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(Status.self, forKey: .status)
        keychainItemID = try container.decodeIfPresent(String.self, forKey: .keychainItemID)
        baseHost = try container.decode(String.self, forKey: .baseHost)
        basePort = try container.decode(Int.self, forKey: .basePort)
        credentialGeneration = try container.decode(Int.self, forKey: .credentialGeneration)
        createdAtEpoch = try container.decode(Int64.self, forKey: .createdAtEpoch)
        lastSuccessfulSyncAtEpoch = try container.decodeIfPresent(Int64.self, forKey: .lastSuccessfulSyncAtEpoch)
        retryNotBeforeEpoch = try container.decodeIfPresent(Int64.self, forKey: .retryNotBeforeEpoch)
        lastErrorRedacted = try container.decodeIfPresent(String.self, forKey: .lastErrorRedacted)
            .map { SimpleFINDiagnosticRedactor.redact($0) }
        links = try container.decodeIfPresent([SimpleFINAccountLink].self, forKey: .links) ?? []
        extraTrustedHosts = try container.decodeIfPresent([SimpleFINHost].self, forKey: .extraTrustedHosts) ?? []
        pendingCredentialReplacement = try container.decodeIfPresent(
            SimpleFINCredentialReplacementIntent.self,
            forKey: .pendingCredentialReplacement
        )
        keychainItemIDsPendingDeletion = try container.decodeIfPresent(
            [String].self,
            forKey: .keychainItemIDsPendingDeletion
        ) ?? []
        credentialDisconnectPending = try container.decodeIfPresent(
            Bool.self,
            forKey: .credentialDisconnectPending
        ) ?? false
        if container.contains(.credentialAuthorizationRevoked) {
            credentialAuthorizationRevoked = try container.decode(
                Bool.self,
                forKey: .credentialAuthorizationRevoked
            )
        } else {
            // Before this durable gate existed, an active state containing an
            // auth-revoked link could only belong to the rejected credential.
            credentialAuthorizationRevoked = status == .active && links.contains {
                $0.status == .paused && $0.pauseReason == .authRevoked
            }
        }
        let decodedDisconnectIdentities = try container.decodeIfPresent(
            [String].self,
            forKey: .disconnectPausedLinkIdentities
        ) ?? []
        let decodedAuthorizationIdentities = try container.decodeIfPresent(
            [String].self,
            forKey: .authRevokedLinkIdentitiesAwaitingReconnect
        ) ?? []
        let decodedIdentityVersion = try container.decodeIfPresent(
            Int.self,
            forKey: .linkIdentityEncodingVersion
        )
        linkIdentityEncodingVersion = Self.currentLinkIdentityEncodingVersion
        if decodedIdentityVersion == nil {
            disconnectPausedLinkIdentities = Self.migrateLegacyProvenance(
                decodedDisconnectIdentities,
                links: links
            )
            authRevokedLinkIdentitiesAwaitingReconnect = Self.migrateLegacyProvenance(
                decodedAuthorizationIdentities,
                links: links
            )
        } else if decodedIdentityVersion == Self.currentLinkIdentityEncodingVersion {
            disconnectPausedLinkIdentities = Self.validateCurrentProvenance(
                decodedDisconnectIdentities,
                links: links
            )
            authRevokedLinkIdentitiesAwaitingReconnect = Self.validateCurrentProvenance(
                decodedAuthorizationIdentities,
                links: links
            )
        } else {
            // A future/unknown provenance encoding must remain auditable but
            // inert; interpreting it as this version could resume a different
            // provider-controlled link.
            disconnectPausedLinkIdentities = Self.makeProvenanceInert(decodedDisconnectIdentities)
            authRevokedLinkIdentitiesAwaitingReconnect = Self.makeProvenanceInert(
                decodedAuthorizationIdentities
            )
        }
    }

    /// Encoding re-sanitizes as a defense-in-depth persistence boundary in
    /// addition to the private setter and redacting mutation APIs.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(keychainItemID, forKey: .keychainItemID)
        try container.encode(baseHost, forKey: .baseHost)
        try container.encode(basePort, forKey: .basePort)
        try container.encode(credentialGeneration, forKey: .credentialGeneration)
        try container.encode(createdAtEpoch, forKey: .createdAtEpoch)
        try container.encodeIfPresent(lastSuccessfulSyncAtEpoch, forKey: .lastSuccessfulSyncAtEpoch)
        try container.encodeIfPresent(retryNotBeforeEpoch, forKey: .retryNotBeforeEpoch)
        try container.encodeIfPresent(
            lastErrorRedacted.map { SimpleFINDiagnosticRedactor.redact($0) },
            forKey: .lastErrorRedacted
        )
        try container.encode(links, forKey: .links)
        try container.encode(extraTrustedHosts, forKey: .extraTrustedHosts)
        try container.encodeIfPresent(
            pendingCredentialReplacement,
            forKey: .pendingCredentialReplacement
        )
        try container.encode(keychainItemIDsPendingDeletion, forKey: .keychainItemIDsPendingDeletion)
        try container.encode(credentialDisconnectPending, forKey: .credentialDisconnectPending)
        try container.encode(credentialAuthorizationRevoked, forKey: .credentialAuthorizationRevoked)
        try container.encode(disconnectPausedLinkIdentities, forKey: .disconnectPausedLinkIdentities)
        try container.encode(
            authRevokedLinkIdentitiesAwaitingReconnect,
            forKey: .authRevokedLinkIdentitiesAwaitingReconnect
        )
        try container.encode(
            Self.currentLinkIdentityEncodingVersion,
            forKey: .linkIdentityEncodingVersion
        )
    }

    public func link(identity: String) -> SimpleFINAccountLink? {
        links.first { $0.identity == identity }
    }

    public var linksByIdentity: [String: SimpleFINAccountLink] {
        Dictionary(grouping: links, by: \.identity).compactMapValues { values in
            values.count == 1 ? values.first : nil
        }
    }

    /// Records a non-official host only after the caller has obtained an
    /// explicit user confirmation. The list is durable, idempotent, and
    /// deterministic so a beta/test endpoint can be retried without widening
    /// the global trust boundary.
    public mutating func addTrustedHost(_ host: SimpleFINHost) {
        guard host.host != SimpleFINURLValidator.officialBridgeHost,
              !extraTrustedHosts.contains(host) else { return }
        extraTrustedHosts.append(host)
        extraTrustedHosts.sort {
            ($0.host, $0.port) < ($1.host, $1.port)
        }
    }

    /// Returns a pin only while requests are allowed to start. A pending
    /// disconnect or rejected authorization invalidates the connection before
    /// any Keychain reference is cleared, so new and in-flight work cannot
    /// commit through either retry window.
    public var activeCredentialPin: SimpleFINConnectionPin? {
        guard status == .active,
              !credentialDisconnectPending,
              !credentialAuthorizationRevoked,
              let keychainItemID else { return nil }
        return SimpleFINConnectionPin(
            itemID: keychainItemID,
            credentialGeneration: credentialGeneration
        )
    }

    public func matchesActiveCredential(_ pin: SimpleFINConnectionPin) -> Bool {
        activeCredentialPin == pin
    }

    public func wasPausedByFullDisconnect(identity: String) -> Bool {
        disconnectPausedLinkIdentities.contains(identity)
    }

    public func canManuallyResumeLink(identity: String) -> Bool {
        activeCredentialPin != nil
            && !disconnectPausedLinkIdentities.contains(identity)
            && !authRevokedLinkIdentitiesAwaitingReconnect.contains(identity)
            && link(identity: identity)?.pauseReason != .authRevoked
            && link(identity: identity)?.pauseReason != .snapshotDiscrepancy
    }

    public var hasLinksAwaitingReconnectValidation: Bool {
        let liveIdentities = Set(links.map(\.identity))
        return disconnectPausedLinkIdentities.contains { liveIdentities.contains($0) }
            || authRevokedLinkIdentitiesAwaitingReconnect.contains { liveIdentities.contains($0) }
    }

    /// Finalizes the link side of a successful full disconnect. Existing hard
    /// pause reasons and diagnostics stay intact; only links that were active
    /// gain reconnect provenance. Repeated calls are idempotent.
    public mutating func pauseAllLinksForFullDisconnect() {
        var awaitingReconnect = Set(disconnectPausedLinkIdentities)
        for index in links.indices {
            if links[index].status == .active {
                awaitingReconnect.insert(links[index].identity)
            }
            links[index].status = .paused
        }
        disconnectPausedLinkIdentities = awaitingReconnect.sorted()
    }

    /// Invalidates every request pinned to the current credential after an
    /// accounts 401/403 and hard-pauses each active link. The fixed diagnostic
    /// contains no response, URL, host, or credential material.
    public mutating func markCredentialAuthorizationRevoked() {
        var awaitingReconnect = Set(disconnectPausedLinkIdentities)
        for index in links.indices where links[index].status == .active {
            awaitingReconnect.remove(links[index].identity)
            links[index].pause(
                reason: .authRevoked,
                message: "Access is no longer authorized; reconnect with a new Setup Token."
            )
        }
        disconnectPausedLinkIdentities = awaitingReconnect.sorted()
        authRevokedLinkIdentitiesAwaitingReconnect = []
        credentialAuthorizationRevoked = true
    }

    /// Applies a validated, generation-pinned discovery result. Links paused
    /// by the full disconnect resume only when their exact remote identity is
    /// present. `authRevoked` is likewise cleared only after an identity match;
    /// every other hard pause remains unchanged and auditable.
    @discardableResult
    public mutating func reactivateLinksAfterIdentityMatch(
        _ remoteIdentities: Set<String>
    ) -> [String] {
        // Defense in depth for any future caller: identity matching cannot
        // bypass a pending disconnect or an authorization-rejected generation.
        guard activeCredentialPin != nil else { return [] }
        var awaitingReconnect = Set(disconnectPausedLinkIdentities)
        var awaitingAuthorizationReconnect = Set(authRevokedLinkIdentitiesAwaitingReconnect)
        var reactivated: [String] = []

        for index in links.indices {
            let identity = links[index].identity
            guard remoteIdentities.contains(identity) else { continue }

            let wasDisconnectPaused = awaitingReconnect.remove(identity) != nil
            let hasNewCredentialForAuthorization = awaitingAuthorizationReconnect.remove(identity) != nil
            guard wasDisconnectPaused || hasNewCredentialForAuthorization else { continue }

            if links[index].status == .paused,
               links[index].pauseReason == .authRevoked,
               hasNewCredentialForAuthorization {
                links[index].resume()
                reactivated.append(identity)
            } else if wasDisconnectPaused {
                switch links[index].pauseReason {
                case nil, .closedMonthImportPending:
                    links[index].status = .active
                    reactivated.append(identity)
                default:
                    // A hard pause acquired after the disconnect supersedes
                    // automatic reconnect, while its reason remains intact.
                    break
                }
            }
        }

        disconnectPausedLinkIdentities = awaitingReconnect.sorted()
        authRevokedLinkIdentitiesAwaitingReconnect = awaitingAuthorizationReconnect.sorted()
        return reactivated.sorted()
    }

    /// Credential cleanup failures take precedence over ordinary sync status
    /// until every superseded Keychain reference has been cleared. Otherwise
    /// a successful or failed sync could make a retryable deletion failure
    /// disappear from the UI while cleanup is still pending.
    public mutating func clearLastErrorAfterSuccessfulSync() {
        guard keychainItemIDsPendingDeletion.isEmpty else { return }
        lastErrorRedacted = nil
    }

    public func isSyncDeferred(at epoch: Int64) -> Bool {
        guard let retryNotBeforeEpoch else { return false }
        return epoch < retryNotBeforeEpoch
    }

    public mutating func deferSync(until epoch: Int64) {
        retryNotBeforeEpoch = max(retryNotBeforeEpoch ?? Int64.min, epoch)
    }

    public mutating func clearExpiredSyncDeferral(at epoch: Int64) {
        if let retryNotBeforeEpoch, epoch >= retryNotBeforeEpoch {
            self.retryNotBeforeEpoch = nil
        }
    }

    public mutating func recordConnectionSyncError(_ message: String) {
        guard keychainItemIDsPendingDeletion.isEmpty else { return }
        lastErrorRedacted = SimpleFINDiagnosticRedactor.redact(message)
    }

    /// Credential lifecycle diagnostics intentionally bypass sync cleanup
    /// precedence, but never bypass redaction.
    public mutating func recordCredentialLifecycleError(_ message: String) {
        lastErrorRedacted = SimpleFINDiagnosticRedactor.redact(message)
    }

    public mutating func clearCredentialLifecycleError() {
        lastErrorRedacted = nil
    }

    /// Persists an errored provider response without changing the link cursor,
    /// connection success timestamp, or connection-level diagnostic. Returns
    /// false if the link disappeared between the network response and commit.
    @discardableResult
    public mutating func recordProviderErrors(
        _ errors: [String],
        forLinkIdentity identity: String
    ) -> Bool {
        guard !errors.isEmpty,
              let index = links.firstIndex(where: { $0.identity == identity }) else {
            return false
        }
        links[index].recordSyncError(
            "Provider messages: \(SimpleFINDiagnosticRedactor.summary(errors))"
        )
        return true
    }

    @discardableResult
    public mutating func upsertLink(_ link: SimpleFINAccountLink) -> Bool {
        // A bound local account may have only one remote identity per
        // connection. Account-less paused links remain intentionally
        // multi-valued until the user resolves them.
        if let localAccountID = link.localAccountID,
           links.contains(where: {
               $0.identity != link.identity
                   && $0.localAccountID == localAccountID
           }) {
            return false
        }

        // Any explicit later link mutation supersedes pending automatic
        // reconnect provenance. Full-disconnect pausing and identity-matched
        // reactivation mutate the stored array directly and restore their
        // provenance deliberately.
        disconnectPausedLinkIdentities.removeAll { $0 == link.identity }
        authRevokedLinkIdentitiesAwaitingReconnect.removeAll { $0 == link.identity }
        if let index = links.firstIndex(where: { $0.identity == link.identity }) {
            links[index] = link
        } else {
            links.append(link)
            links.sort { $0.identity < $1.identity }
        }
        return true
    }

    public mutating func upsertLinkOrThrow(_ link: SimpleFINAccountLink) throws {
        guard upsertLink(link) else {
            throw SimpleFINLinkInvariantError.localAccountAlreadyLinked
        }
    }

    private static func migrateLegacyProvenance(
        _ identities: [String],
        links: [SimpleFINAccountLink]
    ) -> [String] {
        let migrated = identities.map { legacyIdentity -> String in
            let matches = links.filter {
                SimpleFINAccountLink.legacyIdentity(
                    connectionKey: $0.connectionKey,
                    remoteAccountID: $0.remoteAccountID
                ) == legacyIdentity
            }
            guard matches.count == 1, let match = matches.first else {
                return inertProvenanceIdentity(legacyIdentity)
            }
            return match.identity
        }
        return Array(Set(migrated)).sorted()
    }

    /// Current-version provenance is live only when exactly one decoded link
    /// owns the identity. Unknown or duplicate-link values remain auditable as
    /// inert markers and cannot participate in reconnect matching.
    private static func validateCurrentProvenance(
        _ identities: [String],
        links: [SimpleFINAccountLink]
    ) -> [String] {
        let identityCounts = Dictionary(grouping: links, by: \.identity).mapValues(\.count)
        let validated = identities.map { identity in
            if identity.hasPrefix("simplefin-link:unmatched:v1:") {
                return identity
            }
            guard identityCounts[identity] == 1 else {
                return inertProvenanceIdentity(identity)
            }
            return identity
        }
        return Array(Set(validated)).sorted()
    }

    private static func makeProvenanceInert(_ identities: [String]) -> [String] {
        Array(Set(identities.map(inertProvenanceIdentity))).sorted()
    }

    /// Namespaces an unmatched legacy/future value away from current canonical
    /// identities. The payload remains deterministic and reversible for audit,
    /// but can never compare equal to a live link identity.
    private static func inertProvenanceIdentity(_ identity: String) -> String {
        if identity.hasPrefix("simplefin-link:unmatched:v1:") {
            return identity
        }
        let encoded = Data(identity.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "simplefin-link:unmatched:v1:\(encoded)"
    }
}

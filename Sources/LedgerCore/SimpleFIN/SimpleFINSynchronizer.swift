import Foundation

public enum SimpleFINLinkStatus: String, Codable, Sendable, Equatable {
    case active
    case paused
}

/// §2.1 SimpleFINLink pause reasons. A `paused` link is skipped by sync until
/// the user (or a successful reconnect, for `authRevoked`) reactivates it.
/// `closedMonthImportPending` is informational: the link stays `active` and
/// keeps syncing; the reason is a visible badge until no unresolved
/// `closedMonthImport` staged rows remain for the account.
public enum SimpleFINLinkPauseReason: String, Codable, Sendable, Equatable, CaseIterable {
    case futurePostedEpoch
    case positiveCardSnapshot
    case unconfirmedSignDirection
    case duplicateRemoteIdentity
    case missingStableConnectionKey
    case currencyMismatch
    case authRevoked
    case closedMonthImportPending
    case snapshotDiscrepancy
    case protocolError
}

public struct SimpleFINAccountLink: Codable, Sendable, Equatable {
    public var connectionKey: String
    public var remoteAccountID: String
    /// Nil for a paused, account-less link (§4.4 step 6: a positive computed
    /// card opening must persist `positiveCardSnapshot` even though no legal
    /// local account can exist to bind). The v1 `simplefin_links` column is
    /// nullable for the same reason. An unbound link never syncs; re-linking
    /// the same remote identity binds an account via the identity upsert.
    public var localAccountID: AccountID?
    public var signNormalization: SimpleFINSignNormalization
    public var lastSuccessfulPostedEpoch: Int64?
    public var status: SimpleFINLinkStatus
    public var pauseReason: SimpleFINLinkPauseReason?
    /// Sanitized per-link error summary only — never URLs, userinfo, tokens,
    /// or hosts combined with credentials.
    public private(set) var lastErrorRedacted: String?

    public init(
        connectionKey: String,
        remoteAccountID: String,
        localAccountID: AccountID?,
        signNormalization: SimpleFINSignNormalization = .normal,
        lastSuccessfulPostedEpoch: Int64? = nil,
        status: SimpleFINLinkStatus = .active,
        pauseReason: SimpleFINLinkPauseReason? = nil,
        lastErrorRedacted: String? = nil
    ) {
        self.connectionKey = connectionKey
        self.remoteAccountID = remoteAccountID
        self.localAccountID = localAccountID
        self.signNormalization = signNormalization
        self.lastSuccessfulPostedEpoch = lastSuccessfulPostedEpoch
        self.status = status
        self.pauseReason = pauseReason
        self.lastErrorRedacted = lastErrorRedacted.map { SimpleFINDiagnosticRedactor.redact($0) }
    }

    enum CodingKeys: String, CodingKey {
        case connectionKey
        case remoteAccountID
        case localAccountID
        case signNormalization
        case lastSuccessfulPostedEpoch
        case status
        case pauseReason
        case lastErrorRedacted
    }

    /// Custom decode so state blobs written before the pause state machine
    /// existed still load (`status` defaults to `.active`).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.connectionKey = try container.decode(String.self, forKey: .connectionKey)
        self.remoteAccountID = try container.decode(String.self, forKey: .remoteAccountID)
        self.localAccountID = try container.decodeIfPresent(AccountID.self, forKey: .localAccountID)
        self.signNormalization = try container.decode(SimpleFINSignNormalization.self, forKey: .signNormalization)
        self.lastSuccessfulPostedEpoch = try container.decodeIfPresent(Int64.self, forKey: .lastSuccessfulPostedEpoch)
        self.status = try container.decodeIfPresent(SimpleFINLinkStatus.self, forKey: .status) ?? .active
        self.pauseReason = try container.decodeIfPresent(SimpleFINLinkPauseReason.self, forKey: .pauseReason)
        self.lastErrorRedacted = try container.decodeIfPresent(String.self, forKey: .lastErrorRedacted)
            .map { SimpleFINDiagnosticRedactor.redact($0) }
    }

    /// Serialization remains a defense-in-depth persistence boundary in
    /// addition to the private setter and redacting mutation APIs.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(connectionKey, forKey: .connectionKey)
        try container.encode(remoteAccountID, forKey: .remoteAccountID)
        try container.encodeIfPresent(localAccountID, forKey: .localAccountID)
        try container.encode(signNormalization, forKey: .signNormalization)
        try container.encodeIfPresent(lastSuccessfulPostedEpoch, forKey: .lastSuccessfulPostedEpoch)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(pauseReason, forKey: .pauseReason)
        try container.encodeIfPresent(
            lastErrorRedacted.map { SimpleFINDiagnosticRedactor.redact($0) },
            forKey: .lastErrorRedacted
        )
    }

    /// Hard pause: sync skips this link until it is explicitly resumed.
    public mutating func pause(reason: SimpleFINLinkPauseReason, message: String? = nil) {
        status = .paused
        pauseReason = reason
        if let message {
            recordSyncError(message)
        }
    }

    public mutating func resume() {
        status = .active
        pauseReason = nil
        clearSyncError()
    }

    /// Clears only a pause created by an unresolved snapshot discrepancy.
    /// Unlike `resume()`, this deliberately preserves any diagnostic text so a
    /// resolution cannot erase unrelated provider or lifecycle information.
    @discardableResult
    public mutating func clearSnapshotDiscrepancyPause() -> Bool {
        guard pauseReason == .snapshotDiscrepancy else { return false }
        status = .active
        pauseReason = nil
        return true
    }

    /// The only ordinary per-link diagnostic mutation path. Provider text is
    /// sanitized before it becomes readable by an in-memory UI.
    public mutating func recordSyncError(_ message: String) {
        lastErrorRedacted = SimpleFINDiagnosticRedactor.redact(message)
    }

    public mutating func clearSyncError() {
        lastErrorRedacted = nil
    }

    public var identity: String {
        Self.identity(connectionKey: connectionKey, remoteAccountID: remoteAccountID)
    }

    /// Versioned, injective UTF-8 tuple encoding. Each component is prefixed
    /// by its UTF-8 byte length and `:`, so delimiter characters inside either
    /// provider-controlled component cannot change the tuple boundary.
    ///
    /// Wire form: `simplefin-link:v1:<n>:<connection><m>:<account>`.
    public static func identity(connectionKey: String, remoteAccountID: String) -> String {
        "simplefin-link:v1:"
            + lengthPrefixedIdentityComponent(connectionKey)
            + lengthPrefixedIdentityComponent(remoteAccountID)
    }

    /// Pre-M5.8.1 persisted reconnect provenance used delimiter concatenation.
    /// It is retained only for decode-time migration and must never be used as
    /// a current identity or comparison key.
    static func legacyIdentity(connectionKey: String, remoteAccountID: String) -> String {
        "\(connectionKey)|\(remoteAccountID)"
    }

    private static func lengthPrefixedIdentityComponent(_ value: String) -> String {
        "\(value.utf8.count):\(value)"
    }
}

/// Fixed, non-secret policy failures for SimpleFIN amount normalization.
/// The error deliberately carries no account names, remote identities, URLs,
/// or provider payloads so it is safe to map into diagnostics and UI text.
public enum SimpleFINSignNormalizationError: Error, Equatable, Sendable {
    case invertedCashLikeAccount
}

/// First-link validation, gating, and arithmetic. Recurring and initial-link
/// response application lives in `SimpleFINSyncEngine.applyAccountSync`.
public enum SimpleFINSynchronizer {
    /// §4.2: checking, savings, and cash use the provider's normal convention
    /// in v1. Credit cards retain both confirmed conventions. The specification
    /// does not define an additional rule for off-budget `.other` accounts, so
    /// this bounded policy leaves their existing behavior unchanged.
    public static func validateSignNormalization(
        accountType: AccountType,
        signNormalization: SimpleFINSignNormalization
    ) throws {
        guard !(accountType.isCashLike && signNormalization == .inverted) else {
            throw SimpleFINSignNormalizationError.invertedCashLikeAccount
        }
    }

    /// §4.4/§4.5 pre-mutation gate for the initial link: every rule that
    /// would otherwise surface as an in-transaction pause is checked here,
    /// BEFORE any account creation or cursor advancement. Throws typed,
    /// redacted sign-policy or protocol errors; returns the single account
    /// block matching the requested identity. Pending and `posted == 0` rows
    /// are remote-protocol artifacts excluded by design (§4.4 step 2) and are
    /// skipped, not validated; rows in non-matching blocks are ignored.
    public static func validateInitialLinkResponse(
        response: SimpleFINAccountsResponse,
        connectionKey: String,
        remoteAccountID: String,
        accountType: AccountType,
        signNormalization: SimpleFINSignNormalization,
        calendar: BudgetCalendar,
        nowEpoch: Int64
    ) throws -> SimpleFINRemoteAccount {
        try validateSignNormalization(
            accountType: accountType,
            signNormalization: signNormalization
        )

        // A response the provider itself marks as errored must never mint an
        // opening balance or advance a cursor (§4.5).
        guard response.errors.isEmpty else {
            throw SimpleFINProtocolError.providerReportedErrors(response.errors)
        }

        var matching: [SimpleFINRemoteAccount] = []
        for account in response.accounts where account.id == remoteAccountID {
            let key = try account.remoteConnectionKey() // rethrows missingStableRemoteIdentity
            if key == connectionKey { matching.append(account) }
        }
        guard matching.count <= 1 else {
            throw SimpleFINProtocolError.duplicateRemoteAccountIdentity(
                SimpleFINAccountLink.identity(connectionKey: connectionKey, remoteAccountID: remoteAccountID)
            )
        }
        // An absent block is not empty history: treating it as such would
        // compute `opening = B` and permanently skip real history behind
        // cursor T.
        guard let block = matching.first else {
            throw SimpleFINProtocolError.missingRequestedAccount
        }

        guard let today = calendar.budgetDate(fromEpoch: nowEpoch) else {
            throw SimpleFINProtocolError.invalidResponse("unrepresentable current date")
        }
        let multiplier = Int64(signNormalization.rawValue)
        for row in block.transactions {
            if row.pending || row.postedEpoch == 0 { continue }
            guard let id = row.id, !id.isEmpty else {
                throw SimpleFINProtocolError.missingRemoteTransactionID
            }
            let parsed: Milliunits
            do {
                parsed = try MoneyParser.milliunits(fromDecimalString: row.amount)
            } catch {
                throw SimpleFINProtocolError.invalidResponse("malformed posted amount")
            }
            let normalized = parsed.multipliedReportingOverflow(by: multiplier)
            guard !normalized.overflow else { throw SimpleFINProtocolError.arithmeticOverflow }
            guard let rowDate = calendar.budgetDate(fromEpoch: row.postedEpoch), rowDate <= today else {
                throw SimpleFINProtocolError.futurePostedEpoch
            }
        }

        // Pre-parse the snapshot balance whenever a comparison will run, so a
        // malformed balance cannot become an in-transaction engine pause.
        if block.balanceDateEpoch ?? response.balanceDateEpoch != nil {
            let parsedBalance: Milliunits
            do {
                parsedBalance = try MoneyParser.milliunits(fromDecimalString: block.balance)
            } catch {
                throw SimpleFINProtocolError.invalidResponse("malformed balance")
            }
            let normalizedBalance = parsedBalance.multipliedReportingOverflow(by: multiplier)
            guard !normalizedBalance.overflow else { throw SimpleFINProtocolError.arithmeticOverflow }
        }
        return block
    }

    /// §4.4 step 6 gate, deliberately mirroring `addAccount`'s `eligible`
    /// predicate (on-budget + currency match) so the pre-check and the
    /// workspace guard can never disagree: a positive computed card opening
    /// cannot be normalized into v1 and must become a persisted, account-less
    /// `positiveCardSnapshot` pause instead of a failed mutation.
    public static func positiveCardOpeningRequiresAccountlessPause(
        accountType: AccountType,
        onBudget: Bool,
        accountCurrency: String,
        budgetCurrency: String,
        openingMilliunits: Milliunits
    ) -> Bool {
        accountType == .creditCard
            && onBudget
            && accountCurrency == budgetCurrency
            && openingMilliunits > 0
    }

    /// Computes the deterministic opening anchor used by first-link setup
    /// (§4.4): sign-normalized provider balance minus all normalized posted
    /// history in the exact `(S, T]` interval. Both sides of the subtraction
    /// use the link's confirmed sign direction — an inverted provider's
    /// snapshot must be flipped exactly like its transaction amounts, or the
    /// computed opening double-counts the inversion. Pending and future rows
    /// are never eligible.
    public static func initialLinkCalculation(
        snapshotBalanceDecimalString: String,
        history: [SimpleFINRemoteTransaction],
        accountType: AccountType,
        signNormalization: SimpleFINSignNormalization,
        startEpoch: Int64,
        balanceDateEpoch: Int64
    ) throws -> SimpleFINInitialLinkCalculation {
        try validateSignNormalization(
            accountType: accountType,
            signNormalization: signNormalization
        )

        var total: Milliunits = 0
        var IDs: [String] = []
        let multiplier = Int64(signNormalization.rawValue)
        for transaction in history.sorted(by: { ($0.postedEpoch, $0.id ?? "") < ($1.postedEpoch, $1.id ?? "") }) {
            // §4.4 step 2: remote-pending rows are excluded, not fatal — the
            // calculation now receives the unfiltered block rows.
            guard !transaction.pending else { continue }
            guard transaction.postedEpoch > startEpoch, transaction.postedEpoch <= balanceDateEpoch else { continue }
            guard let id = transaction.id, !id.isEmpty else { throw SimpleFINProtocolError.missingRemoteTransactionID }
            let parsed = try MoneyParser.milliunits(fromDecimalString: transaction.amount)
            let normalized = parsed.multipliedReportingOverflow(by: multiplier)
            guard !normalized.overflow else { throw SimpleFINProtocolError.arithmeticOverflow }
            let sum = total.addingReportingOverflow(normalized.partialValue)
            guard !sum.overflow else { throw SimpleFINProtocolError.arithmeticOverflow }
            total = sum.partialValue
            IDs.append(id)
        }
        let parsedBalance = try MoneyParser.milliunits(fromDecimalString: snapshotBalanceDecimalString)
        let normalizedBalance = parsedBalance.multipliedReportingOverflow(by: multiplier)
        guard !normalizedBalance.overflow else { throw SimpleFINProtocolError.arithmeticOverflow }
        let opening = normalizedBalance.partialValue.subtractingReportingOverflow(total)
        guard !opening.overflow else { throw SimpleFINProtocolError.arithmeticOverflow }
        return SimpleFINInitialLinkCalculation(
            openingBalanceDecimalString: decimalString(from: opening.partialValue),
            normalizedHistoryTotalDecimalString: decimalString(from: total),
            importedTransactionIDs: IDs,
            historyStartEpoch: startEpoch,
            balanceDateEpoch: balanceDateEpoch
        )
    }

    private static func decimalString(from milliunits: Milliunits) -> String {
        let decimal = Decimal(milliunits) / Decimal(1000)
        return NSDecimalNumber(decimal: decimal).stringValue
    }
}

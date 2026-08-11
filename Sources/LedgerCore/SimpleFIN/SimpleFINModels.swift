import Foundation

public extension SimpleFINCredential {
    var description: String { "[REDACTED SimpleFIN credential]" }
    var debugDescription: String { "[REDACTED SimpleFIN credential]" }
}

extension SimpleFINCredential: CustomStringConvertible, CustomDebugStringConvertible {}

public enum SimpleFINProtocolError: Error, Equatable, Sendable {
    case invalidSetupToken
    case invalidClaimEndpoint
    case untrustedHost(String)
    case invalidAccessURL
    case unsupportedPort
    case missingCredential
    case invalidResponse(String)
    case missingStableRemoteIdentity
    case duplicateRemoteAccountIdentity(String)
    case unlinkedRemoteAccount(String)
    case currencyMismatch
    case missingRemoteTransactionID
    case futurePostedEpoch
    case arithmeticOverflow
    case pendingRowsExcluded
    /// The provider reported errors (`errors`/`errlist`); the response must
    /// not be used to derive an opening balance or advance a cursor (§4.5).
    /// Values originating from `SimpleFINAccountsResponse` are already
    /// boundary-redacted and bounded.
    case providerReportedErrors([String])
    /// A per-account request returned a response without the requested
    /// account block; treating it as empty history would mint a wrong opening.
    case missingRequestedAccount
}

public struct SimpleFINHost: Hashable, Codable, Sendable, Equatable {
    public private(set) var host: String
    public private(set) var port: Int

    public init(host: String, port: Int = 443) throws {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty, port > 0, port <= 65_535 else {
            throw SimpleFINProtocolError.unsupportedPort
        }
        self.host = normalized
        self.port = port
    }
}

public struct SimpleFINQueryItem: Codable, Sendable, Equatable, Hashable {
    public var name: String
    public var value: String?

    public init(name: String, value: String?) {
        self.name = name
        self.value = value
    }
}

/// Structured Access URL material. Its CustomStringConvertible and
/// CustomDebugStringConvertible conformances are intentionally redacted so
/// credentials cannot enter diagnostics.
public struct SimpleFINCredential: Codable, Sendable, Equatable {
    public private(set) var host: SimpleFINHost
    public private(set) var opaquePercentEncodedPathPrefix: String
    public private(set) var existingQueryItems: [SimpleFINQueryItem]
    public private(set) var existingPercentEncodedQuery: String?
    public private(set) var username: String
    public private(set) var password: String
    public private(set) var approvedHost: SimpleFINHost

    private enum CodingKeys: String, CodingKey {
        case host
        case opaquePercentEncodedPathPrefix
        case existingQueryItems
        case existingPercentEncodedQuery
        case username
        case password
        case approvedHost
    }

    public init(
        host: SimpleFINHost,
        opaquePercentEncodedPathPrefix: String,
        existingQueryItems: [SimpleFINQueryItem],
        existingPercentEncodedQuery: String?,
        username: String,
        password: String,
        approvedHost: SimpleFINHost
    ) throws {
        guard !opaquePercentEncodedPathPrefix.isEmpty,
              !username.isEmpty,
              !password.isEmpty,
              opaquePercentEncodedPathPrefix.hasPrefix("/"),
              !Self.containsDotSegment(opaquePercentEncodedPathPrefix) else {
            throw SimpleFINProtocolError.invalidAccessURL
        }
        self.host = host
        self.opaquePercentEncodedPathPrefix = opaquePercentEncodedPathPrefix
        self.existingQueryItems = existingQueryItems
        self.existingPercentEncodedQuery = existingPercentEncodedQuery
        self.username = username
        self.password = password
        self.approvedHost = approvedHost
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            host: container.decode(SimpleFINHost.self, forKey: .host),
            opaquePercentEncodedPathPrefix: container.decode(String.self, forKey: .opaquePercentEncodedPathPrefix),
            existingQueryItems: container.decode([SimpleFINQueryItem].self, forKey: .existingQueryItems),
            existingPercentEncodedQuery: container.decodeIfPresent(String.self, forKey: .existingPercentEncodedQuery),
            username: container.decode(String.self, forKey: .username),
            password: container.decode(String.self, forKey: .password),
            approvedHost: container.decode(SimpleFINHost.self, forKey: .approvedHost)
        )
    }

    private static func containsDotSegment(_ path: String) -> Bool {
        path.split(separator: "/", omittingEmptySubsequences: false).contains { segment in
            guard let decoded = String(segment).removingPercentEncoding else { return true }
            return decoded == "." || decoded == ".."
        }
    }
}

public struct SimpleFINRemoteOrganization: Decodable, Sendable, Equatable {
    public var id: String?
    public var domain: String?
    public var name: String?

    public init(id: String? = nil, domain: String? = nil, name: String? = nil) {
        self.id = id
        self.domain = domain
        self.name = name
    }

    public var stableKey: String? {
        if let id = normalized(id) { return "org-id:\(id)" }
        if let domain = normalized(domain) { return "org-domain:\(domain)" }
        return nil
    }

    private func normalized(_ value: String?) -> String? {
        guard let raw = value else { return nil }
        let normalized = raw.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized.isEmpty ? nil : normalized
    }
}

public struct SimpleFINRemoteTransaction: Decodable, Sendable, Equatable {
    public var id: String?
    public var amount: String
    public var postedEpoch: Int64
    public var transactedAtEpoch: Int64?
    public var description: String?
    public var payee: String?
    public var pending: Bool

    public init(
        id: String?,
        amount: String,
        postedEpoch: Int64,
        transactedAtEpoch: Int64? = nil,
        description: String? = nil,
        payee: String? = nil,
        pending: Bool = false
    ) {
        self.id = id
        self.amount = amount
        self.postedEpoch = postedEpoch
        self.transactedAtEpoch = transactedAtEpoch
        self.description = description
        self.payee = payee
        self.pending = pending
    }
}

public struct SimpleFINRemoteAccount: Decodable, Sendable, Equatable {
    public var id: String
    public var name: String?
    public var currency: String
    public var balance: String
    public var availableBalance: String?
    public var balanceDateEpoch: Int64?
    public var organization: SimpleFINRemoteOrganization?
    public var connectionID: String?
    public var transactions: [SimpleFINRemoteTransaction]

    public init(
        id: String,
        name: String? = nil,
        currency: String,
        balance: String,
        availableBalance: String? = nil,
        balanceDateEpoch: Int64? = nil,
        organization: SimpleFINRemoteOrganization? = nil,
        connectionID: String? = nil,
        transactions: [SimpleFINRemoteTransaction] = []
    ) {
        self.id = id
        self.name = name
        self.currency = currency
        self.balance = balance
        self.availableBalance = availableBalance
        self.balanceDateEpoch = balanceDateEpoch
        self.organization = organization
        self.connectionID = connectionID
        self.transactions = transactions
    }

    public func remoteConnectionKey() throws -> String {
        if let connectionID = normalized(connectionID) { return "conn:\(connectionID)" }
        if let key = organization?.stableKey { return key }
        throw SimpleFINProtocolError.missingStableRemoteIdentity
    }

    public var remoteAccountIdentity: String { id }

    private func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized.isEmpty ? nil : normalized
    }
}

public struct SimpleFINAccountsResponse: Decodable, Sendable, Equatable {
    public var accounts: [SimpleFINRemoteAccount]
    public private(set) var errors: [String]
    public var balanceDateEpoch: Int64?

    public init(accounts: [SimpleFINRemoteAccount], errors: [String] = [], balanceDateEpoch: Int64? = nil) throws {
        self.accounts = accounts
        // Provider diagnostics cross into LedgerCore only in sanitized form.
        // The response still records that errors existed; callers must not
        // rebuild an errored response with an empty error list.
        self.errors = SimpleFINDiagnosticRedactor.redact(errors)
        self.balanceDateEpoch = balanceDateEpoch
        try validateUniqueAccountIdentities()
    }

    public func validateUniqueAccountIdentities() throws {
        var seen = Set<String>()
        for account in accounts {
            let key = SimpleFINAccountLink.identity(
                connectionKey: try account.remoteConnectionKey(),
                remoteAccountID: account.remoteAccountIdentity
            )
            guard seen.insert(key).inserted else {
                throw SimpleFINProtocolError.duplicateRemoteAccountIdentity(key)
            }
        }
    }
}

public enum SimpleFINSignNormalization: Int, Codable, Sendable, Equatable {
    case normal = 1
    case inverted = -1
}

public struct SimpleFINRequestWindow: Sendable, Equatable {
    public var startEpoch: Int64
    public var endEpoch: Int64?

    public init(startEpoch: Int64, endEpoch: Int64? = nil) throws {
        if let endEpoch, startEpoch >= endEpoch {
            throw SimpleFINProtocolError.invalidResponse("invalid request window")
        }
        self.startEpoch = startEpoch
        self.endEpoch = endEpoch
    }

    public static func recurring(lastSuccessfulPostedEpoch: Int64) throws -> SimpleFINRequestWindow {
        let overlap = Int64(5) * 86_400
        let start = lastSuccessfulPostedEpoch > Int64.min + overlap
            ? lastSuccessfulPostedEpoch - overlap
            : Int64.min
        return try SimpleFINRequestWindow(startEpoch: start)
    }

    public static func initial(startEpoch: Int64, balanceDateEpoch: Int64, endpointEndDateIsInclusive: Bool) throws -> SimpleFINRequestWindow {
        let end: Int64
        if endpointEndDateIsInclusive {
            end = balanceDateEpoch
        } else {
            end = try checkedAdd(balanceDateEpoch, 1)
        }
        return try SimpleFINRequestWindow(startEpoch: startEpoch, endEpoch: end)
    }

    private static func checkedAdd(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow else { throw SimpleFINProtocolError.arithmeticOverflow }
        return result.partialValue
    }
}

public struct SimpleFINInitialLinkCalculation: Sendable, Equatable {
    public var openingBalanceDecimalString: String
    public var normalizedHistoryTotalDecimalString: String
    public var importedTransactionIDs: [String]
    public var historyStartEpoch: Int64
    public var balanceDateEpoch: Int64

    public init(
        openingBalanceDecimalString: String,
        normalizedHistoryTotalDecimalString: String,
        importedTransactionIDs: [String],
        historyStartEpoch: Int64,
        balanceDateEpoch: Int64
    ) {
        self.openingBalanceDecimalString = openingBalanceDecimalString
        self.normalizedHistoryTotalDecimalString = normalizedHistoryTotalDecimalString
        self.importedTransactionIDs = importedTransactionIDs
        self.historyStartEpoch = historyStartEpoch
        self.balanceDateEpoch = balanceDateEpoch
    }
}

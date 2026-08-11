import Foundation

/// Per-remote-row import identity and last-seen state (§2.1 SimpleFINImport).
/// Exactly one record exists per imported transaction; `source_kind ==
/// .simplefin` iff such a record exists. `remotePayloadHash` is the SHA-256 of
/// the canonical sorted-keys JSON of the normalized remote row and is the
/// change-detection baseline for §4.3 conflict handling. Raw values are stored
/// pre-sign-normalization; no credentials or URLs ever enter this row.
public struct SimpleFINImportRecord: Sendable, Equatable, Codable, Identifiable {
    public var id: SimpleFINImportID
    public var budgetID: BudgetID
    public var transactionID: TransactionID
    public var connectionKey: String
    public var remoteAccountID: String
    public var remoteTransactionID: String
    public var remoteAmountDecimalString: String
    public var remotePostedEpoch: Int64
    public var remoteTransactedEpoch: Int64?
    public var remotePayloadHash: String
    public var protocolVersion: String
    public var lastSeenEpoch: Int64
    public var remoteDisappearanceAcknowledged: Bool

    public init(
        id: SimpleFINImportID = SimpleFINImportID(),
        budgetID: BudgetID,
        transactionID: TransactionID,
        connectionKey: String,
        remoteAccountID: String,
        remoteTransactionID: String,
        remoteAmountDecimalString: String,
        remotePostedEpoch: Int64,
        remoteTransactedEpoch: Int64? = nil,
        remotePayloadHash: String,
        protocolVersion: String = SimpleFINImportRecord.legacyProtocolVersion,
        lastSeenEpoch: Int64,
        remoteDisappearanceAcknowledged: Bool = false
    ) {
        self.id = id
        self.budgetID = budgetID
        self.transactionID = transactionID
        self.connectionKey = connectionKey
        self.remoteAccountID = remoteAccountID
        self.remoteTransactionID = remoteTransactionID
        self.remoteAmountDecimalString = remoteAmountDecimalString
        self.remotePostedEpoch = remotePostedEpoch
        self.remoteTransactedEpoch = remoteTransactedEpoch
        self.remotePayloadHash = remotePayloadHash
        self.protocolVersion = protocolVersion
        self.lastSeenEpoch = lastSeenEpoch
        self.remoteDisappearanceAcknowledged = remoteDisappearanceAcknowledged
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case budgetID
        case transactionID
        case connectionKey
        case remoteAccountID
        case remoteTransactionID
        case remoteAmountDecimalString
        case remotePostedEpoch
        case remoteTransactedEpoch
        case remotePayloadHash
        case protocolVersion
        case lastSeenEpoch
        case remoteDisappearanceAcknowledged
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(SimpleFINImportID.self, forKey: .id),
            budgetID: try container.decode(BudgetID.self, forKey: .budgetID),
            transactionID: try container.decode(TransactionID.self, forKey: .transactionID),
            connectionKey: try container.decode(String.self, forKey: .connectionKey),
            remoteAccountID: try container.decode(String.self, forKey: .remoteAccountID),
            remoteTransactionID: try container.decode(String.self, forKey: .remoteTransactionID),
            remoteAmountDecimalString: try container.decode(String.self, forKey: .remoteAmountDecimalString),
            remotePostedEpoch: try container.decode(Int64.self, forKey: .remotePostedEpoch),
            remoteTransactedEpoch: try container.decodeIfPresent(Int64.self, forKey: .remoteTransactedEpoch),
            remotePayloadHash: try container.decode(String.self, forKey: .remotePayloadHash),
            protocolVersion: try container.decode(String.self, forKey: .protocolVersion),
            lastSeenEpoch: try container.decode(Int64.self, forKey: .lastSeenEpoch),
            remoteDisappearanceAcknowledged: try container.decodeIfPresent(
                Bool.self,
                forKey: .remoteDisappearanceAcknowledged
            ) ?? false
        )
    }

    /// The deployed Bridge response shape has not been pinned by the §4.2
    /// capture gate yet; until then every import records the legacy marker.
    public static let legacyProtocolVersion = "legacy"
}

public enum SyncConflictKind: String, Sendable, Equatable, Codable {
    case remoteChanged
    case remoteDisappeared
    case manualPotentialDuplicate
}

public enum SyncConflictStatus: String, Sendable, Equatable, Codable {
    case open
    case resolved
    case dismissed
}

/// Sanitized side of a `SyncConflictRow`: normalized remote/local facts only —
/// never credentials, Access URLs, hosts, or raw provider payloads.
public struct SyncConflictMetadata: Sendable, Equatable, Codable {
    public var amountDecimalString: String?
    public var postedEpoch: Int64?
    public var transactedEpoch: Int64?
    public var date: String?
    public var payeeDisplay: String?
    public var descriptionText: String?
    public var payloadHash: String?
    public var note: String?

    public init(
        amountDecimalString: String? = nil,
        postedEpoch: Int64? = nil,
        transactedEpoch: Int64? = nil,
        date: String? = nil,
        payeeDisplay: String? = nil,
        descriptionText: String? = nil,
        payloadHash: String? = nil,
        note: String? = nil
    ) {
        self.amountDecimalString = amountDecimalString
        self.postedEpoch = postedEpoch
        self.transactedEpoch = transactedEpoch
        self.date = date
        self.payeeDisplay = payeeDisplay
        self.descriptionText = descriptionText
        self.payloadHash = payloadHash
        self.note = note
    }
}

/// A remote change, disappearance, or duplicate candidate that must not
/// overwrite user-owned data (§2.1/§4.3). The sync engine only creates `open`
/// rows; resolution is an explicit user decision.
public struct SyncConflictRow: Sendable, Equatable, Codable, Identifiable {
    public var id: SyncConflictID
    public var budgetID: BudgetID
    public var transactionID: TransactionID?
    public var simpleFINImportID: SimpleFINImportID?
    public var eventKind: SyncConflictKind
    public var status: SyncConflictStatus
    public var oldMetadata: SyncConflictMetadata
    public var newMetadata: SyncConflictMetadata
    public var createdAtEpoch: Int64
    public var resolvedAtEpoch: Int64?

    public init(
        id: SyncConflictID = SyncConflictID(),
        budgetID: BudgetID,
        transactionID: TransactionID?,
        simpleFINImportID: SimpleFINImportID?,
        eventKind: SyncConflictKind,
        status: SyncConflictStatus = .open,
        oldMetadata: SyncConflictMetadata,
        newMetadata: SyncConflictMetadata,
        createdAtEpoch: Int64,
        resolvedAtEpoch: Int64? = nil
    ) {
        self.id = id
        self.budgetID = budgetID
        self.transactionID = transactionID
        self.simpleFINImportID = simpleFINImportID
        self.eventKind = eventKind
        self.status = status
        self.oldMetadata = oldMetadata
        self.newMetadata = newMetadata
        self.createdAtEpoch = createdAtEpoch
        self.resolvedAtEpoch = resolvedAtEpoch
    }
}

public enum SnapshotDiscrepancyStatus: String, Sendable, Equatable, Codable {
    case open
    case resolved
}

public enum SnapshotDiscrepancyResolutionReason: String, Sendable, Equatable, Codable {
    case adjustment
    case accountClosedOffBudget
    case manualAttestation
}

/// A §4.4 post-sync balance mismatch between the sign-normalized remote
/// snapshot and `registerBalanceAsOf(account, T)`. At most one `open` row per
/// account; the sync engine refreshes it while the mismatch persists and never
/// resolves it on its own ("the sync engine never guesses"). New rows retain
/// the exact SimpleFIN link identity that observed the mismatch so resolution
/// cannot infer a link from a local account alone.
public struct SnapshotDiscrepancyRow: Sendable, Equatable, Codable, Identifiable {
    public var id: SnapshotDiscrepancyID
    public var budgetID: BudgetID
    public var accountID: AccountID
    /// Optional only for pre-M5.9.1 rows. New sync-created rows always carry
    /// the canonical `SimpleFINAccountLink.identity`.
    public var simpleFINLinkIdentity: String?
    public var observedEpoch: Int64
    public var remoteBalanceMilliunits: Milliunits
    public var localRegisterMilliunits: Milliunits
    public var differenceMilliunits: Milliunits
    public var status: SnapshotDiscrepancyStatus
    public var resolutionReason: SnapshotDiscrepancyResolutionReason?
    public var adjustmentTransactionID: TransactionID?
    public var createdAtEpoch: Int64
    public var resolvedAtEpoch: Int64?

    public init(
        id: SnapshotDiscrepancyID = SnapshotDiscrepancyID(),
        budgetID: BudgetID,
        accountID: AccountID,
        simpleFINLinkIdentity: String? = nil,
        observedEpoch: Int64,
        remoteBalanceMilliunits: Milliunits,
        localRegisterMilliunits: Milliunits,
        differenceMilliunits: Milliunits,
        status: SnapshotDiscrepancyStatus = .open,
        resolutionReason: SnapshotDiscrepancyResolutionReason? = nil,
        adjustmentTransactionID: TransactionID? = nil,
        createdAtEpoch: Int64,
        resolvedAtEpoch: Int64? = nil
    ) {
        self.id = id
        self.budgetID = budgetID
        self.accountID = accountID
        self.simpleFINLinkIdentity = simpleFINLinkIdentity
        self.observedEpoch = observedEpoch
        self.remoteBalanceMilliunits = remoteBalanceMilliunits
        self.localRegisterMilliunits = localRegisterMilliunits
        self.differenceMilliunits = differenceMilliunits
        self.status = status
        self.resolutionReason = resolutionReason
        self.adjustmentTransactionID = adjustmentTransactionID
        self.createdAtEpoch = createdAtEpoch
        self.resolvedAtEpoch = resolvedAtEpoch
    }
}

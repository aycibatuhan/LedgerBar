import Foundation

/// Phantom-typed entity identifier. Wraps a UUID; comparison is over the raw
/// 16 bytes so replay tie-breaking is deterministic and locale-independent.
public struct EntityID<Tag: Sendable>: Hashable, Sendable, Comparable, Codable, CustomStringConvertible {
    public let uuid: UUID

    public init(_ uuid: UUID) { self.uuid = uuid }
    public init() { self.uuid = UUID() }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.uuid = try container.decode(UUID.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(uuid)
    }

    public static func < (lhs: EntityID<Tag>, rhs: EntityID<Tag>) -> Bool {
        let a = lhs.uuid.uuid
        let b = rhs.uuid.uuid
        let la = [a.0, a.1, a.2, a.3, a.4, a.5, a.6, a.7, a.8, a.9, a.10, a.11, a.12, a.13, a.14, a.15]
        let lb = [b.0, b.1, b.2, b.3, b.4, b.5, b.6, b.7, b.8, b.9, b.10, b.11, b.12, b.13, b.14, b.15]
        for i in 0..<16 where la[i] != lb[i] {
            return la[i] < lb[i]
        }
        return false
    }

    public var description: String { uuid.uuidString }
}

public enum BudgetTag: Sendable {}
public enum AccountTag: Sendable {}
public enum CategoryGroupTag: Sendable {}
public enum CategoryTag: Sendable {}
public enum PayeeTag: Sendable {}
public enum TransactionTag: Sendable {}
public enum TransferPairTag: Sendable {}
public enum ReconciliationTag: Sendable {}
public enum AuditEventTag: Sendable {}
public enum SimpleFINImportTag: Sendable {}
public enum SyncConflictTag: Sendable {}
public enum SnapshotDiscrepancyTag: Sendable {}
public enum SyncRequestLogTag: Sendable {}

public typealias BudgetID = EntityID<BudgetTag>
public typealias AccountID = EntityID<AccountTag>
public typealias CategoryGroupID = EntityID<CategoryGroupTag>
public typealias CategoryID = EntityID<CategoryTag>
public typealias PayeeID = EntityID<PayeeTag>
public typealias TransactionID = EntityID<TransactionTag>
public typealias TransferPairID = EntityID<TransferPairTag>
public typealias ReconciliationID = EntityID<ReconciliationTag>
public typealias AuditEventID = EntityID<AuditEventTag>
public typealias SimpleFINImportID = EntityID<SimpleFINImportTag>
public typealias SyncConflictID = EntityID<SyncConflictTag>
public typealias SnapshotDiscrepancyID = EntityID<SnapshotDiscrepancyTag>
public typealias SyncRequestLogID = EntityID<SyncRequestLogTag>

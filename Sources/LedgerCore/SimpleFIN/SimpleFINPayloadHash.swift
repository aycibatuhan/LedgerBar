import CryptoKit
import Foundation

/// §2.1 `remote_payload_hash`: SHA-256 of canonical UTF-8 JSON for the
/// normalized remote row using lexicographically sorted keys and no secrets.
/// The canonical form covers exactly the identity-bearing transaction fields;
/// `org`/`extra` and anything credential-adjacent never enter the hash input.
public enum SimpleFINPayloadHash {
    private struct CanonicalRow: Encodable {
        var id: String
        var amount: String
        var posted: Int64
        var transactedAt: Int64?
        var description: String?
        var payee: String?
        var pending: Bool

        enum CodingKeys: String, CodingKey {
            case id
            case amount
            case posted
            case transactedAt = "transacted_at"
            case description
            case payee
            case pending
        }
    }

    public static func canonicalHash(remoteTransactionID: String, transaction: SimpleFINRemoteTransaction) throws -> String {
        let row = CanonicalRow(
            id: remoteTransactionID,
            amount: transaction.amount,
            posted: transaction.postedEpoch,
            transactedAt: transaction.transactedAtEpoch,
            description: transaction.description,
            payee: transaction.payee,
            pending: transaction.pending
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(row)
        return SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    }
}

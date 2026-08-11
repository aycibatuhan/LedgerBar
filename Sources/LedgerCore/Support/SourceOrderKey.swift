import Foundation

/// Stable canonical source-order key (§3.2). One pinned length-prefixed UTF-8
/// encoding; the encoded string never changes after insertion and its
/// lexicographic UTF-8 byte order is part of the deterministic replay order.
///
/// - `remote:<byteLength(connection)>:<connection><byteLength(account)>:<account><byteLength(transaction)>:<transaction>`
/// - `manual:<20-digit-zero-padded-sequence>`
/// - `system:<20-digit-zero-padded-sequence>:<system_kind>`
///
/// Both `manual:` and `system:` sequences draw from the budget's single
/// `next_local_source_sequence` allocator.
public struct SourceOrderKey: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    public let rawValue: String

    /// Wraps an already-encoded key (for example when loading from storage).
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static func remote(connectionKey: String, accountID: String, transactionID: String) -> SourceOrderKey {
        func lengthPrefixed(_ s: String) -> String {
            "\(s.utf8.count):\(s)"
        }
        return SourceOrderKey(
            rawValue: "remote:"
                + lengthPrefixed(connectionKey)
                + lengthPrefixed(accountID)
                + lengthPrefixed(transactionID)
        )
    }

    public static func manual(sequence: Int64) -> SourceOrderKey {
        SourceOrderKey(rawValue: "manual:" + Self.paddedSequence(sequence))
    }

    public static func system(sequence: Int64, systemKind: String) -> SourceOrderKey {
        SourceOrderKey(rawValue: "system:" + Self.paddedSequence(sequence) + ":" + systemKind)
    }

    private static func paddedSequence(_ sequence: Int64) -> String {
        precondition(sequence >= 0, "source sequence is never negative")
        let digits = String(sequence)
        precondition(digits.count <= 20, "source sequence exceeds 20 digits")
        return String(repeating: "0", count: 20 - digits.count) + digits
    }

    /// Deterministic lexicographic comparison over UTF-8 bytes.
    public static func < (lhs: SourceOrderKey, rhs: SourceOrderKey) -> Bool {
        var l = lhs.rawValue.utf8.makeIterator()
        var r = rhs.rawValue.utf8.makeIterator()
        while true {
            switch (l.next(), r.next()) {
            case (nil, nil): return false
            case (nil, _): return true
            case (_, nil): return false
            case let (a?, b?):
                if a != b { return a < b }
            }
        }
    }

    public var description: String { rawValue }
}

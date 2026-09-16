import Foundation

/// Portable, credential-free export of one budget (D8): the workspace
/// snapshot only. SimpleFIN connection state, Keychain references, and
/// projection caches are never included; a re-imported budget re-links
/// bank accounts explicitly.
public struct BudgetExport: Codable, Sendable, Equatable {
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var exportedAtEpoch: Int64
    public var appVersion: String
    public var snapshot: BudgetWorkspaceSnapshot

    public init(snapshot: BudgetWorkspaceSnapshot, exportedAtEpoch: Int64, appVersion: String) {
        self.formatVersion = Self.currentFormatVersion
        self.exportedAtEpoch = exportedAtEpoch
        self.appVersion = appVersion
        self.snapshot = snapshot
    }
}

public enum BudgetTransferError: Error, Equatable, Sendable {
    case unsupportedFormatVersion(Int)
    case malformed
}

public enum BudgetTransfer {
    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return encoder
    }

    public static func encode(_ export: BudgetExport) throws -> Data {
        try encoder.encode(export)
    }

    public static func decode(_ data: Data) throws -> BudgetExport {
        let export: BudgetExport
        do {
            export = try JSONDecoder().decode(BudgetExport.self, from: data)
        } catch {
            throw BudgetTransferError.malformed
        }
        guard export.formatVersion <= BudgetExport.currentFormatVersion else {
            throw BudgetTransferError.unsupportedFormatVersion(export.formatVersion)
        }
        // Prove the snapshot is internally consistent before anyone uses it.
        _ = try BudgetWorkspace(snapshot: export.snapshot)
        return export
    }

    /// Gives every entity in a snapshot a fresh identity while preserving
    /// every reference between them: the snapshot is re-encoded and each
    /// UUID string is replaced consistently. Audit metadata that names ids
    /// is remapped too, so the history still points at the copied rows.
    /// Remote import identities (order keys, provider ids) are not UUIDs and
    /// stay as they are, which is correct: they identify the bank's row.
    public static func remapIdentities(_ snapshot: BudgetWorkspaceSnapshot) throws -> BudgetWorkspaceSnapshot {
        let data = try JSONEncoder().encode(snapshot)
        guard var text = String(data: data, encoding: .utf8) else { throw BudgetTransferError.malformed }
        let pattern = "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
        let regex = try NSRegularExpression(pattern: pattern)
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        var mapping: [String: String] = [:]
        // Replace from the end so ranges stay valid.
        for match in matches.reversed() {
            guard let range = Range(match.range, in: text) else { continue }
            let original = String(text[range]).uppercased()
            let replacement = mapping[original] ?? UUID().uuidString
            mapping[original] = replacement
            text.replaceSubrange(range, with: replacement)
        }
        let remapped = try JSONDecoder().decode(BudgetWorkspaceSnapshot.self, from: Data(text.utf8))
        _ = try BudgetWorkspace(snapshot: remapped)
        return remapped
    }
}

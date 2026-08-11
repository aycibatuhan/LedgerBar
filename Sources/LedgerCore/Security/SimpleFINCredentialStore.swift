import Foundation
import Security

public enum SimpleFINKeychainError: Error, Equatable, Sendable {
    case unexpectedStatus(Int32)
    case itemNotFound
    case invalidStoredData
    case missingAccessGroup
}

public protocol SimpleFINCredentialStore: Sendable {
    /// Verifies that this store can persist an item before a single-use
    /// SimpleFIN Setup Token is sent to the provider. Implementations must not
    /// accept or return credential material from this probe.
    func preflight() throws
    func save(_ credential: SimpleFINCredential, itemID: String) throws
    func load(itemID: String) throws -> SimpleFINCredential
    /// Idempotent deletion contract: an already-absent item is success. The
    /// lifecycle intentionally repeats deletion after crash/database retries.
    func delete(itemID: String) throws
}

public extension SimpleFINCredentialStore {
    /// Synthetic/test stores do not need an OS entitlement probe.
    func preflight() throws {}
}

/// Production credential store. Only the opaque item identifier belongs in
/// SQLite; the serialized credential is stored as a Data Protection generic
/// password item and never appears in logs or process arguments.
public final class KeychainSimpleFINCredentialStore: SimpleFINCredentialStore, @unchecked Sendable {
    public static let service = "com.ledgerbar.simplefin.access"

    private let accessGroup: String?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(accessGroup: String? = nil) {
        self.accessGroup = accessGroup ?? Self.resolvedAccessGroup()
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    /// The single designated group embedded by the signed app target. An
    /// unsigned command-line process cannot resolve this entitlement and must
    /// use the capture tool's protected-input fallback instead of querying an
    /// implicit/default Keychain partition.
    public static func resolvedAccessGroup() -> String? {
        guard let task = SecTaskCreateFromSelf(nil),
              let raw = SecTaskCopyValueForEntitlement(
                  task,
                  "keychain-access-groups" as CFString,
                  nil
              ) as? [String],
              raw.count == 1,
              !raw[0].isEmpty else {
            return nil
        }
        return raw[0]
    }

    public var configuredAccessGroup: String? { accessGroup }

    public func preflight() throws {
        let itemID = "__ledgerbar_preflight_\(UUID().uuidString)"
        let query = try baseQuery(itemID: itemID)
        var attributes = query
        attributes[kSecValueData as String] = Data("ledgerbar-keychain-preflight".utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        attributes[kSecAttrSynchronizable as String] = false
        var itemAdded = false
        defer {
            if itemAdded { _ = SecItemDelete(query as CFDictionary) }
        }

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SimpleFINKeychainError.unexpectedStatus(statusCode(for: status))
        }
        itemAdded = true

        let deleteStatus = SecItemDelete(query as CFDictionary)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            throw SimpleFINKeychainError.unexpectedStatus(statusCode(for: deleteStatus))
        }
        itemAdded = false
    }

    public func save(_ credential: SimpleFINCredential, itemID: String) throws {
        let data = try encoder.encode(credential)
        var attributes = try baseQuery(itemID: itemID)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        attributes[kSecAttrSynchronizable as String] = false
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updateAttributes: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                kSecAttrSynchronizable as String: false
            ]
            let updateStatus = SecItemUpdate(
                try baseQuery(itemID: itemID) as CFDictionary,
                updateAttributes as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                throw SimpleFINKeychainError.unexpectedStatus(statusCode(for: updateStatus))
            }
        } else if status != errSecSuccess {
            throw SimpleFINKeychainError.unexpectedStatus(statusCode(for: status))
        }
    }

    public func load(itemID: String) throws -> SimpleFINCredential {
        var query = try baseQuery(itemID: itemID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status != errSecItemNotFound else { throw SimpleFINKeychainError.itemNotFound }
        guard status == errSecSuccess else {
            throw SimpleFINKeychainError.unexpectedStatus(statusCode(for: status))
        }
        guard let data = result as? Data else { throw SimpleFINKeychainError.invalidStoredData }
        do {
            return try decoder.decode(SimpleFINCredential.self, from: data)
        } catch {
            throw SimpleFINKeychainError.invalidStoredData
        }
    }

    public func delete(itemID: String) throws {
        let status = SecItemDelete(try baseQuery(itemID: itemID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SimpleFINKeychainError.unexpectedStatus(statusCode(for: status))
        }
    }

    private func baseQuery(itemID: String) throws -> [String: Any] {
        guard let accessGroup, !accessGroup.isEmpty else {
            throw SimpleFINKeychainError.missingAccessGroup
        }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: itemID,
            kSecUseDataProtectionKeychain as String: true
        ]
        query[kSecAttrAccessGroup as String] = accessGroup
        return query
    }

    private func statusCode(for status: OSStatus) -> Int32 { Int32(status) }
}

/// Test-only synthetic credential store. It is intentionally in-memory and
/// must never be selected by the production app target.
public final class InMemorySimpleFINCredentialStore: SimpleFINCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: SimpleFINCredential] = [:]

    public init() {}

    public func save(_ credential: SimpleFINCredential, itemID: String) throws {
        lock.lock(); defer { lock.unlock() }
        values[itemID] = credential
    }

    public func load(itemID: String) throws -> SimpleFINCredential {
        lock.lock(); defer { lock.unlock() }
        guard let value = values[itemID] else { throw SimpleFINKeychainError.itemNotFound }
        return value
    }

    public func delete(itemID: String) throws {
        lock.lock(); defer { lock.unlock() }
        values.removeValue(forKey: itemID)
    }
}

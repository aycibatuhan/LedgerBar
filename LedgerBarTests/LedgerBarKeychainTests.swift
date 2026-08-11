import Foundation
import XCTest
import LedgerCore

final class LedgerBarKeychainTests: XCTestCase {
    func testSyntheticCredentialRoundTripAndIdempotentDelete() throws {
        guard let accessGroup = KeychainSimpleFINCredentialStore.resolvedAccessGroup() else {
            XCTFail("The development-signed host did not expose a Keychain access group")
            return
        }
        let store = KeychainSimpleFINCredentialStore(accessGroup: accessGroup)
        try store.preflight()

        let itemID = "com.ledgerbar.tests.\(UUID().uuidString)"
        defer { try? store.delete(itemID: itemID) }

        let host = try SimpleFINHost(host: SimpleFINURLValidator.officialBridgeHost)
        let credential = try SimpleFINCredential(
            host: host,
            opaquePercentEncodedPathPrefix: "/synthetic-access",
            existingQueryItems: [],
            existingPercentEncodedQuery: nil,
            username: "ledgerbar-ui-test-user",
            password: "synthetic-test-password",
            approvedHost: host
        )

        try store.save(credential, itemID: itemID)
        let loaded = try store.load(itemID: itemID)
        XCTAssertEqual(loaded, credential)

        let wrongGroup = "0000000000.com.ledgerbar.app"
        let wrongStore = KeychainSimpleFINCredentialStore(accessGroup: wrongGroup)
        XCTAssertThrowsError(try wrongStore.load(itemID: itemID)) { error in
            XCTAssertNotEqual(error as? SimpleFINKeychainError, .itemNotFound)
        }

        try store.delete(itemID: itemID)
        XCTAssertThrowsError(try store.load(itemID: itemID)) { error in
            XCTAssertEqual(error as? SimpleFINKeychainError, .itemNotFound)
        }
        // Deletion is intentionally idempotent for crash-recovery retries.
        try store.delete(itemID: itemID)
    }

    func testSignedHostExposesOnlyTheDesignatedKeychainGroup() throws {
        guard let accessGroup = KeychainSimpleFINCredentialStore.resolvedAccessGroup() else {
            XCTFail("The development-signed host did not expose a Keychain access group")
            return
        }
        let entitlements = try signedHostEntitlements()
        XCTAssertEqual(entitlements["keychain-access-groups"] as? [String], [accessGroup])
        XCTAssertNotNil(
            accessGroup.range(
                of: #"^[A-Z0-9]{10}\.com\.ledgerbar\.app$"#,
                options: .regularExpression
            ),
            "The resolved access group must be TEAMID.com.ledgerbar.app"
        )
        let applicationIdentifier =
            (entitlements["com.apple.application-identifier"]
             ?? entitlements["application-identifier"]) as? String
        XCTAssertEqual(applicationIdentifier, accessGroup)
        XCTAssertTrue(
            applicationIdentifier?.hasSuffix(".com.ledgerbar.app") == true,
            "The signed host must expose the matching application-identifier"
        )
        XCTAssertEqual(entitlements["com.apple.security.app-sandbox"] as? Bool, true)
        XCTAssertEqual(entitlements["com.apple.security.network.client"] as? Bool, true)
        XCTAssertEqual(entitlements["com.apple.security.files.user-selected.read-write"] as? Bool, true)
    }

    private func signedHostEntitlements() throws -> [String: Any] {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
        let suffix = UUID().uuidString
        let stdoutURL = temporaryDirectory.appendingPathComponent("ledgerbar-codesign-stdout-\(suffix)")
        let stderrURL = temporaryDirectory.appendingPathComponent("ledgerbar-codesign-stderr-\(suffix)")
        defer {
            try? fileManager.removeItem(at: stdoutURL)
            try? fileManager.removeItem(at: stderrURL)
        }
        guard fileManager.createFile(
            atPath: stdoutURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ), fileManager.createFile(
            atPath: stderrURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw NSError(domain: "LedgerBarKeychainTests", code: 3)
        }

        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdoutHandle.close()
            try? stderrHandle.close()
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-d", "--entitlements", ":-", Bundle.main.bundlePath]
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle
        try process.run()
        process.waitUntilExit()
        try stdoutHandle.close()
        try stderrHandle.close()

        let rawData = try Data(contentsOf: stdoutURL) + Data(contentsOf: stderrURL)
        guard process.terminationStatus == 0,
              let xmlStart = rawData.range(of: Data("<?xml".utf8)) else {
            throw NSError(domain: "LedgerBarKeychainTests", code: 2)
        }
        let xmlData = rawData[xmlStart.lowerBound...]
        guard let plistEnd = xmlData.range(of: Data("</plist>".utf8)) else {
            throw NSError(domain: "LedgerBarKeychainTests", code: 2)
        }
        let plistData = xmlData[..<plistEnd.upperBound]
        guard let plist = try PropertyListSerialization.propertyList(
            from: plistData,
            options: [],
            format: nil
        ) as? [String: Any] else {
            throw NSError(domain: "LedgerBarKeychainTests", code: 1)
        }
        return plist
    }
}

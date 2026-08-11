import Foundation
import Testing
@testable import LedgerCore

private enum CaptureFailureStage: Equatable {
    case creation
    case permission
    case rawWrite
    case outputWrite
    case cleanup
}

private enum SyntheticCaptureFailure: Error {
    case injected
}

private final class CaptureFileHarness: @unchecked Sendable {
    private let lock = NSLock()
    private let failure: CaptureFailureStage?
    private var recordedEvents: [String] = []

    init(failure: CaptureFailureStage? = nil) {
        self.failure = failure
    }

    func operations() -> SimpleFINCaptureFileOperations {
        SimpleFINCaptureFileOperations(
            createRestrictedRawFile: { [self] url in
                record("create")
                let created = FileManager.default.createFile(
                    atPath: url.path,
                    contents: nil,
                    attributes: [.posixPermissions: 0o600]
                )
                guard created else { throw SyntheticCaptureFailure.injected }
                if failure == .creation { throw SyntheticCaptureFailure.injected }
            },
            setRawPermissions: { [self] url in
                record("permission")
                if failure == .permission { throw SyntheticCaptureFailure.injected }
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: url.path
                )
            },
            writeRawData: { [self] data, url in
                record("raw-write")
                if failure == .rawWrite {
                    try data.write(to: url)
                    throw SyntheticCaptureFailure.injected
                }
                try data.write(to: url)
            },
            writeSanitizedData: { [self] data, url in
                record("output-write")
                if failure == .outputWrite { throw SyntheticCaptureFailure.injected }
                try data.write(to: url, options: [.atomic])
            },
            removeRawFile: { [self] url in
                record("cleanup")
                if failure == .cleanup { throw SyntheticCaptureFailure.injected }
                do {
                    try FileManager.default.removeItem(at: url)
                } catch let error as CocoaError where error.code == .fileNoSuchFile {
                    return
                }
            }
        )
    }

    func events() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return recordedEvents
    }

    private func record(_ event: String) {
        lock.lock(); defer { lock.unlock() }
        recordedEvents.append(event)
    }
}

@Suite("§4.2 capture raw-artifact cleanup")
struct SimpleFINCaptureArtifactWriterTests {
    private let syntheticJSON = Data(#"{"accounts":[],"errors":[]}"#.utf8)

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledgerbar-capture-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func rawArtifacts(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(SimpleFINCaptureArtifactWriter.rawFilePrefix) }
    }

    @Test("success writes sanitized output and removes the raw artifact")
    func success() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("fixture.json")

        let sanitized = try SimpleFINCaptureArtifactWriter.writeSanitizedFixture(
            fromRawResponse: syntheticJSON,
            to: output
        )

        #expect(FileManager.default.fileExists(atPath: output.path))
        #expect(try Data(contentsOf: output) == sanitized)
        #expect(try rawArtifacts(in: directory).isEmpty)
    }

    @Test("permission failure cleans up before throwing")
    func permissionFailure() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("fixture.json")
        let harness = CaptureFileHarness(failure: .permission)

        #expect(throws: SimpleFINCaptureArtifactError.rawPermissionFailed) {
            _ = try SimpleFINCaptureArtifactWriter.writeSanitizedFixture(
                fromRawResponse: syntheticJSON,
                to: output,
                operations: harness.operations()
            )
        }
        #expect(try rawArtifacts(in: directory).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(harness.events() == ["create", "permission", "cleanup"])
    }

    @Test("raw-file creation failure still enters cleanup")
    func creationFailure() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let harness = CaptureFileHarness(failure: .creation)

        #expect(throws: SimpleFINCaptureArtifactError.rawFileCreationFailed) {
            _ = try SimpleFINCaptureArtifactWriter.writeSanitizedFixture(
                fromRawResponse: syntheticJSON,
                to: directory.appendingPathComponent("fixture.json"),
                operations: harness.operations()
            )
        }
        #expect(try rawArtifacts(in: directory).isEmpty)
        #expect(harness.events() == ["create", "cleanup"])
    }

    @Test("live creation failure treats an absent raw file as already cleaned")
    func liveCreationFailure() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let missingParent = directory.appendingPathComponent("missing", isDirectory: true)

        #expect(throws: SimpleFINCaptureArtifactError.rawFileCreationFailed) {
            _ = try SimpleFINCaptureArtifactWriter.writeSanitizedFixture(
                fromRawResponse: syntheticJSON,
                to: missingParent.appendingPathComponent("fixture.json")
            )
        }
        #expect(try rawArtifacts(in: directory).isEmpty)
    }

    @Test("partial raw-write failure is removed")
    func rawWriteFailure() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let harness = CaptureFileHarness(failure: .rawWrite)

        #expect(throws: SimpleFINCaptureArtifactError.rawWriteFailed) {
            _ = try SimpleFINCaptureArtifactWriter.writeSanitizedFixture(
                fromRawResponse: syntheticJSON,
                to: directory.appendingPathComponent("fixture.json"),
                operations: harness.operations()
            )
        }
        #expect(try rawArtifacts(in: directory).isEmpty)
        #expect(harness.events().last == "cleanup")
    }

    @Test("sanitization failure removes the raw artifact")
    func sanitizationFailure() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(throws: SimpleFINCaptureArtifactError.sanitizationFailed) {
            _ = try SimpleFINCaptureArtifactWriter.writeSanitizedFixture(
                fromRawResponse: Data("not-json".utf8),
                to: directory.appendingPathComponent("fixture.json")
            )
        }
        #expect(try rawArtifacts(in: directory).isEmpty)
    }

    @Test("sanitized-output failure removes the raw artifact")
    func outputFailure() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let harness = CaptureFileHarness(failure: .outputWrite)

        #expect(throws: SimpleFINCaptureArtifactError.outputWriteFailed) {
            _ = try SimpleFINCaptureArtifactWriter.writeSanitizedFixture(
                fromRawResponse: syntheticJSON,
                to: directory.appendingPathComponent("fixture.json"),
                operations: harness.operations()
            )
        }
        #expect(try rawArtifacts(in: directory).isEmpty)
        #expect(harness.events().last == "cleanup")
    }

    @Test("cleanup failure is attempted and surfaced with a fixed error")
    func cleanupFailure() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let harness = CaptureFileHarness(failure: .cleanup)

        #expect(throws: SimpleFINCaptureArtifactError.rawCleanupFailed) {
            _ = try SimpleFINCaptureArtifactWriter.writeSanitizedFixture(
                fromRawResponse: syntheticJSON,
                to: directory.appendingPathComponent("fixture.json"),
                operations: harness.operations()
            )
        }
        #expect(harness.events().last == "cleanup")
        #expect(try rawArtifacts(in: directory).count == 1)
    }

    @Test("permissions precede raw bytes and cleanup precedes return")
    func operationOrdering() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let harness = CaptureFileHarness()

        _ = try SimpleFINCaptureArtifactWriter.writeSanitizedFixture(
            fromRawResponse: syntheticJSON,
            to: directory.appendingPathComponent("fixture.json"),
            operations: harness.operations()
        )

        #expect(harness.events() == ["create", "permission", "raw-write", "output-write", "cleanup"])
        #expect(try rawArtifacts(in: directory).isEmpty)
    }
}

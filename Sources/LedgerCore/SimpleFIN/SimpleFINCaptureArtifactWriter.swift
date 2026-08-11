import Foundation

/// Fixed, redacted capture-artifact failures. No case carries raw response
/// bytes, a path supplied by the provider, or an underlying error string.
public enum SimpleFINCaptureArtifactError: Error, Equatable, Sendable {
    case rawFileCreationFailed
    case rawPermissionFailed
    case rawWriteFailed
    case sanitizationFailed
    case outputWriteFailed
    case rawCleanupFailed
}

/// Narrow file-operation seam for deterministic failure-path tests.
public struct SimpleFINCaptureFileOperations: Sendable {
    public var createRestrictedRawFile: @Sendable (URL) throws -> Void
    public var setRawPermissions: @Sendable (URL) throws -> Void
    public var writeRawData: @Sendable (Data, URL) throws -> Void
    public var writeSanitizedData: @Sendable (Data, URL) throws -> Void
    public var removeRawFile: @Sendable (URL) throws -> Void

    public init(
        createRestrictedRawFile: @escaping @Sendable (URL) throws -> Void,
        setRawPermissions: @escaping @Sendable (URL) throws -> Void,
        writeRawData: @escaping @Sendable (Data, URL) throws -> Void,
        writeSanitizedData: @escaping @Sendable (Data, URL) throws -> Void,
        removeRawFile: @escaping @Sendable (URL) throws -> Void
    ) {
        self.createRestrictedRawFile = createRestrictedRawFile
        self.setRawPermissions = setRawPermissions
        self.writeRawData = writeRawData
        self.writeSanitizedData = writeSanitizedData
        self.removeRawFile = removeRawFile
    }

    public static let live = SimpleFINCaptureFileOperations(
        createRestrictedRawFile: { url in
            let created = FileManager.default.createFile(
                atPath: url.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            )
            guard created else { throw CocoaError(.fileWriteUnknown) }
        },
        setRawPermissions: { url in
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        },
        writeRawData: { data, url in
            let handle = try FileHandle(forWritingTo: url)
            do {
                try handle.write(contentsOf: data)
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
        },
        writeSanitizedData: { data, url in
            try data.write(to: url, options: [.atomic])
        },
        removeRawFile: { url in
            do {
                try FileManager.default.removeItem(at: url)
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                return
            }
        }
    )
}

/// Owns the complete lifetime of the on-disk raw response. Cleanup is
/// installed before file creation, permissioning, or writing, and every
/// result is held until that cleanup scope has unwound.
public enum SimpleFINCaptureArtifactWriter {
    public static let rawFilePrefix = ".simplefin-capture-raw-"

    public static func writeSanitizedFixture(
        fromRawResponse raw: Data,
        to outputURL: URL,
        rawDirectory: URL? = nil,
        operations: SimpleFINCaptureFileOperations = .live
    ) throws -> Data {
        let rawURL = (rawDirectory ?? outputURL.deletingLastPathComponent())
            .appendingPathComponent("\(rawFilePrefix)\(UUID().uuidString).json")

        var cleanupFailed = false
        let operationResult: PipelineResult
        do {
            // This defer is registered before the first operation that can
            // create or alter the raw artifact.
            defer {
                do {
                    try operations.removeRawFile(rawURL)
                } catch {
                    cleanupFailed = true
                }
            }
            operationResult = runPipeline(
                raw: raw,
                rawURL: rawURL,
                outputURL: outputURL,
                operations: operations
            )
        }

        // Cleanup has already run before either success or failure escapes.
        if cleanupFailed {
            throw SimpleFINCaptureArtifactError.rawCleanupFailed
        }
        switch operationResult {
        case .success(let sanitized):
            return sanitized
        case .failure(let error):
            throw error
        }
    }

    private enum PipelineResult {
        case success(Data)
        case failure(SimpleFINCaptureArtifactError)
    }

    private static func runPipeline(
        raw: Data,
        rawURL: URL,
        outputURL: URL,
        operations: SimpleFINCaptureFileOperations
    ) -> PipelineResult {
        do {
            try operations.createRestrictedRawFile(rawURL)
        } catch {
            return .failure(.rawFileCreationFailed)
        }
        do {
            // Restrict an empty file before any sensitive response bytes are
            // written, rather than relying on a later chmod.
            try operations.setRawPermissions(rawURL)
        } catch {
            return .failure(.rawPermissionFailed)
        }
        do {
            try operations.writeRawData(raw, rawURL)
        } catch {
            return .failure(.rawWriteFailed)
        }

        let sanitized: Data
        do {
            sanitized = try SimpleFINCaptureSanitizer.sanitizedFixture(fromRawJSON: raw)
        } catch {
            return .failure(.sanitizationFailed)
        }
        do {
            try operations.writeSanitizedData(sanitized, outputURL)
        } catch {
            return .failure(.outputWriteFailed)
        }
        return .success(sanitized)
    }
}

import Foundation
import Darwin
import LedgerCore

/// §4.2 capture gate: a one-command tool the user runs against their own
/// account before Codable models are frozen for the deployed Bridge shape.
/// It accepts no credential-bearing argument or ordinary environment value.

private struct CaptureOptions {
    var days: Int
    var outputPath: String
}

private enum CaptureArgumentResult {
    case help
    case options(CaptureOptions)
}

private enum CaptureCommandError: Error {
    case invalidDays
    case missingOutputPath
    case unknownArgument
    case missingApplicationSupport
    case absoluteDatabaseOverrideRequiresOptIn
    case databasePathEscapesApplicationSupport
    case missingDatabase
    case databaseUnavailable
    case notConnected
    case keychainUnavailable
    case protectedPromptUnavailable
    case invalidWindow
    case requestFailed(isHTTP: Bool)
    case artifact(SimpleFINCaptureArtifactError)
}

private func writeFailure(_ message: String) {
    FileHandle.standardError.write(Data("capture: \(message)\n".utf8))
}

private func note(_ message: String) {
    print("capture: \(message)")
}

private func parseArguments(_ arguments: [String]) throws -> CaptureArgumentResult {
    var days = 7
    var outputPath = "simplefin-shape-fixture.json"
    var iterator = arguments.makeIterator()
    while let argument = iterator.next() {
        switch argument {
        case "--days":
            guard let value = iterator.next(),
                  let parsed = Int(value),
                  parsed > 0,
                  parsed <= 90 else {
                throw CaptureCommandError.invalidDays
            }
            days = parsed
        case "--output":
            guard let value = iterator.next(), !value.isEmpty else {
                throw CaptureCommandError.missingOutputPath
            }
            outputPath = value
        case "--help", "-h":
            return .help
        default:
            throw CaptureCommandError.unknownArgument
        }
    }
    return .options(CaptureOptions(days: days, outputPath: outputPath))
}

private func helpText() -> String {
    """
    Captures the deployed SimpleFIN /accounts response shape.
    The credential comes from the signed app Keychain group or one
    terminal-echo-disabled protected prompt; it is never accepted in argv or
    ordinary environment values. The raw body is created with 0600 permissions
    and removed before the command exits.

      --days N        history window in days (default 7)
      --output PATH   sanitized fixture destination (default ./simplefin-shape-fixture.json)
    """
}

private func databaseURL() throws -> URL {
    guard let support = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
    ).first else {
        throw CaptureCommandError.missingApplicationSupport
    }

    if let override = ProcessInfo.processInfo.environment["LEDGERBAR_DB_PATH"], !override.isEmpty {
        if override.hasPrefix("/") {
            guard ProcessInfo.processInfo.environment["LEDGERBAR_ALLOW_ABSOLUTE_DB_PATH"] == "1" else {
                throw CaptureCommandError.absoluteDatabaseOverrideRequiresOptIn
            }
            return URL(fileURLWithPath: override).standardizedFileURL
        }
        let supportRoot = support.standardizedFileURL.path
        let candidate = support.appendingPathComponent(override).standardizedFileURL
        guard candidate.path == supportRoot || candidate.path.hasPrefix(supportRoot + "/") else {
            throw CaptureCommandError.databasePathEscapesApplicationSupport
        }
        return candidate
    }

    let unsandboxedDatabase = support
        .appendingPathComponent("LedgerBar", isDirectory: true)
        .appendingPathComponent("ledgerbar.sqlite")
    let sandboxedDatabase = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Containers/com.ledgerbar.app/Data/Library/Application Support/LedgerBar/ledgerbar.sqlite")

    // A signed sandboxed app writes the container path; an ad-hoc/manual local
    // app writes the ordinary user Application Support path. Prefer whichever
    // existing database is present without accepting an arbitrary path.
    if FileManager.default.fileExists(atPath: sandboxedDatabase.path) {
        return sandboxedDatabase
    }
    return unsandboxedDatabase
}

private func message(for error: Error) -> String {
    guard let commandError = error as? CaptureCommandError else {
        return "the capture could not be completed."
    }
    switch commandError {
    case .invalidDays:
        return "--days needs a value between 1 and 90"
    case .missingOutputPath:
        return "--output needs a path"
    case .unknownArgument:
        return "unknown argument. This tool intentionally accepts no credential material."
    case .missingApplicationSupport:
        return "no Application Support directory"
    case .absoluteDatabaseOverrideRequiresOptIn:
        return "an absolute LEDGERBAR_DB_PATH requires LEDGERBAR_ALLOW_ABSOLUTE_DB_PATH=1 for disposable development testing"
    case .databasePathEscapesApplicationSupport:
        return "the relative LEDGERBAR_DB_PATH escapes Application Support"
    case .missingDatabase:
        return "no LedgerBar database found. Connect SimpleFIN in the app first."
    case .databaseUnavailable:
        return "could not open the LedgerBar database"
    case .notConnected:
        return "SimpleFIN is not connected in the app. The capture gate stays blocked until it is."
    case .keychainUnavailable:
        return "the Keychain item could not be read from this process. Run the capture from a correctly signed and entitled host; the capture gate remains blocked."
    case .protectedPromptUnavailable:
        return "the Keychain item is unavailable and protected interactive input is not available on this terminal"
    case .invalidWindow:
        return "invalid capture window"
    case .requestFailed(let isHTTP):
        return isHTTP
            ? "the /accounts request failed with an HTTP error. No credential material is printed."
            : "the /accounts request failed validation. No credential material is printed."
    case .artifact(let artifactError):
        switch artifactError {
        case .rawFileCreationFailed, .rawPermissionFailed, .rawWriteFailed:
            return "could not safely write the restricted raw capture file; cleanup was attempted."
        case .sanitizationFailed:
            return "the response was not valid JSON; raw-file cleanup completed before exit."
        case .outputWriteFailed:
            return "could not write the sanitized fixture; raw-file cleanup completed before exit."
        case .rawCleanupFailed:
            return "raw capture cleanup could not be confirmed. Remove any .simplefin-capture-raw file beside the requested output before retrying."
        }
    }
}

private func readProtectedLine(_ prompt: String) throws -> String {
    guard isatty(STDIN_FILENO) == 1 else {
        throw CaptureCommandError.protectedPromptUnavailable
    }
    FileHandle.standardOutput.write(Data(prompt.utf8))
    fflush(stdout)

    var original = termios()
    guard tcgetattr(STDIN_FILENO, &original) == 0 else {
        throw CaptureCommandError.protectedPromptUnavailable
    }
    var hidden = original
    hidden.c_lflag &= ~tcflag_t(ECHO)
    guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &hidden) == 0 else {
        throw CaptureCommandError.protectedPromptUnavailable
    }
    defer {
        _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
        print()
    }

    guard let value = readLine(), !value.isEmpty else {
        throw CaptureCommandError.protectedPromptUnavailable
    }
    return value
}

private func promptForAccessCredential(approvedHost: SimpleFINHost) throws -> SimpleFINCredential {
    // §4.2 fallback for an unsigned CLI process. The Access URL is never
    // accepted in argv/environment and is held only in memory for this request.
    let rawAccessURL = try readProtectedLine("Access URL (input hidden; never saved): ")
    guard let accessURL = URL(string: rawAccessURL) else {
        throw SimpleFINProtocolError.invalidAccessURL
    }
    return try SimpleFINURLValidator.parseAccessURL(
        accessURL,
        approvedHosts: [approvedHost]
    )
}

private func runCaptureCommand() async -> Int32 {
    do {
        let parsed = try parseArguments(Array(CommandLine.arguments.dropFirst()))
        guard case .options(let options) = parsed else {
            print(helpText())
            return 0
        }

        let databaseURL = try databaseURL()
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw CaptureCommandError.missingDatabase
        }

        let store: LedgerWorkspaceStore
        let workspace: BudgetWorkspace
        do {
            store = try LedgerWorkspaceStore(databaseURL: databaseURL)
            workspace = try store.loadFirstWorkspace()
        } catch {
            throw CaptureCommandError.databaseUnavailable
        }
        guard let state = try? store.loadSimpleFINState(budgetID: workspace.budget.id),
              let credentialPin = state.activeCredentialPin else {
            throw CaptureCommandError.notConnected
        }

        let credential: SimpleFINCredential
        do {
            let accessGroup = KeychainSimpleFINCredentialStore.resolvedAccessGroup()
            credential = try KeychainSimpleFINCredentialStore(accessGroup: accessGroup)
                .load(itemID: credentialPin.itemID)
        } catch SimpleFINKeychainError.missingAccessGroup {
            let approvedHost = try SimpleFINHost(host: state.baseHost, port: state.basePort)
            note("Keychain access is unavailable in this unsigned CLI process; using protected interactive input without saving the credential.")
            credential = try promptForAccessCredential(approvedHost: approvedHost)
        } catch {
            throw CaptureCommandError.keychainUnavailable
        }

        let nowEpoch = Int64(Date().timeIntervalSince1970.rounded())
        let window: SimpleFINRequestWindow
        do {
            window = try SimpleFINRequestWindow(
                startEpoch: nowEpoch - Int64(options.days) * 86_400
            )
        } catch {
            throw CaptureCommandError.invalidWindow
        }

        let raw: Data
        do {
            let client = SimpleFINClient(credential: credential)
            raw = try await client.fetchAccountsRawForCapture(SimpleFINRequest(window: window))
        } catch {
            throw CaptureCommandError.requestFailed(isHTTP: error is SimpleFINHTTPError)
        }

        let outputURL = URL(fileURLWithPath: options.outputPath)
        let sanitized: Data
        do {
            sanitized = try SimpleFINCaptureArtifactWriter.writeSanitizedFixture(
                fromRawResponse: raw,
                to: outputURL,
                rawDirectory: FileManager.default.temporaryDirectory
            )
        } catch let artifactError as SimpleFINCaptureArtifactError {
            throw CaptureCommandError.artifact(artifactError)
        }

        note("raw capture removed (best-effort file deletion, not cryptographic erasure).")
        if let decoded = try? JSONDecoder().decode(SimpleFINAccountsResponse.self, from: sanitized) {
            note("sanitized fixture decodes with the current defensive models (\(decoded.accounts.count) account(s)).")
        } else {
            note("NOTE: the sanitized fixture does NOT decode with the current models — the deployed shape diverges; update the decoder before freezing.")
        }
        note("sanitized fixture written to \(outputURL.path)")
        return 0
    } catch {
        writeFailure(message(for: error))
        return 1
    }
}

// `exit` is confined to the outermost boundary. All raw-artifact scopes have
// returned and their cleanup has already run before a nonzero status is used.
let captureExitStatus = await runCaptureCommand()
if captureExitStatus != 0 {
    exit(captureExitStatus)
}

import AppKit
import Foundation
import LedgerCore
import Observation

private enum AppModelConfigurationError: Error {
    case absoluteDatabaseOverrideRequiresOptIn
    case databasePathEscapesApplicationSupport
}

/// Main-actor view model bridging the `BudgetMutationService` actor and the
/// store's `ValueObservation` revision stream into `@Observable` state. Views
/// never write to the database directly; every mutation goes through
/// `perform`, which serializes on the service actor and refreshes published
/// state after commit.
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case loading
        case onboarding
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var snapshot: BudgetWorkspaceSnapshot?
    private(set) var projection: ProjectionResult?
    private(set) var simplefin: SimpleFINConnectionState?
    // Set from the SimpleFIN flows (separate file); views treat as read-only.
    var syncing = false
    var lastSyncSummary: String?
    var actionError: String?
    var infoMessage: String?

    let service: BudgetMutationService
    let credentials: any SimpleFINCredentialStore
    let credentialLifecycle: SimpleFINCredentialLifecycle
    private let store: LedgerWorkspaceStore
    let syncCoordinator = SyncCoordinator()
    private var observationTask: Task<Void, Never>?
    private var bootstrapped = false
    /// Claimed credential waiting for explicit host confirmation (§4.1 step 5).
    var pendingClaim: PendingClaim?
    /// A Setup Token targeting a custom host is held only in memory while the
    /// user decides whether to trust that exact host. It is never persisted.
    @ObservationIgnored var pendingSetupToken: String?
    var pendingTrustedHost: SimpleFINHost?

    struct PendingClaim {
        var credential: SimpleFINCredential
        var hostDescription: String
        var replacementIntent: SimpleFINCredentialReplacementIntent
        var requiresHostConfirmation: Bool
    }

    init(store: LedgerWorkspaceStore, credentials: any SimpleFINCredentialStore) {
        self.store = store
        let service = BudgetMutationService(store: store)
        self.service = service
        self.credentials = credentials
        self.credentialLifecycle = SimpleFINCredentialLifecycle(
            credentials: credentials,
            states: BudgetMutationSimpleFINConnectionStateStore(service: service)
        )
    }

    static func production() throws -> AppModel {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let databaseURL: URL
        if let override = ProcessInfo.processInfo.environment["LEDGERBAR_DB_PATH"], !override.isEmpty {
            // Development/smoke-test override so a scratch run never touches
            // the real Application Support database. Relative overrides stay
            // inside the sandboxed Application Support directory; absolute
            // overrides are retained for explicit local smoke tests. Never
            // carries credentials.
            if override.hasPrefix("/") {
                guard ProcessInfo.processInfo.environment["LEDGERBAR_ALLOW_ABSOLUTE_DB_PATH"] == "1" else {
                    throw AppModelConfigurationError.absoluteDatabaseOverrideRequiresOptIn
                }
                databaseURL = URL(fileURLWithPath: override).standardizedFileURL
            } else {
                let supportRoot = support.standardizedFileURL.path
                let candidate = support.appendingPathComponent(override).standardizedFileURL
                guard candidate.path == supportRoot || candidate.path.hasPrefix(supportRoot + "/") else {
                    throw AppModelConfigurationError.databasePathEscapesApplicationSupport
                }
                databaseURL = candidate
            }
        } else {
            databaseURL = support
                .appendingPathComponent("LedgerBar", isDirectory: true)
                .appendingPathComponent("ledgerbar.sqlite")
        }
        let store = try LedgerWorkspaceStore(databaseURL: databaseURL)
        let accessGroup = KeychainSimpleFINCredentialStore.resolvedAccessGroup()
        return AppModel(
            store: store,
            credentials: KeychainSimpleFINCredentialStore(accessGroup: accessGroup)
        )
    }

    static func failed(message: String) -> AppModel {
        // In-memory placeholder so the UI can render the failure state even
        // when the filesystem-backed database failed because of disk or
        // directory access problems. It is never populated by this phase.
        let model = try! AppModel(
            store: LedgerWorkspaceStore.inMemory(),
            credentials: InMemorySimpleFINCredentialStore()
        )
        model.phase = .failed(message)
        return model
    }

    var nowEpoch: Int64 { Int64(Date().timeIntervalSince1970.rounded()) }

    // MARK: - Lifecycle

    func bootstrapIfNeeded() async {
        guard !bootstrapped else { return }
        bootstrapped = true
        if case .failed = phase { return }
        do {
            _ = try await service.loadFirst()
            do {
                try await credentialLifecycle.retryPendingOperations(nowEpoch: nowEpoch)
            } catch {
                actionError = friendlyMessage(error)
            }
            try await advanceBudgetClock()
            await refresh()
            phase = .ready
            startObservation()
            startActivationObserver()
            await autoSyncIfDue()
        } catch LedgerPersistenceError.workspaceNotFound {
            phase = .onboarding
        } catch {
            phase = .failed(friendlyMessage(error))
        }
    }

    func createBudget(currency: String, timeZoneIdentifier: String, firstMonth: BudgetMonth) async {
        do {
            let calendar = try BudgetCalendar(timeZoneIdentifier: timeZoneIdentifier)
            guard let today = calendar.budgetDate(fromEpoch: nowEpoch) else {
                throw BudgetCalendarError.unrepresentableDate
            }
            _ = try await service.createBudget(
                name: "My Budget",
                currency: currency,
                timeZoneIdentifier: timeZoneIdentifier,
                firstMonth: firstMonth,
                currentMonth: today.budgetMonth,
                nowEpoch: nowEpoch
            )
            await refresh()
            phase = .ready
            startObservation()
            startActivationObserver()
        } catch {
            actionError = friendlyMessage(error)
        }
    }

    /// §2.2 budget clock: advance `last_observed_budget_month` monotonically on
    /// launch/activation; never decrease it when the system clock moves back.
    func advanceBudgetClock() async throws {
        guard let snapshot = await service.currentSnapshot() else { return }
        let calendar = try BudgetCalendar(timeZoneIdentifier: snapshot.budget.timeZoneIdentifier)
        guard let today = calendar.budgetDate(fromEpoch: nowEpoch) else { return }
        let observed = snapshot.budget.lastObservedBudgetMonth
        if today.budgetMonth > observed {
            _ = try await service.transact(nowEpoch: nowEpoch) { workspace in
                try workspace.advanceObservedMonth(to: today.budgetMonth)
            }
        }
    }

    func refresh() async {
        snapshot = await service.currentSnapshot()
        if let snapshot {
            // Extend one month past current so the read-only future view has
            // data (§5.2); errors here are integrity failures worth surfacing.
            let horizon = snapshot.budget.lastObservedBudgetMonth.next
            do {
                projection = try await service.projectionResult(through: horizon)
            } catch {
                projection = nil
                actionError = friendlyMessage(error)
            }
        } else {
            projection = nil
        }
        simplefin = try? await service.simpleFINState()
    }

    /// Manual ValueObservation → @Observable bridge (§6.1): each committed
    /// revision triggers a state refresh from the service.
    private func startObservation() {
        observationTask?.cancel()
        let stream = store.observeRevisions()
        observationTask = Task { [weak self] in
            var lastSeen: Int64 = -1
            do {
                for try await revision in stream {
                    guard revision != lastSeen else { continue }
                    lastSeen = revision
                    await self?.refresh()
                }
            } catch {
                // Observation ending is not user-actionable; mutations still
                // refresh directly.
            }
        }
    }

    /// Launch/activation/wake all re-check the budget clock and the 24-hour
    /// sync threshold with elapsed-time checks — a timer alone is not
    /// dependable across sleep/App Nap (§6.4).
    private func startActivationObserver() {
        let handler: @Sendable (Notification) -> Void = { _ in
            Task { @MainActor [weak self] in
                await self?.retryPendingCredentialOperations()
                try? await self?.advanceBudgetClock()
                await self?.autoSyncIfDue()
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main, using: handler
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main, using: handler
        )
    }

    func retryPendingCredentialOperations() async {
        do {
            try await credentialLifecycle.retryPendingOperations(nowEpoch: nowEpoch)
            await refresh()
            if let pendingClaim,
               simplefin?.keychainItemID == pendingClaim.replacementIntent.itemID,
               simplefin?.pendingCredentialReplacement == nil,
               simplefin?.keychainItemIDsPendingDeletion.isEmpty == true,
               simplefin?.credentialDisconnectPending == false {
                self.pendingClaim = nil
            }
        } catch {
            actionError = friendlyMessage(error)
            await refresh()
        }
    }

    // MARK: - Mutations

    @discardableResult
    func perform<T: Sendable>(_ body: @escaping @Sendable (inout BudgetWorkspace) throws -> T) async -> T? {
        do {
            let result = try await service.transact(nowEpoch: nowEpoch, body)
            await refresh()
            return result
        } catch {
            actionError = friendlyMessage(error)
            await refresh()
            return nil
        }
    }

    // MARK: - Backup (§7.3)

    func backupDatabase() async {
        let panel = NSSavePanel()
        panel.title = "Save LedgerBar Backup"
        panel.nameFieldStringValue = "LedgerBar-backup.sqlite"
        panel.canCreateDirectories = true
        activateApp()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try await service.backup(to: url)
            infoMessage = "Backup verified (PRAGMA integrity_check) and saved. The file is unencrypted SQLite — keep the destination protected (FileVault/access controls)."
        } catch {
            actionError = friendlyMessage(error)
        }
    }

    // MARK: - Derived accessors used by views

    var budgetCurrency: String { snapshot?.budget.currency ?? "USD" }
    var currentMonth: BudgetMonth? { snapshot?.budget.lastObservedBudgetMonth }

    func categoryName(_ id: CategoryID?) -> String {
        guard let id else { return "" }
        return snapshot?.categories.first { $0.id == id }?.name ?? "?"
    }

    func payeeName(_ id: PayeeID?) -> String {
        guard let id else { return "" }
        return snapshot?.payees.first { $0.id == id }?.displayName ?? "?"
    }

    func accountName(_ id: AccountID) -> String {
        snapshot?.accounts.first { $0.id == id }?.name ?? "?"
    }

    var needsCategoryCount: Int {
        snapshot?.transactions.filter { $0.postingState == .needsCategory }.count ?? 0
    }

    var stagedCount: Int {
        snapshot?.transactions.filter { $0.postingState == .staged }.count ?? 0
    }

    // MARK: - Error mapping (sanitized; never includes credentials/URLs)

    nonisolated func friendlyMessage(_ error: Error) -> String {
        switch error {
        case let integrity as IntegrityError:
            return "Data integrity check failed (\(integrity.code.rawValue)). The change was rolled back."
        case let mutation as MutationError:
            return Self.mutationMessage(mutation)
        case is ArithmeticOverflowError:
            return "The amount is too large to process. The change was rolled back."
        case let parse as MoneyParseError:
            switch parse {
            case .malformed: return "Enter a valid amount."
            case .notFinite: return "Enter a finite amount."
            case .outOfRange: return "That amount is out of range."
            }
        case let persistence as LedgerPersistenceError:
            switch persistence {
            case .workspaceNotFound: return "No budget exists yet."
            case .invalidSnapshot: return "The stored budget could not be read."
            case .concurrentModification, .concurrentSimpleFINStateModification: return "This budget changed in another LedgerBar instance. The latest data was reloaded; retry the action."
            case .destinationAlreadyExists: return "The backup destination already exists."
            case .backupIntegrityCheckFailed: return "Backup verification failed; nothing was saved."
            }
        case let http as SimpleFINHTTPError:
            return Self.httpMessage(http)
        case let proto as SimpleFINProtocolError:
            return Self.protocolMessage(proto)
        case SimpleFINSignNormalizationError.invertedCashLikeAccount:
            return "Checking, savings, and cash accounts must use the normal SimpleFIN sign convention."
        case SimpleFINKeychainError.missingAccessGroup:
            return "This LedgerBar build is ad-hoc signed and has no Keychain access group, so it cannot store the SimpleFIN credential. Live sync needs the development-signed Xcode build (see docs/DEVELOPMENT.md)."
        case let SimpleFINKeychainError.unexpectedStatus(status):
            return "The SimpleFIN credential could not be accessed in the Keychain (OSStatus \(status))."
        case is SimpleFINKeychainError:
            return "The SimpleFIN credential could not be accessed in the Keychain."
        case let lifecycle as SimpleFINCredentialLifecycleError:
            switch lifecycle {
            case .credentialDeletionFailed:
                return SimpleFINCredentialLifecycleError.deletionFailureDiagnostic
            case .credentialRecoveryFailed:
                return "SimpleFIN credential recovery could not be completed. Retry the connection action."
            case .operationAlreadyInProgress:
                return "Another SimpleFIN credential operation is already in progress."
            case .pendingOperationConflict:
                return "SimpleFIN credential state changed before the operation completed. Retry the connection action."
            }
        case AppModelConfigurationError.absoluteDatabaseOverrideRequiresOptIn:
            return "An absolute database override requires explicit development opt-in."
        case AppModelConfigurationError.databasePathEscapesApplicationSupport:
            return "The requested database path is outside Application Support."
        case SyncCoordinatorError.alreadyRunning:
            return "A sync is already running."
        case SyncCoordinatorError.notConnected:
            return "SimpleFIN is not connected."
        case SyncCoordinatorError.connectionChanged:
            return "The SimpleFIN connection changed while the request was running; its response was discarded."
        case SimpleFINConnectionPinError.connectionChanged:
            return "The SimpleFIN connection changed while the request was running; its response was discarded."
        case let resolution as SyncResolutionError:
            switch resolution {
            case .staleRequest:
                return "This review changed before the decision was saved. The queue was refreshed; review the current facts again."
            case .conflictNotOpen, .discrepancyNotOpen:
                return "This review item is already resolved or no longer open. The queue was refreshed."
            case .accountLifecycleUnsupported:
                return "Account-close resolution is not supported in this local app milestone."
            default:
                return "The review decision was rejected because the stored review record is no longer valid."
            }
        default:
            return "The operation could not be completed."
        }
    }

    private nonisolated static func mutationMessage(_ error: MutationError) -> String {
        switch error {
        case .allocationMonthNotCurrent: return "Only the current month can be assigned or reallocated."
        case .negativeSetBudgeted: return "Assigned amounts must be zero or more."
        case .allocationTargetNotAllowed: return "That category cannot be assigned directly."
        case .moveMoneyAmountNotPositive: return "Enter a positive amount to move."
        case .moveMoneySameCategory: return "Choose two different categories."
        case .moveMoneySourceUnavailable: return "The source category does not have that much available."
        case .moveMoneyRTAUnavailable: return "Ready to Assign does not have that much available."
        case .moveMoneyCategoryNotEligible: return "That category cannot be used in a money move."
        case .futureDatedTransaction: return "Future-dated entries are not supported in v1."
        case .dateBeforeFirstMonth: return "The date is before the budget's first month."
        case .closedMonth: return "That month is closed. Reopen it first to make changes."
        case .accountNotFound: return "Account not found."
        case .accountClosed: return "That account is closed."
        case .categoryRequired: return "Choose a category."
        case .categoryNotAllowed: return "That category is not allowed for this transaction."
        case .cardBalanceWouldBecomePositive: return "This would make the credit card balance positive, which v1 does not support."
        case .positiveCardOpeningBalance: return "A positive credit-card balance is not supported in v1."
        case .refundNotPositive: return "A refund must have a positive amount."
        case .refundOriginInvalid: return "The refund origin is not valid for this row."
        case .refundExceedsRemainingLot: return "The refund exceeds what remains refundable on the original purchase."
        case .cashRefundWithCreditDebt: return "This category has credit overspending; the cash refund was staged instead."
        case .transactionNotFound: return "Transaction not found."
        case .transactionImmutable: return "Imported identity fields cannot be edited."
        case .reconciledTransaction: return "That transaction is reconciled. Un-reconcile it first."
        case .transactionHasDependents: return "That transaction has linked rows; resolve them first."
        case .unsupportedTransferPair: return "That transfer direction is not supported in v1."
        case .transferLegsInvalid: return "Transfer legs must be equal and opposite, in the same month, within ±7 days."
        case .transferPairNotFound: return "Transfer pair not found."
        case .stagedRowNotFound: return "Staged row not found."
        case .resolutionGuardFailed: return "Resolving this row would make the card balance positive."
        case .resolutionNotEligible: return "That row cannot be resolved this way."
        case .reconciliationInvalid: return "The reconciliation input is not valid for this account."
        case .reconciliationUndoBlocked: return "This reconciliation can no longer be undone."
        case .budgetMismatch, .entityNotFound, .duplicateEntity: return "The referenced item was not found."
        case .currencyMismatch: return "Currencies do not match."
        case .systemEntityImmutable: return "System items cannot be changed."
        case .nameEmpty: return "Enter a name."
        case .duplicateName: return "That name is already in use."
        case .monthNotClosed: return "That month is not closed."
        case .monthAlreadyClosed: return "That month is already closed."
        case .accountHasActivity: return "Close is blocked while the account has a balance or unresolved rows. Use “Void History and Close” for a duplicate or mistaken account."
        case .accountHasTransferPairs: return "Unpair this account's transfers before voiding its history; the other side of each transfer belongs to another account."
        case .categoryHasAvailable: return "Move this category's available money elsewhere before hiding it."
        case .arithmeticOverflow: return "The amount is too large to process."
        }
    }

    private nonisolated static func httpMessage(_ error: SimpleFINHTTPError) -> String {
        switch error {
        case .status(let code, let retryAfter):
            switch code {
            case 402: return "SimpleFIN Bridge reports payment is required (402)."
            case 403: return "The token or access was refused (403). A claim 403 means the Setup Token was already used or is invalid; an accounts 403 means access was revoked — get a new Setup Token."
            case 401: return "Access is no longer authorized (401). Reconnect with a new Setup Token."
            case 429:
                if let retryAfter { return "Rate limited (429). Retry after \(retryAfter) seconds." }
                return "Rate limited (429). Try again later."
            default: return "SimpleFIN request failed with HTTP \(code)."
            }
        case .transport: return "The SimpleFIN server could not be reached."
        case .responseTooLarge: return "The SimpleFIN response was too large and was discarded."
        case .invalidUTF8Response: return "The SimpleFIN response was not readable."
        case .redirectRefused: return "A redirect was refused for security."
        }
    }

    private nonisolated static func protocolMessage(_ error: SimpleFINProtocolError) -> String {
        switch error {
        case .invalidSetupToken: return "That Setup Token is not valid."
        case .invalidClaimEndpoint, .invalidAccessURL: return "The SimpleFIN URL failed validation."
        case .untrustedHost(let host): return "Host \(host) is not on the trusted list."
        case .unsupportedPort: return "Only HTTPS on an approved port is supported."
        case .missingCredential: return "No stored SimpleFIN credential."
        case .invalidResponse: return "The SimpleFIN response did not match a supported shape."
        case .missingStableRemoteIdentity: return "A remote account has no stable identity; it was not imported."
        case .duplicateRemoteAccountIdentity: return "Two remote accounts share one identity; sync was paused rather than merging them."
        case .unlinkedRemoteAccount: return "A remote account is not linked to a local account."
        case .currencyMismatch: return "The remote account currency does not match."
        case .missingRemoteTransactionID: return "A remote transaction has no stable ID; the account was not imported."
        case .futurePostedEpoch: return "A remote transaction is dated in the future; the link was paused."
        case .arithmeticOverflow: return "A remote amount was out of range."
        case .pendingRowsExcluded: return "Pending rows are excluded by design."
        case .providerReportedErrors(let messages):
            // Provider strings remain untrusted even if an error was created
            // directly rather than through `SimpleFINAccountsResponse`.
            return "SimpleFIN reported a problem for this account: \(SimpleFINDiagnosticRedactor.summary(messages)). Linking was not started."
        case .missingRequestedAccount:
            return "The provider's response did not include the requested account; linking was not started."
        }
    }
}

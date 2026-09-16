import LedgerCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            SimpleFINSettingsPane()
                .tabItem { Label("SimpleFIN", systemImage: "link") }
            BackupSettingsPane()
                .tabItem { Label("Backup", systemImage: "externaldrive") }
            AssistantSettingsPane()
                .tabItem { Label("Assistant", systemImage: "sparkles") }
        }
        .frame(width: 600, height: 560)
    }
}

/// §4 connection lifecycle: claim a single-use Setup Token into the Keychain,
/// link remote accounts to new local accounts with the §4.4 anchor algorithm,
/// sync with per-account cursors, and disconnect preserving tombstones.
struct SimpleFINSettingsPane: View {
    @Environment(AppModel.self) private var model

    @State private var setupToken = ""
    @State private var claiming = false
    @State private var remoteCandidates: [RemoteAccountCandidate]?
    @State private var fetchingAccounts = false
    @State private var linkTarget: RemoteAccountCandidate?
    @State private var confirmingFullDisconnect = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                feedbackSection
                connectionSection
                if model.simplefin?.status == .active {
                    Divider()
                    linksSection
                    Divider()
                    remoteSection
                }
            }
            .padding(20)
        }
        .sheet(item: $linkTarget) { candidate in
            LinkAccountSheet(candidate: candidate) { refreshed in
                if refreshed { Task { await loadRemote() } }
            }
        }
        .alert("Confirm SimpleFIN host", isPresented: Binding(
            get: { model.pendingClaim?.requiresHostConfirmation == true },
            set: { if !$0 { model.rejectPendingClaim() } }
        )) {
            Button("Trust This Host") {
                guard let pending = model.pendingClaim else { return }
                Task { await model.confirmPendingClaim(pending) }
            }
            Button("Cancel", role: .cancel) { model.rejectPendingClaim() }
        } message: {
            Text("The Access URL points at \(model.pendingClaim?.hostDescription ?? "?"), which differs from the claim host. Store credentials for it only if you expected this.")
        }
        .alert("Trust SimpleFIN host?", isPresented: Binding(
            get: { model.pendingTrustedHost != nil },
            set: { if !$0 { model.rejectPendingSetupHost() } }
        )) {
            Button("Trust Host & Retry") {
                guard let setupToken = model.pendingSetupToken,
                      let trustedHost = model.pendingTrustedHost else { return }
                // Capture both values before SwiftUI dismisses the alert and
                // invokes the binding setter, which clears pending state.
                Task {
                    await model.trustPendingSetupHostAndRetry(
                        setupToken: setupToken,
                        host: trustedHost
                    )
                }
            }
            .accessibilityIdentifier("ledgerbar.simplefin.trust-host")
            Button("Cancel", role: .cancel) { model.rejectPendingSetupHost() }
        } message: {
            let host = model.pendingTrustedHost
            Text("The Setup Token targets \(host?.host ?? "?"):\(host?.port ?? 443), which is not the official SimpleFIN host. Trust it only if you obtained this token from that provider environment.")
        }
        .confirmationDialog(
            "Disconnect the entire SimpleFIN connection?",
            isPresented: $confirmingFullDisconnect,
            titleVisibility: .visible
        ) {
            Button("Disconnect Entire Connection", role: .destructive) {
                Task { await model.disconnectSimpleFIN() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The Keychain credential will be deleted and every linked account will pause. Local accounts, transactions, imports, link identities, and cursors will be preserved.")
        }
    }

    @ViewBuilder
    private var feedbackSection: some View {
        if let error = model.actionError {
            HStack(alignment: .top, spacing: 8) {
                Label(error, systemImage: "xmark.octagon.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Dismiss") {
                    model.actionError = nil
                }
                .buttonStyle(.borderless)
            }
            .padding(10)
            .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        }
        if let info = model.infoMessage {
            HStack(alignment: .top, spacing: 8) {
                Label(info, systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Dismiss") {
                    model.infoMessage = nil
                }
                .buttonStyle(.borderless)
            }
            .padding(10)
            .background(.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private var connectionSection: some View {
        Text("SimpleFIN Bridge").font(.title3.bold())
        if let state = model.simplefin, state.status == .active {
            if state.credentialDisconnectPending {
                Label(
                    "Disconnect pending; credential cleanup must finish before the connection is inactive.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
            } else if state.credentialAuthorizationRevoked {
                Label(
                    "Access was revoked; disconnect and reconnect with a new Setup Token.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
            } else {
                Label("Connected to \(state.baseHost)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            if let last = state.lastSuccessfulSyncAtEpoch {
                Text("Last successful sync: \(Date(timeIntervalSince1970: TimeInterval(last)).formatted())")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = state.lastErrorRedacted {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                Button(model.syncing ? "Syncing…" : "Sync Now") {
                    Task { await model.syncNow() }
                }
                .disabled(model.syncing || state.activeCredentialPin == nil)
                .accessibilityIdentifier("ledgerbar.simplefin.sync-now")
                Button(state.credentialDisconnectPending ? "Retry Disconnect…" : "Disconnect…", role: .destructive) {
                    confirmingFullDisconnect = true
                }
                .help("Deletes the Keychain credential. The local ledger, links, and cursors are preserved; reconnecting reuses them.")
            }
            if let summary = model.lastSyncSummary {
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Text("Paste a one-time Setup Token from SimpleFIN Bridge. The token is claimed once and discarded; the resulting Access URL credential is stored only in the Keychain, never in the database or logs.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                SecureField("Setup Token (Base64)", text: $setupToken)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 340)
                    .accessibilityIdentifier("ledgerbar.simplefin.setup-token")
                Button(claiming ? "Claiming…" : "Connect") {
                    let token = setupToken
                    setupToken = "" // single-use: never retained in UI state
                    claiming = true
                    Task {
                        await model.connectSimpleFIN(setupToken: token)
                        claiming = false
                    }
                }
                .disabled(setupToken.isEmpty || claiming || model.pendingClaim != nil)
                .accessibilityIdentifier("ledgerbar.simplefin.connect")
            }
            if model.simplefin?.status == .disconnected {
                Text("Previously disconnected: links and cursors are preserved and will be reused on reconnect.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        if model.pendingClaim?.requiresHostConfirmation == false,
           model.simplefin?.credentialDisconnectPending != true {
            HStack {
                Text("The claimed credential is waiting for secure storage to finish.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Button("Retry Secure Storage") {
                    Task { await model.retryPendingClaimStorage() }
                }
            }
        }
    }

    @ViewBuilder
    private var linksSection: some View {
        HStack {
            Text("Linked accounts").font(.headline)
            Spacer()
            if model.openSyncConflictCount > 0 || model.openSnapshotDiscrepancyCount > 0 {
                // Records persist across launches and are actionable from the
                // main-window Review Queue.
                Label(
                    "\(model.openSyncConflictCount) conflict(s), \(model.openSnapshotDiscrepancyCount) balance discrepancy(ies) open",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
        let links = model.simplefin?.links ?? []
        if links.isEmpty {
            Text("No linked accounts yet. Fetch remote accounts below to link one.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ForEach(links, id: \.identity) { link in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(link.localAccountID.map { model.accountName($0) } ?? "No local account — relink to finish")
                        Text("Cursor: \(link.lastSuccessfulPostedEpoch.map { Date(timeIntervalSince1970: TimeInterval($0)).formatted(date: .abbreviated, time: .shortened) } ?? "not synced")")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if let accountID = link.localAccountID,
                           model.snapshot?.accounts.first(where: { $0.id == accountID })?.closed == true {
                            Text("The linked account is closed; this link no longer syncs.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else if model.simplefin?.wasPausedByFullDisconnect(identity: link.identity) == true {
                            Text("Paused: awaiting a matching remote identity after reconnect")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        } else if link.status == .paused {
                            Text("Paused: \(Self.pauseDescription(link.pauseReason))")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        } else if link.pauseReason == .closedMonthImportPending {
                            Text("Closed-month imports await review; sync continues.")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                        if let error = link.lastErrorRedacted {
                            Text(error)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text(link.signNormalization == .normal ? "Normal sign" : "Inverted sign")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    // Resuming an account-less link is a silent no-op (no
                    // cursor, no account); the recovery path is re-linking
                    // the remote account, which rebinds by identity.
                    if link.status == .paused,
                       let accountID = link.localAccountID,
                       model.snapshot?.accounts.first(where: { $0.id == accountID })?.closed != true,
                       model.simplefin?.canManuallyResumeLink(identity: link.identity) == true {
                        Button("Resume") {
                            Task { await model.resumeLink(identity: link.identity) }
                        }
                        .font(.caption)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private static func pauseDescription(_ reason: SimpleFINLinkPauseReason?) -> String {
        switch reason {
        case .futurePostedEpoch: return "a remote row is dated in the future"
        case .positiveCardSnapshot: return "the provider reports a positive card balance"
        case .unconfirmedSignDirection: return "the sign direction is unconfirmed"
        case .duplicateRemoteIdentity: return "two remote accounts share one identity"
        case .missingStableConnectionKey: return "the remote connection has no stable identity"
        case .currencyMismatch: return "the remote currency changed after linking"
        case .authRevoked: return "access was revoked; reconnect with a new Setup Token"
        case .closedMonthImportPending: return "closed-month imports await review"
        case .snapshotDiscrepancy: return "a balance discrepancy needs resolution"
        case .protocolError: return "the provider response failed validation"
        case nil: return "paused"
        }
    }

    @ViewBuilder
    private var remoteSection: some View {
        let validatingReconnect = model.simplefin?.hasLinksAwaitingReconnectValidation == true
        HStack {
            Text("Remote accounts").font(.headline)
            Spacer()
            Button(
                fetchingAccounts
                    ? "Fetching…"
                    : (validatingReconnect ? "Validate Reconnected Accounts" : "Fetch Remote Accounts")
            ) {
                Task { await loadRemote() }
            }
            .disabled(fetchingAccounts || model.simplefin?.activeCredentialPin == nil)
        }
        if validatingReconnect {
            Text("Existing links remain paused until this connection returns their exact remote identities.")
                .font(.caption)
                .foregroundStyle(.orange)
        }
        if let candidates = remoteCandidates {
            if candidates.isEmpty {
                Text("The provider returned no accounts.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(candidates) { candidate in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(candidate.account.name ?? candidate.account.id)
                        Text("\(candidate.account.currency) · balance \(candidate.account.balance) · \(candidate.account.organization?.name ?? candidate.connectionKey)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if candidate.linkedLocalAccountID != nil {
                        Label("Linked", systemImage: "checkmark").font(.caption).foregroundStyle(.green)
                    } else {
                        Button("Link…") { linkTarget = candidate }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func loadRemote() async {
        fetchingAccounts = true
        remoteCandidates = await model.fetchRemoteAccounts()
        fetchingAccounts = false
    }
}

/// §4.4 initial link for a new local account: sign confirmation, the
/// completeness attestation branch, and the derived-opening explanation.
struct LinkAccountSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let candidate: RemoteAccountCandidate
    let onFinished: (Bool) -> Void

    enum AttestationChoice: String, CaseIterable, Identifiable {
        case snapshotMinusHistory = "Derive opening from snapshot minus imported history"
        case userOpening = "I know the opening balance at the anchor date"
        var id: String { rawValue }
    }

    @State private var localName = ""
    @State private var type: AccountType = .checking
    @State private var onBudget = true
    @State private var sign: SimpleFINSignNormalization = .normal
    @State private var signConfirmed = false
    @State private var attestation: AttestationChoice = .snapshotMinusHistory
    @State private var openingText = ""
    @State private var working = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Link \(candidate.account.name ?? candidate.account.id)").font(.title3.bold())
                Form {
                    TextField("Local account name", text: $localName)
                    Picker("Type", selection: $type) {
                        Text("Checking").tag(AccountType.checking)
                        Text("Savings").tag(AccountType.savings)
                        Text("Cash").tag(AccountType.cash)
                        Text("Credit Card").tag(AccountType.creditCard)
                        Text("Other (tracking)").tag(AccountType.other)
                    }
                    Toggle("On budget", isOn: $onBudget)
                        .disabled(type == .other)

                    Section("Sign direction") {
                        LabeledContent("Reported balance") { Text(candidate.account.balance).monospacedDigit() }
                        Picker("Normalization", selection: $sign) {
                            Text("Normal (outflows negative)").tag(SimpleFINSignNormalization.normal)
                            if !type.isCashLike {
                                Text("Inverted (provider flips signs)").tag(SimpleFINSignNormalization.inverted)
                            }
                        }
                        if type == .creditCard {
                            Text("After normalization the card balance must be zero or negative (debt). A positive card balance pauses the link.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else if type.isCashLike {
                            Text("Checking, savings, and cash accounts use the normal provider sign convention in v1.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Toggle("I confirmed the sign direction against a recent statement", isOn: $signConfirmed)
                    }

                    Section("Opening balance") {
                        Picker("Method", selection: $attestation) {
                            ForEach(AttestationChoice.allCases) { choice in
                                Text(choice.rawValue).tag(choice)
                            }
                        }
                        .pickerStyle(.radioGroup)
                        if attestation == .userOpening {
                            TextField("Opening balance at anchor date", text: $openingText)
                        }
                        Text("SimpleFIN does not certify history completeness. Either branch marks the account “history incomplete”. History up to ~90 days (or back to the budget's first month, whichever is later) is imported once; the opening is computed exactly once, never snapshot-plus-history.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }
                    Button(working ? "Linking…" : "Link Account") { link() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canLink)
                }
            }
            .padding(20)
        }
        .frame(width: 520, height: 560)
        .onAppear {
            localName = candidate.account.name ?? "Linked Account"
            if candidate.account.currency != model.budgetCurrency {
                onBudget = false
            }
        }
        .onChange(of: type) { _, newType in
            if newType.isCashLike, sign == .inverted {
                sign = .normal
                signConfirmed = false
            }
        }
    }

    private var canLink: Bool {
        guard !working, signConfirmed, !localName.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard !(type.isCashLike && sign == .inverted) else { return false }
        if attestation == .userOpening { return !openingText.isEmpty }
        return true
    }

    private func link() {
        working = true
        let chosen: LinkAttestation
        switch attestation {
        case .snapshotMinusHistory:
            chosen = .snapshotMinusHistory
        case .userOpening:
            guard let value = try? MoneyFormatting.parse(openingText) else {
                model.actionError = "Enter a valid opening balance."
                working = false
                return
            }
            chosen = .userOpening(value)
        }
        let name = localName
        let accountType = type
        let budgeted = onBudget
        let normalization = sign
        let target = candidate
        Task {
            let linked = await model.linkRemoteAccount(
                candidate: target,
                localName: name,
                type: accountType,
                onBudget: budgeted,
                sign: normalization,
                attestation: chosen
            )
            working = false
            if linked {
                onFinished(true)
                dismiss()
            }
        }
    }
}

/// §7.3 verified local backup.
struct BackupSettingsPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Backup").font(.title3.bold())
            Text("Creates a consistent SQLite backup (GRDB backup API), verifies it with PRAGMA integrity_check, and only then copies it to the destination you choose. The backup is unencrypted — protect the destination with FileVault or equivalent. Restore is manual in v1: quit LedgerBar, replace the database in Application Support (removing -wal/-shm sidecars), and relaunch.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Back Up Now…") {
                Task { await model.backupDatabase() }
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("ledgerbar.backup-now")
            Spacer()
        }
        .padding(20)
    }
}

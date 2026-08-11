import LedgerCore
import SwiftUI

/// The user-facing queue for persisted sync decisions. Every button maps to a
/// fixed core resolution command; this view never writes the database directly.
struct ReviewQueueView: View {
    @Environment(AppModel.self) private var model

    private var openDiscrepancies: [SnapshotDiscrepancyRow] {
        (model.snapshot?.snapshotDiscrepancies ?? [])
            .filter { $0.status == .open }
            .sorted { ($0.observedEpoch, $0.id) < ($1.observedEpoch, $1.id) }
    }

    private var openConflicts: [SyncConflictRow] {
        (model.snapshot?.syncConflicts ?? [])
            .filter { $0.status == .open }
            .sorted { ($0.createdAtEpoch, $0.id) < ($1.createdAtEpoch, $1.id) }
    }

    var body: some View {
        Group {
            if openDiscrepancies.isEmpty && openConflicts.isEmpty {
                ContentUnavailableView(
                    "No open reviews",
                    systemImage: "checkmark.seal",
                    description: Text("New snapshot discrepancies and sync conflicts will appear here after SimpleFIN sync.")
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if !openDiscrepancies.isEmpty {
                            SectionHeader(
                                title: "Balance discrepancies",
                                count: openDiscrepancies.count,
                                systemImage: "equal.square"
                            )
                            ForEach(openDiscrepancies) { discrepancy in
                                SnapshotDiscrepancyCard(discrepancy: discrepancy)
                            }
                        }
                        if !openConflicts.isEmpty {
                            SectionHeader(
                                title: "Sync conflicts",
                                count: openConflicts.count,
                                systemImage: "arrow.triangle.2.circlepath"
                            )
                            ForEach(openConflicts) { conflict in
                                SyncConflictCard(conflict: conflict)
                            }
                        }
                    }
                    .padding(18)
                }
            }
        }
        .navigationTitle("Review Queue")
    }
}

private struct SectionHeader: View {
    let title: String
    let count: Int
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.title3.bold())
            Text("\(count)")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(.orange.opacity(0.2)))
                .accessibilityLabel("\(count) open")
        }
    }
}

private struct SnapshotDiscrepancyCard: View {
    @Environment(AppModel.self) private var model
    let discrepancy: SnapshotDiscrepancyRow
    @State private var showAdjustmentConfirmation = false
    @State private var showAttestationConfirmation = false

    private var accountName: String {
        model.accountName(discrepancy.accountID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label(accountName, systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Spacer()
                Text("Observed \(dateText(discrepancy.observedEpoch))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
                valueRow("Remote snapshot", discrepancy.remoteBalanceMilliunits)
                valueRow("Local register", discrepancy.localRegisterMilliunits)
                valueRow("Required adjustment", discrepancy.differenceMilliunits)
            }
            .font(.callout)

            Text("The local register and the provider snapshot differ at the observed date. Choose an audited adjustment, or explicitly attest that no accounting adjustment is required.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Create audited adjustment") {
                    showAdjustmentConfirmation = true
                }
                .buttonStyle(.borderedProminent)
                .help("Creates the signed difference as a reconciliation-style adjustment and clears the matching snapshot pause.")

                Button("Confirm without adjustment") {
                    showAttestationConfirmation = true
                }
                .buttonStyle(.bordered)
                .help("Records an explicit manual attestation without changing the ledger.")
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
        .confirmationDialog(
            "Create a permanent ledger adjustment?",
            isPresented: $showAdjustmentConfirmation,
            titleVisibility: .visible
        ) {
            Button("Create Adjustment", role: .destructive) {
                model.actionError = nil
                Task {
                    await model.resolveSnapshotDiscrepancy(discrepancy, choice: .adjustment)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This records \(MoneyFormatting.string(discrepancy.differenceMilliunits, currency: model.budgetCurrency)) for \(accountName) at the observed snapshot date and clears only the matching review item. The change is permanent and audited.")
        }
        .confirmationDialog(
            "Confirm this discrepancy without changing the ledger?",
            isPresented: $showAttestationConfirmation,
            titleVisibility: .visible
        ) {
            Button("Record Attestation") {
                model.actionError = nil
                Task {
                    await model.resolveSnapshotDiscrepancy(
                        discrepancy,
                        choice: .manualAttestation(.confirmedWithoutAccountingAdjustment)
                    )
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears only the matching review item and records that you manually accepted the difference. It does not create an adjustment transaction.")
        }
    }

    private func valueRow(_ title: String, _ amount: Milliunits) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
            Text(MoneyFormatting.string(amount, currency: model.budgetCurrency))
                .monospacedDigit()
                .foregroundStyle(amount < 0 ? .red : .primary)
        }
    }

    private func dateText(_ epoch: Int64) -> String {
        Date(timeIntervalSince1970: TimeInterval(epoch)).formatted(date: .abbreviated, time: .shortened)
    }
}

private struct SyncConflictCard: View {
    @Environment(AppModel.self) private var model
    let conflict: SyncConflictRow
    @State private var showDestructiveConfirmation = false
    @State private var destructiveChoice: SyncConflictResolutionChoice?
    @State private var showEditSheet = false

    private var transaction: TransactionRow? {
        guard let id = conflict.transactionID else { return nil }
        return model.snapshot?.transactions.first { $0.id == id }
    }

    private var canEditDisappearedRow: Bool {
        guard let transaction else { return false }
        return transaction.cleared != .reconciled
            && !(model.snapshot?.reconciliationMembership.contains(transaction.id) ?? false)
    }

    /// `acceptRemote` is deliberately still rejected by the core for rows
    /// that are user-owned or otherwise protected. Do not offer a button that
    /// is guaranteed to fail; the user can keep the local row and edit it
    /// through the normal audited transaction workflow instead.
    private var canAcceptRemote: Bool {
        guard let transaction,
              let snapshot = model.snapshot,
              let account = snapshot.accounts.first(where: { $0.id == transaction.accountID }),
              !account.closed,
              transaction.postingState == .needsCategory,
              transaction.userEditedAtEpoch == nil,
              !transaction.approved,
              transaction.cleared == .uncleared,
              transaction.transferPairID == nil,
              transaction.refundOfTransactionID == nil,
              !snapshot.reconciliationMembership.contains(transaction.id),
              !isClosed(transaction.date.budgetMonth),
              let postedEpoch = conflict.newMetadata.postedEpoch,
              let calendar = try? BudgetCalendar(timeZoneIdentifier: snapshot.budget.timeZoneIdentifier),
              let newDate = calendar.budgetDate(fromEpoch: postedEpoch),
              !isClosed(newDate.budgetMonth)
        else { return false }
        return true
    }

    private func isClosed(_ month: BudgetMonth) -> Bool {
        model.snapshot?.closedMonths.contains { $0.month == month && $0.status == .closed } ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label(title, systemImage: "exclamationmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Spacer()
                Text(dateText(conflict.createdAtEpoch))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let transaction {
                Text("Local row: \(model.payeeName(transaction.payeeID).isEmpty ? "Unknown payee" : model.payeeName(transaction.payeeID)) · \(MoneyFormatting.string(transaction.amountMilliunits, currency: model.budgetCurrency)) · \(transaction.date.description)")
                    .font(.callout)
            }

            HStack(alignment: .top, spacing: 16) {
                metadataColumn("Stored", conflict.oldMetadata)
                metadataColumn("Remote observation", conflict.newMetadata)
            }

            actionButtons
        }
        .padding(14)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
        .confirmationDialog(
            destructiveConfirmationTitle,
            isPresented: $showDestructiveConfirmation,
            titleVisibility: .visible
        ) {
            if destructiveConfirmationIsDestructive {
                Button(destructiveConfirmationActionLabel, role: .destructive) {
                    applyDestructiveChoice()
                }
            } else {
                Button(destructiveConfirmationActionLabel) {
                    applyDestructiveChoice()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(destructiveConfirmationMessage)
        }
        .sheet(isPresented: $showEditSheet) {
            if let transaction {
                RemoteDisappearedEditSheet(conflict: conflict, transaction: transaction)
            } else {
                ContentUnavailableView("Transaction unavailable", systemImage: "exclamationmark.circle")
            }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        HStack {
            switch conflict.eventKind {
            case .remoteChanged:
                Button("Keep local") {
                    resolve(.remoteChanged(.keepLocal))
                }
                if canAcceptRemote {
                    Button("Accept remote") {
                        confirm(.remoteChanged(.acceptRemote))
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Text("Accept remote is unavailable for this protected row.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .remoteDisappeared:
                Button("Keep local") {
                    resolve(.remoteDisappeared(.keepLocal))
                }
                if canEditDisappearedRow {
                    Button("Edit local row…") {
                        showEditSheet = true
                    }
                }
                Button("Void imported row", role: .destructive) {
                    confirm(.remoteDisappeared(.softVoidImported))
                }
            case .manualPotentialDuplicate:
                Button("Keep both") {
                    resolve(.manualPotentialDuplicate(.keepBoth))
                }
                Button("Void imported row", role: .destructive) {
                    confirm(.manualPotentialDuplicate(.softVoidImported))
                }
                Button("Delete manual row", role: .destructive) {
                    confirm(.manualPotentialDuplicate(.deleteManual))
                }
            }
        }
        .buttonStyle(.bordered)
    }

    private var title: String {
        switch conflict.eventKind {
        case .remoteChanged: return "Remote transaction changed"
        case .remoteDisappeared: return "Remote transaction disappeared"
        case .manualPotentialDuplicate: return "Possible manual/import duplicate"
        }
    }

    private func metadataColumn(_ label: String, _ metadata: SyncConflictMetadata) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption.weight(.semibold))
            if let amount = metadata.amountDecimalString { Text("Provider amount (raw): \(amount)") }
            if let date = metadata.date { Text("Date: \(date)") }
            if let postedEpoch = metadata.postedEpoch { Text("Posted: \(dateText(postedEpoch))") }
            if let transactedEpoch = metadata.transactedEpoch { Text("Transacted: \(dateText(transactedEpoch))") }
            if let payee = metadata.payeeDisplay, !payee.isEmpty { Text("Payee: \(payee)") }
            if let description = metadata.descriptionText, !description.isEmpty { Text("Description: \(description)") }
            if let note = metadata.note, !note.isEmpty { Text(note) }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func dateText(_ epoch: Int64) -> String {
        Date(timeIntervalSince1970: TimeInterval(epoch)).formatted(date: .abbreviated, time: .shortened)
    }

    private func resolve(_ choice: SyncConflictResolutionChoice) {
        model.actionError = nil
        Task { await model.resolveSyncConflict(conflict, choice: choice) }
    }

    private func confirm(_ choice: SyncConflictResolutionChoice) {
        destructiveChoice = choice
        showDestructiveConfirmation = true
    }

    private func applyDestructiveChoice() {
        guard let destructiveChoice else { return }
        model.actionError = nil
        Task { await model.resolveSyncConflict(conflict, choice: destructiveChoice) }
    }

    private var destructiveConfirmationTitle: String {
        switch destructiveChoice {
        case .some(.remoteChanged(.acceptRemote)):
            return "Accept the remote transaction change?"
        case .some(.remoteDisappeared(.softVoidImported)):
            return "Void the imported transaction?"
        case .some(.manualPotentialDuplicate(.softVoidImported)):
            return "Void the imported duplicate?"
        case .some(.manualPotentialDuplicate(.deleteManual)):
            return "Delete the manual duplicate?"
        default:
            return "Confirm sync conflict action?"
        }
    }

    private var destructiveConfirmationActionLabel: String {
        switch destructiveChoice {
        case .some(.remoteChanged(.acceptRemote)):
            return "Accept Remote"
        case .some(.remoteDisappeared(.softVoidImported)),
             .some(.manualPotentialDuplicate(.softVoidImported)):
            return "Void Imported Row"
        case .some(.manualPotentialDuplicate(.deleteManual)):
            return "Delete Manual Row"
        default:
            return "Confirm"
        }
    }

    private var destructiveConfirmationIsDestructive: Bool {
        switch destructiveChoice {
        case .some(.remoteDisappeared(.softVoidImported)),
             .some(.manualPotentialDuplicate(.softVoidImported)),
             .some(.manualPotentialDuplicate(.deleteManual)):
            return true
        default:
            return false
        }
    }

    private var destructiveConfirmationMessage: String {
        switch destructiveChoice {
        case .some(.remoteChanged(.acceptRemote)):
            return "This applies the stored provider observation to the local row atomically and records the decision in the audit history."
        case .some(.remoteDisappeared(.softVoidImported)):
            return "This soft-voids the imported row, preserves its import identity, and records that the provider no longer returned it."
        case .some(.manualPotentialDuplicate(.softVoidImported)):
            return "This soft-voids the imported row while preserving the manual row and both identities."
        case .some(.manualPotentialDuplicate(.deleteManual)):
            return "This permanently deletes the manual row after the core dependency checks pass."
        default:
            return "This decision is atomic and recorded in the local audit history."
        }
    }
}

private struct RemoteDisappearedEditSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let conflict: SyncConflictRow
    let transaction: TransactionRow

    @State private var dateText: String
    @State private var memo: String
    @State private var approved: Bool
    @State private var cleared: ClearedState

    init(conflict: SyncConflictRow, transaction: TransactionRow) {
        self.conflict = conflict
        self.transaction = transaction
        _dateText = State(initialValue: transaction.date.description)
        _memo = State(initialValue: transaction.memo ?? "")
        _approved = State(initialValue: transaction.approved)
        _cleared = State(initialValue: transaction.cleared == .reconciled ? .cleared : transaction.cleared)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit local row")
                .font(.title3.bold())
            Text("The remote row disappeared. These bounded local edits will be applied atomically with the acknowledgement; amount and imported identity remain unchanged.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Form {
                TextField("Date (YYYY-MM-DD)", text: $dateText)
                TextEditor(text: $memo)
                    .frame(minHeight: 70)
                    .overlay(alignment: .topLeading) {
                        if memo.isEmpty {
                            Text("Memo")
                                .foregroundStyle(.tertiary)
                                .padding(.top, 8)
                                .padding(.leading, 4)
                                .allowsHitTesting(false)
                        }
                    }
                Toggle("Approved", isOn: $approved)
                Picker("Cleared", selection: $cleared) {
                    Text("Uncleared").tag(ClearedState.uncleared)
                    Text("Cleared").tag(ClearedState.cleared)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Apply edits and keep") { submit() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func submit() {
        model.actionError = nil
        guard let date = parseBudgetDate(dateText) else {
            model.actionError = "Enter a valid date in YYYY-MM-DD format."
            return
        }
        var edits: [RemoteDisappearedLocalEdit] = []
        if date != transaction.date { edits.append(.date(date)) }
        let normalizedMemo = memo.isEmpty ? nil : memo
        if normalizedMemo != transaction.memo { edits.append(.memo(normalizedMemo)) }
        if approved != transaction.approved { edits.append(.approval(approved)) }
        let originalCleared = transaction.cleared == .reconciled ? .cleared : transaction.cleared
        if cleared != originalCleared { edits.append(.cleared(cleared)) }
        Task {
            await model.resolveSyncConflict(
                conflict,
                choice: edits.isEmpty
                    ? .remoteDisappeared(.keepLocal)
                    : .remoteDisappeared(.editLocal(edits)),
                expectedTransactionFingerprint: transaction.accountingFingerprint
            )
            if model.actionError == nil { dismiss() }
        }
    }

    private func parseBudgetDate(_ value: String) -> BudgetDate? {
        BudgetDate(string: value)
    }
}

import Foundation

extension BudgetWorkspace {

    // MARK: - Commit (D6.3/D6.4)

    /// Materializes every preview row marked `.import` through the shared
    /// import path (closed-month staging, rules, payee learning, sign
    /// default), records one `FileImportRecord` per row and one
    /// `ImportBatchRow` for provenance, replays once, and bumps the revision.
    /// Rows marked `.skip` are counted, never inserted. A thrown error leaves
    /// the workspace unchanged.
    @discardableResult
    public mutating func commitImportBatch(
        accountID: AccountID,
        format: ImportFormat,
        fileName: String,
        rows: [ImportPreviewRow],
        nowEpoch: Int64
    ) throws -> ImportBatchSummary {
        guard let account = accounts[accountID] else { throw MutationError.accountNotFound }
        guard !account.closed else { throw MutationError.accountClosed }

        var copy = self
        let batch = ImportBatchRow(
            budgetID: budget.id, accountID: accountID, format: format,
            fileName: String(fileName.prefix(120)), importedAtEpoch: nowEpoch,
            importedCount: 0, skippedCount: 0
        )
        var imported = 0
        var skipped = 0
        var needsCategory = 0
        var staged = 0
        var usedRowKeys = Set<String>()
        for preview in rows.sorted(by: { $0.row.index < $1.row.index }) {
            guard preview.decision == .import else { skipped += 1; continue }
            let row = preview.row
            guard row.date.budgetMonth >= budget.firstMonth else { throw MutationError.dateBeforeFirstMonth }
            guard row.date.budgetMonth <= currentMonth else { throw MutationError.futureDatedTransaction }
            let fingerprint = row.fingerprint(accountID: accountID)
            // Defensive re-check: a certain duplicate never lands twice even
            // if the caller passed a stale preview.
            let alreadyImported = copy.fileImports.values.contains { record in
                guard copy.transactions[record.transactionID]?.accountID == accountID else { return false }
                if let externalID = row.externalID, !externalID.isEmpty, record.externalID == externalID { return true }
                return record.fingerprint == fingerprint
            }
            if alreadyImported { skipped += 1; continue }
            let rowKey = row.externalID.flatMap { $0.isEmpty ? nil : $0 } ?? fingerprint
            guard usedRowKeys.insert(rowKey).inserted else { skipped += 1; continue }

            let materialized = try copy.materializeImportedRow(
                accountID: accountID,
                sourceKind: .file,
                sourceOrderKey: .file(batchKey: batch.id.description, rowKey: rowKey),
                date: row.date,
                effectiveAtEpoch: try calendar.noonEpoch(of: row.date),
                payeeName: row.description,
                amountMilliunits: row.amountMilliunits,
                memo: row.memo,
                nowEpoch: nowEpoch
            )
            copy.setFileImport(FileImportRecord(
                transactionID: materialized.id,
                budgetID: budget.id,
                batchID: batch.id,
                externalID: row.externalID.flatMap { $0.isEmpty ? nil : $0 },
                fingerprint: fingerprint,
                rawFields: row.rawFields
            ))
            imported += 1
            switch materialized.postingState {
            case .needsCategory: needsCategory += 1
            case .staged: staged += 1
            default: break
            }
        }
        var finished = batch
        finished.importedCount = imported
        finished.skippedCount = skipped
        copy.setImportBatch(finished)
        try copy.runReplayAndApplyDecisions()
        if let today = calendar.budgetDate(fromEpoch: nowEpoch) {
            copy.matchSchedules(asOf: today, nowEpoch: nowEpoch)
        }
        // Split rows produced by rules do not show as needsCategory in the
        // pre-replay count; recount from the committed rows for accuracy.
        needsCategory = copy.transactions.values.filter { copy.fileImports[$0.id]?.batchID == batch.id && $0.postingState == .needsCategory }.count
        staged = copy.transactions.values.filter { copy.fileImports[$0.id]?.batchID == batch.id && $0.postingState == .staged }.count
        copy.recordAudit(
            entityType: "importBatch", entityID: batch.id.description, eventKind: "fileImported",
            metadata: ["format": format.rawValue, "imported": String(imported), "skipped": String(skipped)],
            nowEpoch: nowEpoch
        )
        try copy.bumpRevision()
        self = copy
        return ImportBatchSummary(
            batchID: batch.id, importedCount: imported, skippedCount: skipped,
            needsCategoryCount: needsCategory, stagedCount: staged
        )
    }

    // MARK: - Saved mappings (D6.2)

    @discardableResult
    public mutating func saveImportMapping(
        name: String,
        headerFingerprint: String?,
        mapping: CSVImportMapping,
        nowEpoch: Int64
    ) throws -> ImportMappingID {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MutationError.nameEmpty }
        var copy = self
        // Same name replaces the previous mapping (an explicit "save as").
        if let existing = copy.importMappings.values.first(where: { $0.name.compare(trimmed, options: .caseInsensitive) == .orderedSame }) {
            var updated = existing
            updated.mapping = mapping
            updated.headerFingerprint = headerFingerprint
            updated.lastUsedAtEpoch = nowEpoch
            copy.setImportMapping(updated)
            try copy.bumpRevision()
            self = copy
            return updated.id
        }
        let row = ImportMappingRow(
            budgetID: budget.id, name: trimmed, headerFingerprint: headerFingerprint,
            mapping: mapping, createdAtEpoch: nowEpoch, lastUsedAtEpoch: nowEpoch
        )
        copy.setImportMapping(row)
        try copy.bumpRevision()
        self = copy
        return row.id
    }

    public mutating func deleteImportMapping(_ id: ImportMappingID) throws {
        guard importMappings[id] != nil else { throw MutationError.entityNotFound }
        var copy = self
        copy.removeImportMapping(id)
        try copy.bumpRevision()
        self = copy
    }

    public mutating func touchImportMapping(_ id: ImportMappingID, nowEpoch: Int64) throws {
        guard var row = importMappings[id] else { throw MutationError.entityNotFound }
        row.lastUsedAtEpoch = nowEpoch
        var copy = self
        copy.setImportMapping(row)
        try copy.bumpRevision()
        self = copy
    }

    /// The saved mapping whose header fingerprint matches, if any.
    public func importMapping(matchingHeader fingerprint: String) -> ImportMappingRow? {
        importMappings.values
            .filter { $0.headerFingerprint == fingerprint }
            .max { ($0.lastUsedAtEpoch, $0.id) < ($1.lastUsedAtEpoch, $1.id) }
    }
}

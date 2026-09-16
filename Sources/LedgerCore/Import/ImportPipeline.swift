import Foundation

/// File → parse → normalize → validate → detect duplicates → preview (D6.3).
/// Everything here is pure; committing is a workspace mutation.
public enum ImportPipeline {

    /// Parses a file into records. CSV requires a mapping; OFX/QFX carry
    /// their own structure and return every statement block found.
    public static func parse(data: Data, format: ImportFormat, csvMapping: CSVImportMapping?) throws -> [ParsedImportRecord] {
        switch format {
        case .csv:
            guard let text = CSVParser.decode(data) else { throw ImportError.unreadableFile }
            guard let mapping = csvMapping else { throw ImportError.mappingColumnOutOfRange }
            let rows = CSVParser.parse(text, delimiter: mapping.delimiter)
            guard !rows.isEmpty else { throw ImportError.emptyFile }
            return try CSVParser.records(from: rows, mapping: mapping)
        case .ofx, .qfx:
            guard let text = OFXParser.decode(data) else { throw ImportError.unreadableFile }
            let statements = try OFXParser.parse(text)
            return statements.flatMap(\.records)
        }
    }

    /// Normalizes parsed records against the budget calendar and bounds.
    /// Rows outside `firstMonth…currentMonth` are reported, never clamped.
    public static func normalize(
        _ records: [ParsedImportRecord],
        format: ImportFormat,
        csvMapping: CSVImportMapping?,
        firstMonth: BudgetMonth,
        currentMonth: BudgetMonth
    ) -> (rows: [NormalizedImportRow], issues: [ImportIssue]) {
        var rows: [NormalizedImportRow] = []
        var issues: [ImportIssue] = []
        for record in records {
            let description = record.description.trimmingCharacters(in: .whitespacesAndNewlines)
            if description.isEmpty && record.rawAmount.isEmpty && record.rawDate.isEmpty {
                issues.append(ImportIssue(lineNumber: record.lineNumber, kind: .emptyRow, detail: "Empty row"))
                continue
            }
            let date: BudgetDate?
            switch format {
            case .csv: date = ImportDateParser.date(from: record.rawDate, format: csvMapping?.dateFormat ?? "yyyy-MM-dd")
            case .ofx, .qfx: date = ImportDateParser.ofxDate(record.rawDate)
            }
            guard let date else {
                issues.append(ImportIssue(lineNumber: record.lineNumber, kind: .unparsableDate, detail: "Date “\(record.rawDate)” did not match the format"))
                continue
            }
            let amount: Milliunits
            do {
                var parsed = try ImportAmountParser.milliunits(from: record.rawAmount, decimalSeparator: csvMapping?.decimalSeparator ?? ".")
                if csvMapping?.invertSign == true, format == .csv { parsed = try negChecked(parsed) }
                amount = parsed
            } catch {
                issues.append(ImportIssue(lineNumber: record.lineNumber, kind: .unparsableAmount, detail: "Amount “\(record.rawAmount)” is not a number"))
                continue
            }
            guard amount != 0 else {
                issues.append(ImportIssue(lineNumber: record.lineNumber, kind: .zeroAmount, detail: "Zero amount"))
                continue
            }
            guard date.budgetMonth >= firstMonth else {
                issues.append(ImportIssue(lineNumber: record.lineNumber, kind: .dateBeforeFirstMonth, detail: "\(date.description) is before the budget's first month"))
                continue
            }
            guard date.budgetMonth <= currentMonth else {
                issues.append(ImportIssue(lineNumber: record.lineNumber, kind: .futureDate, detail: "\(date.description) is in a future month"))
                continue
            }
            rows.append(NormalizedImportRow(
                index: rows.count,
                lineNumber: record.lineNumber,
                date: date,
                amountMilliunits: amount,
                description: description.isEmpty ? "Unknown" : description,
                memo: record.memo?.trimmingCharacters(in: .whitespacesAndNewlines),
                externalID: record.externalID?.trimmingCharacters(in: .whitespacesAndNewlines),
                checkNumber: record.checkNumber,
                rawFields: record.rawFields
            ))
        }
        return (rows, issues)
    }
}

extension BudgetWorkspace {

    /// Conservative duplicate detection (D6.5), in order: same external ID on
    /// this account; same fingerprint; a repeat inside the file; then a
    /// possible duplicate when any non-voided row on the account has the same
    /// amount within ±3 days. Certain and possible duplicates default to
    /// skip; the user can flip a possible duplicate to import.
    public func classifyImportRows(_ rows: [NormalizedImportRow], accountID: AccountID) -> [ImportPreviewRow] {
        var byExternalID: [String: TransactionID] = [:]
        var byFingerprint: [String: TransactionID] = [:]
        for record in fileImports.values {
            guard let row = transactions[record.transactionID], row.accountID == accountID else { continue }
            if let externalID = record.externalID { byExternalID[externalID] = record.transactionID }
            byFingerprint[record.fingerprint] = record.transactionID
        }
        // Amount → rows on this account, for the fuzzy pass.
        var byAmount: [Milliunits: [TransactionRow]] = [:]
        for row in transactions.values where row.accountID == accountID && row.postingState != .voided {
            byAmount[row.amountMilliunits, default: []].append(row)
        }
        var seenExternal = Set<String>()
        var seenFingerprints = Set<String>()
        return rows.map { row in
            let fingerprint = row.fingerprint(accountID: accountID)
            if let externalID = row.externalID, !externalID.isEmpty {
                if let existing = byExternalID[externalID] {
                    return ImportPreviewRow(row: row, status: .duplicate(existing: existing, reason: .externalID), decision: .skip)
                }
                if !seenExternal.insert(externalID).inserted {
                    return ImportPreviewRow(row: row, status: .duplicate(existing: nil, reason: .withinFile), decision: .skip)
                }
            }
            if let existing = byFingerprint[fingerprint] {
                return ImportPreviewRow(row: row, status: .duplicate(existing: existing, reason: .fingerprint), decision: .skip)
            }
            if !seenFingerprints.insert(fingerprint).inserted {
                return ImportPreviewRow(row: row, status: .duplicate(existing: nil, reason: .withinFile), decision: .skip)
            }
            let day = BudgetWorkspace.civilDayNumber(row.date)
            let candidates = (byAmount[row.amountMilliunits] ?? [])
                .filter { abs(BudgetWorkspace.civilDayNumber($0.date) - day) <= 3 }
                .sorted { ($0.date, $0.id) < ($1.date, $1.id) }
                .map(\.id)
            if !candidates.isEmpty {
                return ImportPreviewRow(row: row, status: .possibleDuplicate(candidates: candidates), decision: .skip)
            }
            return ImportPreviewRow(row: row, status: .new, decision: .import)
        }
    }
}

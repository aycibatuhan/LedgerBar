import CryptoKit
import Foundation

// MARK: - Formats and parsed records (docs/DESIGN.md D6)

public enum ImportFormat: String, Sendable, Codable, CaseIterable {
    case csv
    case ofx
    case qfx

    public static func detect(fileName: String, data: Data) -> ImportFormat? {
        let ext = (fileName as NSString).pathExtension.lowercased()
        switch ext {
        case "csv", "txt", "tsv": return .csv
        case "ofx": return .ofx
        case "qfx": return .qfx
        default: break
        }
        // Content sniff: OFX files carry an OFX header or <OFX> root.
        let head = String(decoding: data.prefix(2_048), as: UTF8.self).uppercased()
        if head.contains("OFXHEADER") || head.contains("<OFX>") { return .ofx }
        if head.contains(",") || head.contains(";") || head.contains("\t") { return .csv }
        return nil
    }

    public var usesFITID: Bool { self != .csv }
}

/// A record as the parser saw it: strings only, with the raw fields kept
/// (bounded) so provenance can be audited after import.
public struct ParsedImportRecord: Sendable, Equatable {
    public var lineNumber: Int
    public var rawDate: String
    public var rawAmount: String
    public var description: String
    public var memo: String?
    public var externalID: String?
    public var checkNumber: String?
    public var rawFields: [String: String]

    public init(
        lineNumber: Int,
        rawDate: String,
        rawAmount: String,
        description: String,
        memo: String? = nil,
        externalID: String? = nil,
        checkNumber: String? = nil,
        rawFields: [String: String] = [:]
    ) {
        self.lineNumber = lineNumber
        self.rawDate = rawDate
        self.rawAmount = rawAmount
        self.description = description
        self.memo = memo
        self.externalID = externalID
        self.checkNumber = checkNumber
        self.rawFields = rawFields
    }
}

// MARK: - CSV mapping (D6.2)

public enum CSVAmountLayout: Sendable, Codable, Equatable, Hashable {
    /// One signed column (negative = outflow unless `invertSign`).
    case signed(column: Int)
    /// Separate debit (outflow) and credit (inflow) columns, magnitudes.
    case debitCredit(debit: Int, credit: Int)
    /// A magnitude column plus a type column whose listed values mean outflow.
    case amountWithType(amount: Int, type: Int, outflowValues: [String])
}

public struct CSVImportMapping: Sendable, Codable, Equatable, Hashable {
    public var hasHeader: Bool
    public var delimiter: String
    public var dateColumn: Int
    /// Unicode date format pattern (for example `MM/dd/yyyy`).
    public var dateFormat: String
    public var amountLayout: CSVAmountLayout
    public var invertSign: Bool
    public var decimalSeparator: String
    public var payeeColumn: Int
    public var memoColumn: Int?
    public var externalIDColumn: Int?
    public var checkNumberColumn: Int?

    public init(
        hasHeader: Bool = true,
        delimiter: String = ",",
        dateColumn: Int,
        dateFormat: String,
        amountLayout: CSVAmountLayout,
        invertSign: Bool = false,
        decimalSeparator: String = ".",
        payeeColumn: Int,
        memoColumn: Int? = nil,
        externalIDColumn: Int? = nil,
        checkNumberColumn: Int? = nil
    ) {
        self.hasHeader = hasHeader
        self.delimiter = delimiter
        self.dateColumn = dateColumn
        self.dateFormat = dateFormat
        self.amountLayout = amountLayout
        self.invertSign = invertSign
        self.decimalSeparator = decimalSeparator
        self.payeeColumn = payeeColumn
        self.memoColumn = memoColumn
        self.externalIDColumn = externalIDColumn
        self.checkNumberColumn = checkNumberColumn
    }

    /// Stable fingerprint of a header row so a repeat export from the same
    /// bank pre-selects its saved mapping.
    public static func headerFingerprint(_ header: [String]) -> String {
        let canonical = header.map { BudgetWorkspace.normalizePayeeName($0) }.joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// A saved, budget-scoped mapping.
public struct ImportMappingRow: Sendable, Codable, Equatable, Identifiable {
    public var id: ImportMappingID
    public var budgetID: BudgetID
    public var name: String
    public var format: ImportFormat
    public var headerFingerprint: String?
    public var mapping: CSVImportMapping
    public var createdAtEpoch: Int64
    public var lastUsedAtEpoch: Int64

    public init(
        id: ImportMappingID = ImportMappingID(),
        budgetID: BudgetID,
        name: String,
        format: ImportFormat = .csv,
        headerFingerprint: String?,
        mapping: CSVImportMapping,
        createdAtEpoch: Int64,
        lastUsedAtEpoch: Int64
    ) {
        self.id = id
        self.budgetID = budgetID
        self.name = name
        self.format = format
        self.headerFingerprint = headerFingerprint
        self.mapping = mapping
        self.createdAtEpoch = createdAtEpoch
        self.lastUsedAtEpoch = lastUsedAtEpoch
    }
}

// MARK: - Normalized rows, dedup, preview (D6.3/D6.5)

public struct NormalizedImportRow: Sendable, Equatable, Identifiable {
    public var index: Int
    public var lineNumber: Int
    public var date: BudgetDate
    public var amountMilliunits: Milliunits
    public var description: String
    public var memo: String?
    public var externalID: String?
    public var checkNumber: String?
    public var rawFields: [String: String]
    public var id: Int { index }

    public init(
        index: Int,
        lineNumber: Int,
        date: BudgetDate,
        amountMilliunits: Milliunits,
        description: String,
        memo: String? = nil,
        externalID: String? = nil,
        checkNumber: String? = nil,
        rawFields: [String: String] = [:]
    ) {
        self.index = index
        self.lineNumber = lineNumber
        self.date = date
        self.amountMilliunits = amountMilliunits
        self.description = description
        self.memo = memo
        self.externalID = externalID
        self.checkNumber = checkNumber
        self.rawFields = rawFields
    }

    /// Conservative identity for rows without an external ID: SHA-256 over
    /// account, date, amount, normalized description, and external ID.
    public func fingerprint(accountID: AccountID) -> String {
        let canonical = [
            accountID.description,
            date.description,
            String(amountMilliunits),
            BudgetWorkspace.normalizePayeeName(description),
            externalID ?? ""
        ].joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Why a parsed record could not be normalized. Skipped rows are reported,
/// never silently dropped.
public struct ImportIssue: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable {
        case unparsableDate
        case unparsableAmount
        case zeroAmount
        case emptyRow
        case dateBeforeFirstMonth
        case futureDate
    }
    public var lineNumber: Int
    public var kind: Kind
    public var detail: String
    public var id: String { "\(lineNumber)-\(kind.rawValue)" }

    public init(lineNumber: Int, kind: Kind, detail: String) {
        self.lineNumber = lineNumber
        self.kind = kind
        self.detail = detail
    }
}

public enum ImportDuplicateStatus: Sendable, Equatable {
    case new
    /// Certain duplicate: same external ID or same fingerprint as an existing
    /// file-import record, or a repeat inside the same file.
    case duplicate(existing: TransactionID?, reason: DuplicateReason)
    /// Same account, amount, and a date within ±3 days of an existing row.
    case possibleDuplicate(candidates: [TransactionID])

    public enum DuplicateReason: String, Sendable {
        case externalID
        case fingerprint
        case withinFile
    }
}

public enum ImportDecision: String, Sendable, Codable {
    case `import`
    case skip
}

public struct ImportPreviewRow: Sendable, Equatable, Identifiable {
    public var row: NormalizedImportRow
    public var status: ImportDuplicateStatus
    public var decision: ImportDecision
    public var id: Int { row.index }

    public init(row: NormalizedImportRow, status: ImportDuplicateStatus, decision: ImportDecision) {
        self.row = row
        self.status = status
        self.decision = decision
    }
}

// MARK: - Persisted provenance (D6.4)

public struct ImportBatchRow: Sendable, Codable, Equatable, Identifiable {
    public var id: ImportBatchID
    public var budgetID: BudgetID
    public var accountID: AccountID
    public var format: ImportFormat
    public var fileName: String
    public var importedAtEpoch: Int64
    public var importedCount: Int
    public var skippedCount: Int

    public init(
        id: ImportBatchID = ImportBatchID(),
        budgetID: BudgetID,
        accountID: AccountID,
        format: ImportFormat,
        fileName: String,
        importedAtEpoch: Int64,
        importedCount: Int,
        skippedCount: Int
    ) {
        self.id = id
        self.budgetID = budgetID
        self.accountID = accountID
        self.format = format
        self.fileName = fileName
        self.importedAtEpoch = importedAtEpoch
        self.importedCount = importedCount
        self.skippedCount = skippedCount
    }
}

/// Exactly one per file-imported transaction (`source_kind == .file` iff a
/// record exists), mirroring `SimpleFINImportRecord`.
public struct FileImportRecord: Sendable, Codable, Equatable {
    public var transactionID: TransactionID
    public var budgetID: BudgetID
    public var batchID: ImportBatchID
    public var externalID: String?
    public var fingerprint: String
    /// Bounded, sanitized raw fields from the file for audit.
    public var rawFields: [String: String]

    public init(
        transactionID: TransactionID,
        budgetID: BudgetID,
        batchID: ImportBatchID,
        externalID: String?,
        fingerprint: String,
        rawFields: [String: String]
    ) {
        self.transactionID = transactionID
        self.budgetID = budgetID
        self.batchID = batchID
        self.externalID = externalID
        self.fingerprint = fingerprint
        self.rawFields = rawFields
    }
}

public struct ImportBatchSummary: Sendable, Equatable {
    public var batchID: ImportBatchID
    public var importedCount: Int
    public var skippedCount: Int
    public var needsCategoryCount: Int
    public var stagedCount: Int
}

public enum ImportError: Error, Equatable, Sendable {
    case unreadableFile
    case unsupportedFormat
    case emptyFile
    case mappingColumnOutOfRange
    case noAccountBlock
    case accountNotEligible
}

import Foundation

/// RFC 4180-style parser: quoted fields, doubled quotes, embedded newlines,
/// CR/LF/CRLF line endings, configurable delimiter, BOM stripped. Pure and
/// allocation-bounded by the input size.
public enum CSVParser {
    public static func decode(_ data: Data) -> String? {
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        if let utf8 = String(data: bytes, encoding: .utf8) { return utf8 }
        if let latin = String(data: bytes, encoding: .windowsCP1252) { return latin }
        return String(data: bytes, encoding: .isoLatin1)
    }

    /// Guesses the delimiter from the first line: the candidate with the most
    /// occurrences wins; ties prefer comma.
    public static func guessDelimiter(_ text: String) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let candidates = [",", ";", "\t", "|"]
        var best = ","
        var bestCount = -1
        for candidate in candidates {
            let count = firstLine.filter { String($0) == candidate }.count
            if count > bestCount { best = candidate; bestCount = count }
        }
        return best
    }

    public static func parse(_ text: String, delimiter: String = ",") -> [[String]] {
        let delimiterChar: Character = delimiter.first ?? ","
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = text.makeIterator()
        var pending: Character? = nil

        func nextChar() -> Character? {
            if let p = pending { pending = nil; return p }
            return iterator.next()
        }

        while let ch = nextChar() {
            if inQuotes {
                if ch == "\"" {
                    if let following = nextChar() {
                        if following == "\"" {
                            field.append("\"")
                        } else {
                            inQuotes = false
                            pending = following
                        }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(ch)
                }
                continue
            }
            switch ch {
            case "\"" where field.isEmpty:
                // A quote opens a quoted field only at the field start; a
                // quote inside an unquoted field is literal (lenient, like
                // most bank exports expect).
                inQuotes = true
            case delimiterChar:
                row.append(field); field = ""
            case "\r":
                if let following = nextChar(), following != "\n" { pending = following }
                row.append(field); field = ""
                rows.append(row); row = []
            case "\n", "\r\n": // Swift treats CRLF as one grapheme cluster
                row.append(field); field = ""
                rows.append(row); row = []
            default:
                field.append(ch)
            }
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        // Drop rows that are entirely empty (trailing blank lines).
        return rows.filter { !$0.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } }
    }

    /// Applies a mapping to parsed rows.
    public static func records(from rows: [[String]], mapping: CSVImportMapping) throws -> [ParsedImportRecord] {
        var result: [ParsedImportRecord] = []
        let header = mapping.hasHeader ? rows.first : nil
        let body = mapping.hasHeader ? Array(rows.dropFirst()) : rows
        func columnName(_ index: Int) -> String {
            if let header, header.indices.contains(index) {
                let name = header[index].trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { return name }
            }
            return "column\(index + 1)"
        }
        for (offset, row) in body.enumerated() {
            let lineNumber = offset + (mapping.hasHeader ? 2 : 1)
            func cell(_ index: Int?) -> String? {
                guard let index else { return nil }
                guard row.indices.contains(index) else { return nil }
                let value = row[index].trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }
            guard mapping.dateColumn < max(row.count, 1), mapping.payeeColumn < max(row.count, 1) else {
                throw ImportError.mappingColumnOutOfRange
            }
            let rawAmount: String
            switch mapping.amountLayout {
            case .signed(let column):
                rawAmount = cell(column) ?? ""
            case let .debitCredit(debit, credit):
                let d = cell(debit)
                let c = cell(credit)
                if let d, !d.isEmpty, ImportAmountParser.isNonZero(d) {
                    rawAmount = "-" + d.trimmingCharacters(in: CharacterSet(charactersIn: "+-"))
                } else if let c {
                    rawAmount = c
                } else {
                    rawAmount = ""
                }
            case let .amountWithType(amount, type, outflowValues):
                let magnitude = cell(amount) ?? ""
                let typeValue = BudgetWorkspace.normalizePayeeName(cell(type) ?? "")
                let outflow = outflowValues.map { BudgetWorkspace.normalizePayeeName($0) }.contains(typeValue)
                rawAmount = outflow ? "-" + magnitude.trimmingCharacters(in: CharacterSet(charactersIn: "+-")) : magnitude
            }
            var raw: [String: String] = [:]
            for (index, value) in row.enumerated() where !value.isEmpty && raw.count < 24 {
                raw[columnName(index)] = String(value.prefix(200))
            }
            result.append(ParsedImportRecord(
                lineNumber: lineNumber,
                rawDate: cell(mapping.dateColumn) ?? "",
                rawAmount: rawAmount,
                description: cell(mapping.payeeColumn) ?? "",
                memo: cell(mapping.memoColumn),
                externalID: cell(mapping.externalIDColumn),
                checkNumber: cell(mapping.checkNumberColumn),
                rawFields: raw
            ))
        }
        return result
    }

    /// Heuristic mapping guess from a header row: looks for common column
    /// names used by US bank exports. Returns nil when no date column is
    /// recognizable; the user then maps by hand.
    public static func guessMapping(header: [String], sampleRows: [[String]], delimiter: String) -> CSVImportMapping? {
        let names = header.map { BudgetWorkspace.normalizePayeeName($0) }
        func find(_ candidates: [String]) -> Int? {
            for candidate in candidates {
                if let index = names.firstIndex(where: { $0 == candidate }) { return index }
            }
            for candidate in candidates {
                if let index = names.firstIndex(where: { $0.contains(candidate) }) { return index }
            }
            return nil
        }
        guard let dateColumn = find(["DATE", "TRANSACTION DATE", "POSTED DATE", "POST DATE", "TRANS DATE", "BOOKING DATE"]) else {
            return nil
        }
        let payeeColumn = find(["DESCRIPTION", "PAYEE", "NAME", "MERCHANT", "MEMO", "DETAILS", "NARRATIVE"]) ?? (names.indices.first { $0 != dateColumn } ?? 0)
        let memoColumn: Int? = {
            let candidates = ["MEMO", "NOTES", "NOTE", "EXTENDED DESCRIPTION", "ORIGINAL DESCRIPTION", "CATEGORY"]
            guard let index = find(candidates), index != payeeColumn else { return nil }
            return index
        }()
        let externalIDColumn = find(["TRANSACTION ID", "REFERENCE", "REFERENCE NUMBER", "FITID", "ID"])
        let checkColumn = find(["CHECK NUMBER", "CHECK NO", "CHECK #", "CHECK"])
        let amountLayout: CSVAmountLayout
        if let debit = find(["DEBIT", "WITHDRAWAL", "WITHDRAWALS", "MONEY OUT", "OUTFLOW"]),
           let credit = find(["CREDIT", "DEPOSIT", "DEPOSITS", "MONEY IN", "INFLOW"]), debit != credit {
            amountLayout = .debitCredit(debit: debit, credit: credit)
        } else if let amount = find(["AMOUNT", "TRANSACTION AMOUNT", "VALUE"]) {
            if let type = find(["TRANSACTION TYPE", "TYPE", "DEBIT/CREDIT", "DR/CR"]),
               sampleRows.contains(where: { $0.indices.contains(type) && ["DEBIT", "DR"].contains(BudgetWorkspace.normalizePayeeName($0[type])) }),
               !sampleRows.contains(where: { $0.indices.contains(amount) && $0[amount].contains("-") }) {
                amountLayout = .amountWithType(amount: amount, type: type, outflowValues: ["debit", "dr", "withdrawal"])
            } else {
                amountLayout = .signed(column: amount)
            }
        } else {
            return nil
        }
        let sampleDates = sampleRows.compactMap { $0.indices.contains(dateColumn) ? $0[dateColumn] : nil }
        let dateFormat = ImportDateParser.guessFormat(samples: sampleDates) ?? "MM/dd/yyyy"
        return CSVImportMapping(
            hasHeader: true,
            delimiter: delimiter,
            dateColumn: dateColumn,
            dateFormat: dateFormat,
            amountLayout: amountLayout,
            payeeColumn: payeeColumn,
            memoColumn: memoColumn,
            externalIDColumn: externalIDColumn,
            checkNumberColumn: checkColumn
        )
    }
}

/// Lenient, deterministic amount reading for bank exports: currency symbols
/// and grouping separators are stripped, `(12.34)` and trailing `-` mean
/// negative, and the result goes through the strict `MoneyParser`.
public enum ImportAmountParser {
    public static func milliunits(from raw: String, decimalSeparator: String = ".") throws -> Milliunits {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw MoneyParseError.malformed }
        var negative = false
        if text.hasPrefix("(") && text.hasSuffix(")") {
            negative = true
            text = String(text.dropFirst().dropLast())
        }
        if text.hasSuffix("-") { negative = true; text = String(text.dropLast()) }
        if text.hasPrefix("-") { negative.toggle(); text = String(text.dropFirst()) }
        if text.hasPrefix("+") { text = String(text.dropFirst()) }
        let upper = text.uppercased()
        if upper.hasSuffix("CR") { text = String(text.dropLast(2)) }
        if upper.hasSuffix("DR") { negative = true; text = String(text.dropLast(2)) }
        let separator = decimalSeparator.first ?? "."
        var cleaned = ""
        for ch in text {
            if ch.isNumber {
                cleaned.append(ch)
            } else if ch == separator {
                cleaned.append(".")
            }
            // Everything else (currency symbols, grouping separators, spaces) is dropped.
        }
        guard !cleaned.isEmpty, cleaned != "." else { throw MoneyParseError.malformed }
        if cleaned.hasPrefix(".") { cleaned = "0" + cleaned }
        if cleaned.hasSuffix(".") { cleaned.removeLast() }
        let value = try MoneyParser.milliunits(fromDecimalString: cleaned)
        return negative ? try negChecked(value) : value
    }

    static func isNonZero(_ raw: String) -> Bool {
        (try? milliunits(from: raw)).map { $0 != 0 } ?? false
    }
}

/// Calendar-date parsing for exports. Formats are Unicode patterns; parsing
/// runs in UTC with a fixed POSIX locale so a date never shifts by time zone.
public enum ImportDateParser {
    public static let commonFormats = [
        "yyyy-MM-dd", "MM/dd/yyyy", "M/d/yyyy", "MM/dd/yy", "M/d/yy",
        "dd/MM/yyyy", "d/M/yyyy", "yyyyMMdd", "dd.MM.yyyy", "dd-MM-yyyy", "MMM d, yyyy", "d MMM yyyy", "yyyy/MM/dd"
    ]

    public static func date(from raw: String, format: String) -> BudgetDate? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = format
        formatter.isLenient = false
        guard let parsed = formatter.date(from: trimmed) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let components = calendar.dateComponents([.year, .month, .day], from: parsed)
        guard let y = components.year, let m = components.month, let d = components.day else { return nil }
        return BudgetDate(year: y, month: m, day: d)
    }

    /// The first common format that parses every sample. Ambiguous samples
    /// (all days ≤ 12) resolve to the US order first; the user can override.
    public static func guessFormat(samples: [String]) -> String? {
        let cleaned = samples.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return nil }
        for format in commonFormats where cleaned.allSatisfy({ date(from: $0, format: format) != nil }) {
            return format
        }
        return nil
    }

    /// OFX `DTPOSTED`: `YYYYMMDD[HHMMSS[.XXX]][[gmt offset[:tz name]]]`. The
    /// calendar date portion is used as-is (the server's local date).
    public static func ofxDate(_ raw: String) -> BudgetDate? {
        let digits = raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(8)
        guard digits.count == 8, let y = Int(digits.prefix(4)),
              let m = Int(digits.dropFirst(4).prefix(2)), let d = Int(digits.suffix(2)) else { return nil }
        return BudgetDate(year: y, month: m, day: d)
    }
}

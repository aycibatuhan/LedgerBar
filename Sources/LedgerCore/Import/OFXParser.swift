import Foundation

/// One statement block from an OFX/QFX file.
public struct OFXStatement: Sendable, Equatable {
    public var accountID: String?
    public var bankID: String?
    public var accountType: String?
    public var currency: String?
    public var ledgerBalanceDecimalString: String?
    public var ledgerBalanceDate: BudgetDate?
    public var records: [ParsedImportRecord]

    public init(
        accountID: String? = nil, bankID: String? = nil, accountType: String? = nil, currency: String? = nil,
        ledgerBalanceDecimalString: String? = nil, ledgerBalanceDate: BudgetDate? = nil, records: [ParsedImportRecord]
    ) {
        self.accountID = accountID
        self.bankID = bankID
        self.accountType = accountType
        self.currency = currency
        self.ledgerBalanceDecimalString = ledgerBalanceDecimalString
        self.ledgerBalanceDate = ledgerBalanceDate
        self.records = records
    }
}

/// Tolerant OFX 1.x (SGML, unclosed leaf tags) and OFX 2.x (XML) reader.
/// It does not build a DOM: it tokenizes tags and reads `<STMTTRN>` blocks
/// and a few account/balance leaves. Unknown tags are ignored. QFX is OFX
/// with Intuit extras and parses identically.
public enum OFXParser {
    private enum Token {
        case open(String)
        case close(String)
        case text(String)
    }

    public static func decode(_ data: Data) -> String? {
        CSVParser.decode(data)
    }

    public static func parse(_ text: String) throws -> [OFXStatement] {
        let body: Substring
        if let range = text.range(of: "<OFX>", options: .caseInsensitive) {
            body = text[range.lowerBound...]
        } else {
            throw ImportError.unsupportedFormat
        }
        let tokens = tokenize(String(body))
        var statements: [OFXStatement] = []
        var current: OFXStatement?
        var record: [String: String]?
        var pathStack: [String] = []
        var index = 0
        var lineCounter = 0

        func leafValue(at i: Int) -> (String, Int)? {
            // A leaf is <TAG>text possibly followed by </TAG>.
            guard i + 1 < tokens.count, case .text(let value) = tokens[i + 1] else { return nil }
            var next = i + 2
            if next < tokens.count, case .close(let name) = tokens[next], case .open(let opened) = tokens[i], name == opened {
                next += 1
            }
            return (value, next)
        }

        while index < tokens.count {
            switch tokens[index] {
            case .open(let name):
                switch name {
                case "STMTRS", "CCSTMTRS", "INVSTMTRS":
                    current = OFXStatement(records: [])
                    pathStack.append(name)
                    index += 1
                case "STMTTRN":
                    record = [:]
                    lineCounter += 1
                    pathStack.append(name)
                    index += 1
                default:
                    if let (value, next) = leafValue(at: index) {
                        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        if record != nil {
                            record?[name] = trimmed
                        } else if current != nil {
                            switch name {
                            case "ACCTID": current?.accountID = trimmed
                            case "BANKID": current?.bankID = trimmed
                            case "ACCTTYPE": current?.accountType = trimmed
                            case "CURDEF": current?.currency = trimmed
                            case "BALAMT": if pathStack.last == "LEDGERBAL" { current?.ledgerBalanceDecimalString = trimmed }
                            case "DTASOF": if pathStack.last == "LEDGERBAL" { current?.ledgerBalanceDate = ImportDateParser.ofxDate(trimmed) }
                            default: break
                            }
                        }
                        index = next
                    } else {
                        pathStack.append(name)
                        index += 1
                    }
                }
            case .close(let name):
                switch name {
                case "STMTTRN":
                    if let fields = record {
                        current?.records.append(makeRecord(fields, lineNumber: lineCounter))
                    }
                    record = nil
                case "STMTRS", "CCSTMTRS", "INVSTMTRS":
                    if let statement = current { statements.append(statement) }
                    current = nil
                default:
                    break
                }
                if let last = pathStack.lastIndex(of: name) { pathStack.removeSubrange(last...) }
                index += 1
            case .text:
                index += 1
            }
        }
        if let statement = current { statements.append(statement) } // unterminated SGML
        guard !statements.isEmpty else { throw ImportError.noAccountBlock }
        return statements
    }

    private static func makeRecord(_ fields: [String: String], lineNumber: Int) -> ParsedImportRecord {
        let name = fields["NAME"] ?? fields["PAYEE"] ?? ""
        let memo = fields["MEMO"]
        let description = name.isEmpty ? (memo ?? "") : name
        var raw: [String: String] = [:]
        for (key, value) in fields where raw.count < 24 {
            raw[key] = String(value.prefix(200))
        }
        return ParsedImportRecord(
            lineNumber: lineNumber,
            rawDate: fields["DTPOSTED"] ?? fields["DTUSER"] ?? "",
            rawAmount: fields["TRNAMT"] ?? "",
            description: description,
            memo: name.isEmpty ? nil : memo,
            externalID: fields["FITID"].flatMap { $0.isEmpty ? nil : $0 },
            checkNumber: fields["CHECKNUM"],
            rawFields: raw
        )
    }

    private static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var i = text.startIndex
        var buffer = ""
        while i < text.endIndex {
            let ch = text[i]
            if ch == "<" {
                if !buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    tokens.append(.text(unescape(buffer)))
                }
                buffer = ""
                guard let end = text[i...].firstIndex(of: ">") else { break }
                var name = String(text[text.index(after: i)..<end]).trimmingCharacters(in: .whitespaces)
                if name.hasPrefix("?") || name.hasPrefix("!") {
                    i = text.index(after: end)
                    continue // XML declaration / comments
                }
                if name.hasPrefix("/") {
                    name.removeFirst()
                    tokens.append(.close(name.uppercased()))
                } else {
                    if name.hasSuffix("/") { name.removeLast() }
                    let bare = name.split(separator: " ").first.map(String.init) ?? name
                    tokens.append(.open(bare.uppercased()))
                }
                i = text.index(after: end)
            } else {
                buffer.append(ch)
                i = text.index(after: i)
            }
        }
        if !buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            tokens.append(.text(unescape(buffer)))
        }
        return tokens
    }

    private static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
    }
}

import Foundation

/// Sanitizer for the §4.2 capture command. Produces a fixture that preserves
/// the deployed response *shape* (key presence, string-vs-number types,
/// decimal formatting, error-list key names) while redacting or
/// pseudonymizing everything identifying: IDs, names, descriptions, payees,
/// amounts, balances, domains, URLs, and unknown string values.
public struct SimpleFINCaptureSanitizer {
    private var pseudonyms: [String: String] = [:]
    private var counter = 0

    public init() {}

    /// Stable per-run pseudonym so identity relationships survive.
    public mutating func token(for original: String) -> String {
        if let existing = pseudonyms[original] { return existing }
        counter += 1
        let token = "redacted-\(counter)"
        pseudonyms[original] = token
        return token
    }

    /// Replaces every digit while preserving sign, separators, and length so
    /// the decimal *format* survives without the value ("-123.45" → "-111.11").
    public static func shapePreservingAmount(_ original: String) -> String {
        String(original.map { $0.isNumber ? "1" : $0 })
    }

    /// Keys whose values carry timestamps/booleans that are shape-relevant
    /// and retained as-is.
    private static let retainedValueKeys: Set<String> = [
        "posted", "transacted_at", "balance-date", "pending", "version"
    ]

    public mutating func sanitize(_ value: Any, key: String? = nil) -> Any {
        switch value {
        case let dictionary as [String: Any]:
            if key == "extra" { return [String: Any]() }
            var result: [String: Any] = [:]
            for (childKey, childValue) in dictionary {
                result[childKey] = sanitize(childValue, key: childKey)
            }
            return result
        case let array as [Any]:
            return array.map { sanitize($0, key: key) }
        case let string as String:
            switch key {
            case "id", "conn_id":
                return token(for: string)
            case "amount", "balance", "available-balance":
                return Self.shapePreservingAmount(string)
            case "currency":
                // ISO-4217 codes are harmless shape data. SimpleFIN also
                // permits custom currency identifiers such as URLs, which
                // must not cross the capture redaction boundary.
                return Self.isISO4217Code(string) ? string : "[REDACTED]"
            case _ where Self.retainedValueKeys.contains(key ?? ""):
                return string
            default:
                // Names, descriptions, payees, domains, URLs, error messages,
                // and any unknown string-valued key are redacted, never leaked.
                return "[REDACTED]"
            }
        case let number as NSNumber:
            switch key {
            case "amount", "balance", "available-balance":
                return NSNumber(value: 1)
            case "id", "conn_id":
                return token(for: number.stringValue)
            case _ where Self.retainedValueKeys.contains(key ?? ""):
                return number // posted/transacted_at/balance-date/pending/version
            default:
                // Booleans carry one bit and stay shape-relevant. Every other
                // numeric value under an unrecognized key could be an account
                // number, timestamp, or balance and is sanitized like amounts,
                // preserving numeric type without the value.
                if CFGetTypeID(number) == CFBooleanGetTypeID() {
                    return number
                }
                return NSNumber(value: 1)
            }
        default:
            return value
        }
    }

    private static func isISO4217Code(_ value: String) -> Bool {
        value.utf8.count == 3 && value.utf8.allSatisfy { (65...90).contains($0) }
    }

    /// Sanitizes a raw JSON body into a pretty-printed, key-sorted fixture.
    public static func sanitizedFixture(fromRawJSON raw: Data) throws -> Data {
        let parsed = try JSONSerialization.jsonObject(with: raw)
        var sanitizer = SimpleFINCaptureSanitizer()
        let cleaned = sanitizer.sanitize(parsed)
        return try JSONSerialization.data(withJSONObject: cleaned, options: [.prettyPrinted, .sortedKeys])
    }
}

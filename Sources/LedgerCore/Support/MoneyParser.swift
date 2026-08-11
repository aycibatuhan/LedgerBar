import Foundation

public enum MoneyParseError: Error, Equatable, Sendable {
    /// The input string is not a canonical signed decimal number.
    case malformed
    /// The value is NaN or otherwise not finite.
    case notFinite
    /// The value does not fit a signed 64-bit milliunit amount.
    case outOfRange
}

/// Deterministic decimal → milliunit conversion.
///
/// A decimal amount is parsed as `Decimal`, multiplied by 1000, then rounded to
/// scale 0 using an explicit `NSDecimalNumberHandler` with
/// `roundingMode = .bankers` and `scale = 0`. More than three fractional
/// decimal places are accepted and banker-rounded to the nearest milliunit.
/// Rejected: NaN, infinity, values outside Int64, malformed input, and
/// conversion overflow. `Double` is never used.
public enum MoneyParser {

    private static let posix = Locale(identifier: "en_US_POSIX")

    /// Rounding handler: bankers, scale 0, no ObjC exceptions — overflow and
    /// loss-of-precision yield `NSDecimalNumber.notANumber`, which is rejected.
    private static let handler = NSDecimalNumberHandler(
        roundingMode: .bankers,
        scale: 0,
        raiseOnExactness: false,
        raiseOnOverflow: false,
        raiseOnUnderflow: false,
        raiseOnDivideByZero: false
    )

    private static let thousand = NSDecimalNumber(value: 1000)
    private static let int64Max = NSDecimalNumber(value: Int64.max)
    private static let int64Min = NSDecimalNumber(value: Int64.min)

    /// Parses a canonical decimal string (`-?digits[.digits]`, optional leading
    /// `+`) into milliunits. This is the strict wire/core entry point; UI input
    /// goes through `NumberFormatter` with `generatesDecimalNumbers = true` and
    /// then `milliunits(fromDecimal:)`.
    public static func milliunits(fromDecimalString raw: String) throws -> Milliunits {
        guard isCanonicalDecimalString(raw) else { throw MoneyParseError.malformed }
        guard let decimal = Decimal(string: raw, locale: posix) else {
            throw MoneyParseError.malformed
        }
        return try milliunits(fromDecimal: decimal)
    }

    /// Converts an already-parsed `Decimal` (for example from a
    /// `NumberFormatter` producing `NSDecimalNumber`) into milliunits.
    public static func milliunits(fromDecimal decimal: Decimal) throws -> Milliunits {
        if decimal.isNaN { throw MoneyParseError.notFinite }
        let number = NSDecimalNumber(decimal: decimal)
        if number == NSDecimalNumber.notANumber { throw MoneyParseError.notFinite }

        let scaled = number.multiplying(by: thousand, withBehavior: handler)
        if scaled == NSDecimalNumber.notANumber { throw MoneyParseError.outOfRange }
        // multiplying(by:withBehavior:) already applied scale-0 bankers
        // rounding; round again explicitly so the rounding step does not depend
        // on that implementation detail.
        let rounded = scaled.rounding(accordingToBehavior: handler)
        if rounded == NSDecimalNumber.notANumber { throw MoneyParseError.outOfRange }

        if rounded.compare(int64Max) == .orderedDescending { throw MoneyParseError.outOfRange }
        if rounded.compare(int64Min) == .orderedAscending { throw MoneyParseError.outOfRange }

        let value = rounded.int64Value
        // Defensive exactness check: the integral rounded value must round-trip.
        if NSDecimalNumber(value: value).compare(rounded) != .orderedSame {
            throw MoneyParseError.outOfRange
        }
        return value
    }

    /// Deterministic milliunit → decimal-string formatting (the inverse of
    /// `milliunits(fromDecimalString:)` for exact milliunit values). Used for
    /// stored remote-amount fallbacks; `Double` is never involved.
    public static func decimalString(fromMilliunits milliunits: Milliunits) -> String {
        let decimal = Decimal(milliunits) / Decimal(1000)
        return NSDecimalNumber(decimal: decimal).stringValue
    }

    /// Strict canonical format: optional sign, at least one digit, optional
    /// fraction with at least one digit. No whitespace, grouping, exponents,
    /// or locale separators.
    private static func isCanonicalDecimalString(_ s: String) -> Bool {
        let bytes = Array(s.utf8)
        var i = 0
        if i < bytes.count, bytes[i] == UInt8(ascii: "+") || bytes[i] == UInt8(ascii: "-") {
            i += 1
        }
        var integerDigits = 0
        while i < bytes.count, bytes[i] >= UInt8(ascii: "0"), bytes[i] <= UInt8(ascii: "9") {
            integerDigits += 1
            i += 1
        }
        guard integerDigits > 0 else { return false }
        if i < bytes.count, bytes[i] == UInt8(ascii: ".") {
            i += 1
            var fractionDigits = 0
            while i < bytes.count, bytes[i] >= UInt8(ascii: "0"), bytes[i] <= UInt8(ascii: "9") {
                fractionDigits += 1
                i += 1
            }
            guard fractionDigits > 0 else { return false }
        }
        return i == bytes.count
    }
}

import Foundation
import LedgerCore

/// §5.3: display/input uses `NumberFormatter` with the budget currency and the
/// user locale, `generatesDecimalNumbers = true`, then checked
/// Decimal → milliunit conversion. `Double` is never used for money.
enum MoneyFormatting {
    static func displayFormatter(currency: String) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        formatter.generatesDecimalNumbers = true
        return formatter
    }

    static func editingFormatter() -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.generatesDecimalNumbers = true
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 10
        return formatter
    }

    static func string(_ milliunits: Milliunits, currency: String) -> String {
        let decimal = Decimal(milliunits) / Decimal(1000)
        let formatter = displayFormatter(currency: currency)
        return formatter.string(from: NSDecimalNumber(decimal: decimal)) ?? "\(decimal)"
    }

    /// Plain (non-currency-symbol) editable representation.
    static func editableString(_ milliunits: Milliunits) -> String {
        let decimal = Decimal(milliunits) / Decimal(1000)
        let formatter = editingFormatter()
        return formatter.string(from: NSDecimalNumber(decimal: decimal)) ?? "0"
    }

    /// Locale-aware parse via `NumberFormatter` (generatesDecimalNumbers) then
    /// checked bankers-rounded conversion.
    static func parse(_ text: String) throws -> Milliunits {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw MoneyParseError.malformed }
        let formatter = editingFormatter()
        if let number = formatter.number(from: trimmed) as? NSDecimalNumber {
            return try MoneyParser.milliunits(fromDecimal: number.decimalValue)
        }
        // Fall back to the strict canonical parser (e.g. "1234.5" while the
        // locale expects a comma separator).
        return try MoneyParser.milliunits(fromDecimalString: trimmed)
    }

    static func monthTitle(_ month: BudgetMonth) -> String {
        var components = DateComponents()
        components.year = month.year
        components.month = month.month
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let date = calendar.date(from: components) else { return month.description }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        formatter.timeZone = TimeZone(identifier: "UTC")!
        return formatter.string(from: date)
    }
}

import Foundation
import Testing
@testable import LedgerCore

@Suite("Money parsing — §3.1 signed amounts, bankers rounding, checked conversion")
struct MoneyParserTests {

    @Test("Exact three-decimal amounts")
    func exactAmounts() throws {
        #expect(try MoneyParser.milliunits(fromDecimalString: "0") == 0)
        #expect(try MoneyParser.milliunits(fromDecimalString: "1") == 1000)
        #expect(try MoneyParser.milliunits(fromDecimalString: "123.45") == 123_450)
        #expect(try MoneyParser.milliunits(fromDecimalString: "-123.45") == -123_450)
        #expect(try MoneyParser.milliunits(fromDecimalString: "+2.001") == 2001)
        #expect(try MoneyParser.milliunits(fromDecimalString: "-0.001") == -1)
        #expect(try MoneyParser.milliunits(fromDecimalString: "2.675") == 2675)
    }

    @Test("More than three fractional places banker-round to the nearest milliunit")
    func bankersRounding() throws {
        // 1.2345 * 1000 = 1234.5 → ties-to-even → 1234
        #expect(try MoneyParser.milliunits(fromDecimalString: "1.2345") == 1234)
        // 1.2355 * 1000 = 1235.5 → 1236
        #expect(try MoneyParser.milliunits(fromDecimalString: "1.2355") == 1236)
        // 0.0005 * 1000 = 0.5 → 0
        #expect(try MoneyParser.milliunits(fromDecimalString: "0.0005") == 0)
        // 0.0015 * 1000 = 1.5 → 2
        #expect(try MoneyParser.milliunits(fromDecimalString: "0.0015") == 2)
        // negative ties: -0.5 milli → 0 (even), -1.5 → -2
        #expect(try MoneyParser.milliunits(fromDecimalString: "-0.0005") == 0)
        #expect(try MoneyParser.milliunits(fromDecimalString: "-0.0015") == -2)
        // non-tie rounding
        #expect(try MoneyParser.milliunits(fromDecimalString: "1.23449") == 1234)
        #expect(try MoneyParser.milliunits(fromDecimalString: "1.234501") == 1235)
    }

    @Test("Malformed inputs are rejected")
    func malformed() {
        for bad in ["", " ", "abc", "1.", ".5", "1..2", "1,5", " 1", "1 ", "1e5", "0x10", "NaN", "inf", "-", "+", "--1", "1.2.3"] {
            #expect(throws: MoneyParseError.malformed) {
                try MoneyParser.milliunits(fromDecimalString: bad)
            }
        }
    }

    @Test("NaN Decimal is rejected as not finite")
    func nanDecimal() {
        #expect(throws: MoneyParseError.notFinite) {
            try MoneyParser.milliunits(fromDecimal: Decimal.nan)
        }
    }

    @Test("Int64 bounds are enforced exactly")
    func bounds() throws {
        // Int64.max milliunits == 9223372036854775.807 units.
        #expect(try MoneyParser.milliunits(fromDecimalString: "9223372036854775.807") == Int64.max)
        #expect(throws: MoneyParseError.outOfRange) {
            try MoneyParser.milliunits(fromDecimalString: "9223372036854775.808")
        }
        #expect(try MoneyParser.milliunits(fromDecimalString: "-9223372036854775.808") == Int64.min)
        #expect(throws: MoneyParseError.outOfRange) {
            try MoneyParser.milliunits(fromDecimalString: "-9223372036854775.809")
        }
        #expect(throws: MoneyParseError.outOfRange) {
            try MoneyParser.milliunits(fromDecimalString: "99999999999999999999")
        }
    }

    @Test("Checked replay arithmetic throws instead of wrapping or trapping")
    func checkedArithmetic() {
        #expect(throws: ArithmeticOverflowError.self) { try addChecked(Int64.max, 1) }
        #expect(throws: ArithmeticOverflowError.self) { try subChecked(Int64.min, 1) }
        #expect(throws: ArithmeticOverflowError.self) { try mulChecked(Int64.max, 2) }
        #expect(throws: ArithmeticOverflowError.self) { try negChecked(Int64.min) }
        #expect(throws: ArithmeticOverflowError.self) { try absChecked(Int64.min) }
        #expect(try! addChecked(2, 3) == 5)
        #expect(try! subChecked(2, 3) == -1)
        #expect(try! negChecked(-5) == 5)
    }
}

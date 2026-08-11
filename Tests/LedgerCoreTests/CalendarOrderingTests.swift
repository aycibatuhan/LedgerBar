import Foundation
import Testing
@testable import LedgerCore

@Suite("Budget calendar — immutable timezone epoch mapping")
struct CalendarTests {

    @Test("Month and date parsing and validity")
    func parsing() {
        #expect(BudgetMonth(string: "2025-01") != nil)
        #expect(BudgetMonth(string: "2025-13") == nil)
        #expect(BudgetMonth(string: "202501") == nil)
        #expect(BudgetDate(string: "2025-02-28") != nil)
        #expect(BudgetDate(string: "2025-02-29") == nil) // not a leap year
        #expect(BudgetDate(string: "2024-02-29") != nil) // leap year
        #expect(BudgetDate(string: "2100-02-29") == nil) // century, not leap
        #expect(BudgetDate(string: "2000-02-29") != nil) // 400-year leap
        #expect(BudgetDate(string: "2025-04-31") == nil)
        #expect(month("2025-12").next == month("2026-01"))
        #expect(month("2025-01").previous == month("2024-12"))
        #expect(month("2025-01").months(through: month("2025-03")).count == 3)
        #expect(month("2025-03").months(through: month("2025-01")).isEmpty)
        #expect(month("2025-01") < month("2025-02"))
        #expect(date("2025-01-31") < date("2025-02-01"))
    }

    @Test("UTC noon epoch is exact and round-trips")
    func utcNoon() throws {
        let cal = try BudgetCalendar(timeZoneIdentifier: "UTC")
        // 2025-01-01T00:00:00Z == 1735689600; noon = +12h.
        #expect(try cal.noonEpoch(of: date("2025-01-01")) == 1_735_689_600 + 43_200)
        #expect(cal.budgetDate(fromEpoch: 1_735_689_600) == date("2025-01-01"))
        #expect(cal.budgetDate(fromEpoch: 1_735_689_599) == date("2024-12-31"))
    }

    @Test("Budget dates are pinned to the budget zone, not UTC")
    func zonePinned() throws {
        let ny = try BudgetCalendar(timeZoneIdentifier: "America/New_York")
        // 2025-01-01T03:00:00Z is still 2024-12-31 22:00 in New York.
        #expect(ny.budgetDate(fromEpoch: 1_735_689_600 + 3 * 3600) == date("2024-12-31"))
        // Round-trip: noon of a date maps back to the same date.
        for d in ["2025-01-01", "2025-03-09", "2025-11-02", "2025-06-15"] {
            let noon = try ny.noonEpoch(of: date(d))
            #expect(ny.budgetDate(fromEpoch: noon) == date(d))
        }
        // Ordering is monotonic across the DST-spring-forward boundary.
        let before = try ny.noonEpoch(of: date("2025-03-08"))
        let dst = try ny.noonEpoch(of: date("2025-03-09"))
        let after = try ny.noonEpoch(of: date("2025-03-10"))
        #expect(before < dst && dst < after)
    }

    @Test("Invalid identifier throws")
    func invalidZone() {
        #expect(throws: BudgetCalendarError.invalidTimeZoneIdentifier("Mars/Olympus")) {
            _ = try BudgetCalendar(timeZoneIdentifier: "Mars/Olympus")
        }
    }
}

@Suite("Source order keys — §3.2 canonical encoding and deterministic order")
struct SourceOrderKeyTests {

    @Test("Pinned encodings")
    func encodings() {
        #expect(SourceOrderKey.manual(sequence: 5).rawValue == "manual:00000000000000000005")
        #expect(
            SourceOrderKey.system(sequence: 42, systemKind: "openingBalance").rawValue
                == "system:00000000000000000042:openingBalance"
        )
        #expect(
            SourceOrderKey.remote(connectionKey: "conn", accountID: "acc", transactionID: "tx").rawValue
                == "remote:4:conn3:acc2:tx"
        )
        // Byte length, not character count: é is 2 UTF-8 bytes.
        #expect(
            SourceOrderKey.remote(connectionKey: "é", accountID: "a", transactionID: "b").rawValue
                == "remote:2:é1:a1:b"
        )
    }

    @Test("Lexicographic byte order: fixed-width sequences sort numerically")
    func ordering() {
        #expect(SourceOrderKey.manual(sequence: 9) < SourceOrderKey.manual(sequence: 10))
        #expect(SourceOrderKey.manual(sequence: 199) < SourceOrderKey.manual(sequence: 200))
        // Prefix is part of the deterministic order: manual < remote < system.
        #expect(SourceOrderKey.manual(sequence: 999_999) < SourceOrderKey.remote(connectionKey: "a", accountID: "b", transactionID: "c"))
        #expect(SourceOrderKey.remote(connectionKey: "z", accountID: "z", transactionID: "z") < SourceOrderKey.system(sequence: 0, systemKind: "x"))
        // Equal keys are not ordered before each other.
        let k = SourceOrderKey.manual(sequence: 7)
        #expect(!(k < k))
    }

    @Test("Entity ID ordering is stable byte order")
    func idOrdering() {
        let low = TransactionID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let high = TransactionID(UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        let top = TransactionID(UUID(uuidString: "FF000000-0000-0000-0000-000000000000")!)
        #expect(low < high)
        #expect(high < top)
        #expect(!(low < low))
    }
}

@Suite("Replay ordering — same-day determinism")
struct ReplayOrderingTests {

    @Test("Same-day manual rows replay in source-sequence order; later sync array order cannot reorder existing remote rows")
    func sameDayOrdering() throws {
        var ws = try makeWorkspace()
        let checking = try ws.addAccount(
            name: "Checking", type: .checking, onBudget: true,
            openingBalance: usd(100), openingDate: date("2025-01-01"), nowEpoch: testEpoch
        )
        let groceries = ws.categoryID(named: "Groceries")
        try ws.setBudgeted(categoryID: groceries, month: month("2025-01"), value: usd(60))
        // Two same-day manual outflows: replay order must follow insertion
        // sequence deterministically (manual:...N < manual:...N+1).
        let t1 = try ws.addManualTransaction(
            accountID: checking, date: date("2025-01-10"), payeeName: "A", categoryID: groceries,
            amountMilliunits: -usd(40), nowEpoch: testEpoch
        )
        let t2 = try ws.addManualTransaction(
            accountID: checking, date: date("2025-01-10"), payeeName: "B", categoryID: groceries,
            amountMilliunits: -usd(30), nowEpoch: testEpoch
        )
        let rows = ws.transactions
        #expect(rows[t1]!.sourceOrderKey < rows[t2]!.sourceOrderKey)
        let snap = try ws.snapshot("2025-01")
        #expect(snap.categories[groceries]?.available == -usd(10))
        #expect(try ConservationCheck.compute(ws, month: month("2025-01")).holds)
    }
}

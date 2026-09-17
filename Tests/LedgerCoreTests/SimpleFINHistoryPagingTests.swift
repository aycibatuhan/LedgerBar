import Foundation
import Testing
@testable import LedgerCore

@Suite("SimpleFIN 45-day history paging")
struct SimpleFINHistoryPagingTests {
    private let day: Int64 = 86_400

    private func account(_ id: String = "acct-1", balance: String, balanceDate: Int64, _ rows: [SimpleFINRemoteTransaction]) -> SimpleFINRemoteAccount {
        SimpleFINRemoteAccount(id: id, name: "Remote", currency: "USD", balance: balance,
                               balanceDateEpoch: balanceDate, connectionID: "c1", transactions: rows)
    }

    private func row(_ id: String?, _ amount: String, _ posted: Int64) -> SimpleFINRemoteTransaction {
        SimpleFINRemoteTransaction(id: id, amount: amount, postedEpoch: posted, payee: "P", pending: false)
    }

    @Test("A window within 45 days is one unchanged request")
    func shortWindowIsSingle() throws {
        let start = testEpoch
        let bounded = try SimpleFINHistoryPaging.windows(startEpoch: start, endEpoch: start + 45 * day, nowEpoch: start + 100 * day)
        let single = try SimpleFINRequestWindow(startEpoch: start, endEpoch: start + 45 * day)
        #expect(bounded == [single])
        let open = try SimpleFINHistoryPaging.windows(startEpoch: start, endEpoch: nil, nowEpoch: start + 30 * day)
        let openSingle = try SimpleFINRequestWindow(startEpoch: start, endEpoch: nil)
        #expect(open == [openSingle])
    }

    @Test("A 90-day initial window becomes contiguous pages of at most 45 days ending exactly where requested")
    func ninetyDaysSplits() throws {
        let start = testEpoch
        let end = start + 90 * day + 1
        let pages = try SimpleFINHistoryPaging.windows(startEpoch: start, endEpoch: end, nowEpoch: end)
        #expect(pages.count == 3)
        #expect(pages.first?.startEpoch == start)
        #expect(pages.last?.endEpoch == end)
        for (a, b) in zip(pages, pages.dropFirst()) {
            #expect(a.endEpoch == b.startEpoch, "no gap and no overlap")
        }
        for page in pages {
            #expect((page.endEpoch ?? end) - page.startEpoch <= SimpleFINHistoryPaging.maxWindowSeconds)
        }
    }

    @Test("A long open-ended recurring window keeps only its last page open")
    func openEndedSplits() throws {
        let start = testEpoch
        let now = start + 70 * day
        let pages = try SimpleFINHistoryPaging.windows(startEpoch: start, endEpoch: nil, nowEpoch: now)
        #expect(pages.count == 2)
        #expect(pages[0].endEpoch == start + 45 * day)
        #expect(pages[1].startEpoch == start + 45 * day)
        #expect(pages[1].endEpoch == nil)
    }

    @Test("Merging concatenates rows, keeps the newest balance, and replaces repeated ids in place")
    func mergeCombinesPages() throws {
        let first = try SimpleFINAccountsResponse(accounts: [account(balance: "10.00", balanceDate: testEpoch + day, [
            row("a", "-1.00", testEpoch + day), row("b", "-2.00", testEpoch + 2 * day), row(nil, "-3.00", testEpoch + 3 * day)
        ])])
        let second = try SimpleFINAccountsResponse(accounts: [account(balance: "20.00", balanceDate: testEpoch + 50 * day, [
            row("c", "-4.00", testEpoch + 46 * day), row("b", "-2.50", testEpoch + 47 * day), row(nil, "-5.00", testEpoch + 48 * day)
        ])], balanceDateEpoch: testEpoch + 50 * day)
        let merged = try SimpleFINHistoryPaging.merge([first, second])
        #expect(merged.errors.isEmpty)
        #expect(merged.balanceDateEpoch == testEpoch + 50 * day)
        let block = try #require(merged.accounts.first)
        #expect(merged.accounts.count == 1)
        #expect(block.balance == "20.00")
        #expect(block.balanceDateEpoch == testEpoch + 50 * day)
        #expect(block.transactions.map(\.id) == ["a", "b", nil, "c", nil])
        #expect(block.transactions[1].amount == "-2.50", "the later page's version of a repeated id wins")
    }

    @Test("A provider error on any page survives the merge")
    func mergeKeepsErrors() throws {
        let clean = try SimpleFINAccountsResponse(accounts: [account(balance: "1.00", balanceDate: testEpoch, [])])
        let errored = try SimpleFINAccountsResponse(accounts: [account(balance: "1.00", balanceDate: testEpoch, [])],
                                                    errors: ["Connection to bank failed"])
        let erroredFirst = try SimpleFINHistoryPaging.merge([errored, clean])
        let erroredLast = try SimpleFINHistoryPaging.merge([clean, errored])
        #expect(!erroredFirst.errors.isEmpty)
        #expect(!erroredLast.errors.isEmpty)
    }
}

import Foundation

/// SimpleFIN Bridge answers a transactions request spanning more than 45 days
/// with a provider error ("Requested date range exceeds recommended range of
/// 45 days"), and LedgerBar fails closed on provider errors. Long windows are
/// therefore fetched as consecutive, non-overlapping pages of at most 45 days
/// and merged back into one response before validation or import.
public enum SimpleFINHistoryPaging {
    public static let maxWindowSeconds: Int64 = 45 * 86_400

    /// Splits `[startEpoch, endEpoch)` into consecutive windows no longer than
    /// the limit. `start-date` is inclusive and `end-date` exclusive, so page
    /// boundaries neither overlap nor leave gaps. A nil end means "through
    /// now": only the final page is open-ended, and only when `nowEpoch` is
    /// within the limit of that page's start.
    public static func windows(
        startEpoch: Int64,
        endEpoch: Int64?,
        nowEpoch: Int64,
        maxWindowSeconds: Int64 = maxWindowSeconds
    ) throws -> [SimpleFINRequestWindow] {
        precondition(maxWindowSeconds > 0)
        let finalEnd = endEpoch ?? nowEpoch
        var pages: [SimpleFINRequestWindow] = []
        var pageStart = startEpoch
        while true {
            let step = pageStart.addingReportingOverflow(maxWindowSeconds)
            let pageLimit = step.overflow ? Int64.max : step.partialValue
            if finalEnd <= pageLimit {
                // Last page keeps the caller's end exactly (nil stays open).
                pages.append(try SimpleFINRequestWindow(startEpoch: pageStart, endEpoch: endEpoch))
                return pages
            }
            pages.append(try SimpleFINRequestWindow(startEpoch: pageStart, endEpoch: pageLimit))
            pageStart = pageLimit
        }
    }

    /// Merges page responses in request order. Account blocks are keyed by
    /// their stable identity; the latest page's balance fields win because it
    /// is the freshest observation. Transactions are concatenated, and a
    /// transaction id repeated across pages keeps its latest version at the
    /// position it first appeared. Rows without an id are all kept so the
    /// usual validation still rejects them. Provider errors from any page are
    /// preserved, so an errored page can never be merged into a clean result.
    public static func merge(_ pages: [SimpleFINAccountsResponse]) throws -> SimpleFINAccountsResponse {
        guard let last = pages.last else {
            throw SimpleFINProtocolError.invalidResponse("no history pages")
        }
        if pages.count == 1 { return last }
        var order: [String] = []
        var blocks: [String: SimpleFINRemoteAccount] = [:]
        var errors: [String] = []
        for page in pages {
            errors.append(contentsOf: page.errors)
            for account in page.accounts {
                let key = SimpleFINAccountLink.identity(
                    connectionKey: try account.remoteConnectionKey(),
                    remoteAccountID: account.remoteAccountIdentity
                )
                guard var merged = blocks[key] else {
                    order.append(key)
                    blocks[key] = account
                    continue
                }
                var transactions = merged.transactions
                for row in account.transactions {
                    if let id = row.id, let index = transactions.firstIndex(where: { $0.id == id }) {
                        transactions[index] = row
                    } else {
                        transactions.append(row)
                    }
                }
                merged = account
                merged.transactions = transactions
                blocks[key] = merged
            }
        }
        return try SimpleFINAccountsResponse(
            accounts: order.compactMap { blocks[$0] },
            errors: errors,
            balanceDateEpoch: last.balanceDateEpoch
        )
    }
}

import Foundation

/// Durable request history required by §2.1. This record contains only request
/// shape and outcome metadata; credentials, URLs, and provider payloads never
/// enter the log.
public struct SyncRequestLog: Sendable, Equatable {
    public enum Status: String, Sendable, Equatable {
        case started
        case succeeded
        case failed
    }

    public var id: SyncRequestLogID
    public var budgetID: BudgetID
    public var connectionID: String
    public var accountID: AccountID?
    public var requestedStartEpoch: Int64?
    public var requestedEndEpoch: Int64?
    public var startedAtEpoch: Int64
    public var completedAtEpoch: Int64?
    public var status: Status
    public var httpStatus: Int?
    public var retryAfterSeconds: Int64?

    public init(
        id: SyncRequestLogID = SyncRequestLogID(),
        budgetID: BudgetID,
        connectionID: String,
        accountID: AccountID? = nil,
        requestedStartEpoch: Int64? = nil,
        requestedEndEpoch: Int64? = nil,
        startedAtEpoch: Int64,
        completedAtEpoch: Int64? = nil,
        status: Status = .started,
        httpStatus: Int? = nil,
        retryAfterSeconds: Int64? = nil
    ) {
        self.id = id
        self.budgetID = budgetID
        self.connectionID = connectionID
        self.accountID = accountID
        self.requestedStartEpoch = requestedStartEpoch
        self.requestedEndEpoch = requestedEndEpoch
        self.startedAtEpoch = startedAtEpoch
        self.completedAtEpoch = completedAtEpoch
        self.status = status
        self.httpStatus = httpStatus
        self.retryAfterSeconds = retryAfterSeconds
    }
}
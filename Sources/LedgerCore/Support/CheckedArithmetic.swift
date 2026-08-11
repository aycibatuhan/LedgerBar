import Foundation

/// All stored money is a signed 64-bit integer in milliunits (1/1000 currency unit).
public typealias Milliunits = Int64

/// Errors thrown by checked replay arithmetic. An overflow aborts the current
/// mutation and rolls back its database transaction; it never wraps and never
/// traps the process in production code paths.
public struct ArithmeticOverflowError: Error, Equatable, Sendable {
    public let operation: String
    public init(operation: String) { self.operation = operation }
}

@inlinable
public func addChecked(_ a: Int64, _ b: Int64) throws -> Int64 {
    let (result, overflow) = a.addingReportingOverflow(b)
    if overflow { throw ArithmeticOverflowError(operation: "add") }
    return result
}

@inlinable
public func subChecked(_ a: Int64, _ b: Int64) throws -> Int64 {
    let (result, overflow) = a.subtractingReportingOverflow(b)
    if overflow { throw ArithmeticOverflowError(operation: "sub") }
    return result
}

@inlinable
public func mulChecked(_ a: Int64, _ b: Int64) throws -> Int64 {
    let (result, overflow) = a.multipliedReportingOverflow(by: b)
    if overflow { throw ArithmeticOverflowError(operation: "mul") }
    return result
}

@inlinable
public func negChecked(_ a: Int64) throws -> Int64 {
    if a == Int64.min { throw ArithmeticOverflowError(operation: "neg") }
    return -a
}

/// Checked absolute value.
@inlinable
public func absChecked(_ a: Int64) throws -> Int64 {
    if a == Int64.min { throw ArithmeticOverflowError(operation: "abs") }
    return a < 0 ? -a : a
}

import Foundation
import Testing
@testable import LedgerCore

@Suite("Checked workspace counters")
struct CounterOverflowTests {
    private func budget(
        revision: Int64 = 0,
        nextLocalSourceSequence: Int64 = 0
    ) -> BudgetRow {
        BudgetRow(
            name: "Overflow test",
            currency: "USD",
            timeZoneIdentifier: "UTC",
            firstMonth: BudgetMonth(year: 2025, month: 1)!,
            lastObservedBudgetMonth: BudgetMonth(year: 2025, month: 1)!,
            nextLocalSourceSequence: nextLocalSourceSequence,
            createdAtEpoch: 0,
            revision: revision
        )
    }

    @Test("revision overflow rejects without committing the group")
    func revisionOverflow() throws {
        var workspace = try BudgetWorkspace(budget: budget(revision: Int64.max))
        let before = workspace

        #expect(throws: ArithmeticOverflowError.self) {
            _ = try workspace.addCategoryGroup(name: "Overflow")
        }
        #expect(workspace == before)
    }

    @Test("source-sequence overflow rejects without committing the account")
    func sourceSequenceOverflow() throws {
        var workspace = try BudgetWorkspace(
            budget: budget(nextLocalSourceSequence: Int64.max)
        )
        let before = workspace

        #expect(throws: ArithmeticOverflowError.self) {
            _ = try workspace.addAccount(
                name: "Checking",
                type: .checking,
                onBudget: true,
                currency: "USD",
                openingBalance: 100,
                openingDate: BudgetDate(year: 2025, month: 1, day: 1)!,
                nowEpoch: 0
            )
        }
        #expect(workspace == before)
    }
}

import Testing
@testable import LedgerCore

/// Deliberately independent, test-only model for the supported cash-account
/// current-month slice. It does not call BudgetWorkspace projection helpers;
/// it models the reference equations directly so the differential gate can
/// catch a shared implementation mistake.
@Suite("Independent ReferenceModel differential gate")
struct ReferenceModelDifferentialTests {
    private struct SplitMix64 {
        private var state: UInt64

        init(seed: UInt64) {
            state = seed
        }

        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }

        mutating func integer(in range: ClosedRange<Int>) -> Int {
            let width = UInt64(range.upperBound - range.lowerBound + 1)
            return range.lowerBound + Int(next() % width)
        }
    }

    private struct ReferenceModel: Equatable {
        var registerBalance: Milliunits
        var rtaActivity: Milliunits
        var rtaEnd: Milliunits
        var budgeted: Milliunits = 0
        var categoryActivity: Milliunits = 0

        init(openingBalance: Milliunits) {
            registerBalance = openingBalance
            rtaActivity = openingBalance
            rtaEnd = openingBalance
        }

        mutating func setBudgeted(_ value: Milliunits) throws {
            guard value >= 0 else { throw MutationError.negativeSetBudgeted }
            let delta = value.subtractingReportingOverflow(budgeted)
            guard !delta.overflow else { throw MutationError.arithmeticOverflow }
            let nextRTA = rtaEnd.subtractingReportingOverflow(delta.partialValue)
            guard !nextRTA.overflow else { throw MutationError.arithmeticOverflow }
            budgeted = value
            rtaEnd = nextRTA.partialValue
        }

        mutating func addCashOutflow(_ magnitude: Milliunits) throws {
            guard magnitude > 0 else { throw MutationError.moveMoneyAmountNotPositive }
            let nextRegister = registerBalance.subtractingReportingOverflow(magnitude)
            let nextActivity = categoryActivity.subtractingReportingOverflow(magnitude)
            guard !nextRegister.overflow, !nextActivity.overflow else {
                throw MutationError.arithmeticOverflow
            }
            registerBalance = nextRegister.partialValue
            categoryActivity = nextActivity.partialValue
        }

        var categoryAvailable: Milliunits {
            budgeted + categoryActivity
        }

        var cashOverspendingAtEnd: Milliunits {
            max(0, -categoryAvailable)
        }
    }

    @Test("fixed-seed assignments and cash outflows match the independent model")
    func fixedSeedCashSliceDifferential() throws {
        var workspace = try makeWorkspace()
        let checkingID = try workspace.addAccount(
            name: "Checking",
            type: .checking,
            onBudget: true,
            openingBalance: usd(1_000),
            openingDate: date("2025-01-02"),
            nowEpoch: testEpoch
        )
        let diningID = workspace.categoryID(named: "Dining")
        var reference = ReferenceModel(openingBalance: usd(1_000))
        var random = SplitMix64(seed: 0xC0FFEE_2025)

        func assertProjection(
            _ workspace: BudgetWorkspace,
            _ reference: ReferenceModel
        ) throws {
            let projection = try workspace.projection()
            let monthSnapshot = try #require(projection.month(month("2025-01")))
            let category = try #require(monthSnapshot.categories[diningID])

            #expect(monthSnapshot.rtaActivity == reference.rtaActivity)
            #expect(monthSnapshot.rtaEnd == reference.rtaEnd)
            #expect(monthSnapshot.totalAssigned == reference.budgeted)
            #expect(category.budgeted == reference.budgeted)
            #expect(category.activity == reference.categoryActivity)
            #expect(category.available == reference.categoryAvailable)
            #expect(category.cashDebt == reference.cashOverspendingAtEnd)
            #expect(monthSnapshot.cashOverspendingAtEnd == reference.cashOverspendingAtEnd)
            #expect(projection.registerBalances[checkingID] == reference.registerBalance)
            #expect(try ConservationCheck.compute(workspace, month: month("2025-01")).holds)
        }

        try assertProjection(workspace, reference)

        for step in 0..<128 {
            if step % 17 == 0 {
                let beforeWorkspace = workspace
                let beforeReference = reference
                do {
                    try workspace.setBudgeted(
                        categoryID: diningID,
                        month: month("2025-01"),
                        value: -1
                    )
                    Issue.record("negative allocation was accepted")
                } catch let error as MutationError {
                    #expect(error == .negativeSetBudgeted)
                }
                do {
                    try reference.setBudgeted(-1)
                    Issue.record("reference model accepted negative allocation")
                } catch let error as MutationError {
                    #expect(error == .negativeSetBudgeted)
                }
                #expect(workspace == beforeWorkspace)
                #expect(reference == beforeReference)
            } else if random.next() % 2 == 0 {
                let target = Milliunits(random.integer(in: 0...600) * 1000)
                try workspace.setBudgeted(
                    categoryID: diningID,
                    month: month("2025-01"),
                    value: target
                )
                try reference.setBudgeted(target)
            } else {
                let magnitude = Milliunits(random.integer(in: 1...80) * 1000)
                try workspace.addManualTransaction(
                    accountID: checkingID,
                    date: date("2025-01-15"),
                    payeeName: "ReferenceModel Vendor \(step)",
                    categoryID: diningID,
                    amountMilliunits: -magnitude,
                    nowEpoch: testEpoch
                )
                try reference.addCashOutflow(magnitude)
            }
            try assertProjection(workspace, reference)
        }
    }
}

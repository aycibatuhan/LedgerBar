import Foundation
import Testing
@testable import LedgerCore

/// Category management mutations (§2.1): add, rename, hide-as-archive, and
/// unhide, with the shared trimmed/non-empty/visible-unique name validation.
@Suite("Category management")
struct CategoryManagementTests {

    private func groupID(named name: String, in workspace: BudgetWorkspace) -> CategoryGroupID {
        workspace.categoryGroups.values.first { $0.name == name }!.id
    }

    // MARK: - Add group

    @Test("addCategoryGroup trims the name and appends at the end of the sort order")
    func addGroupTrimsAndAppends() throws {
        var workspace = try makeWorkspace()
        let maxSort = workspace.categoryGroups.values.map(\.sortOrder).max()!
        let id = try workspace.addCategoryGroup(name: "  Goals \n")
        let group = try #require(workspace.categoryGroups[id])
        #expect(group.name == "Goals")
        #expect(group.sortOrder == maxSort + 1)
        #expect(!group.hidden)
    }

    @Test("addCategoryGroup rejects empty and whitespace-only names")
    func addGroupRejectsEmptyNames() throws {
        var workspace = try makeWorkspace()
        let before = workspace.snapshot()
        #expect(throws: MutationError.nameEmpty) { try workspace.addCategoryGroup(name: "") }
        #expect(throws: MutationError.nameEmpty) { try workspace.addCategoryGroup(name: "   \n\t") }
        #expect(workspace.snapshot() == before)
    }

    @Test("addCategoryGroup rejects a case-insensitive duplicate of a visible group")
    func addGroupRejectsDuplicateNames() throws {
        var workspace = try makeWorkspace()
        #expect(throws: MutationError.duplicateName) {
            try workspace.addCategoryGroup(name: "savings")
        }
        #expect(throws: MutationError.duplicateName) {
            try workspace.addCategoryGroup(name: "  Fixed Expenses ")
        }
    }

    // MARK: - Add category

    @Test("addCategory trims the name and creates a spending category in the group")
    func addCategoryTrims() throws {
        var workspace = try makeWorkspace()
        let everyday = groupID(named: "Everyday Spending", in: workspace)
        let id = try workspace.addCategory(groupID: everyday, name: "  Coffee ")
        let category = try #require(workspace.categories[id])
        #expect(category.name == "Coffee")
        #expect(category.groupID == everyday)
        #expect(category.kind == .spending)
        #expect(category.systemKind == nil)
        #expect(!category.hidden)
    }

    @Test("addCategory rejects empty names and unknown groups")
    func addCategoryRejectsEmptyAndUnknown() throws {
        var workspace = try makeWorkspace()
        let everyday = groupID(named: "Everyday Spending", in: workspace)
        #expect(throws: MutationError.nameEmpty) {
            try workspace.addCategory(groupID: everyday, name: " \t ")
        }
        #expect(throws: MutationError.entityNotFound) {
            try workspace.addCategory(groupID: CategoryGroupID(), name: "Coffee")
        }
    }

    @Test("addCategory rejects a case-insensitive duplicate within the same group but allows it in another group")
    func addCategoryDuplicateScope() throws {
        var workspace = try makeWorkspace()
        let everyday = groupID(named: "Everyday Spending", in: workspace)
        let savings = groupID(named: "Savings", in: workspace)
        #expect(throws: MutationError.duplicateName) {
            try workspace.addCategory(groupID: everyday, name: "groceries")
        }
        // Same name in a different group is a distinct envelope.
        _ = try workspace.addCategory(groupID: savings, name: "Groceries")
    }

    @Test("addCategory still rejects the Credit Card Payments group")
    func addCategoryRejectsPaymentsGroup() throws {
        var workspace = try makeWorkspace()
        _ = try workspace.addAccount(
            name: "Card", type: .creditCard, onBudget: true,
            openingBalance: 0, openingDate: date("2025-01-01"), nowEpoch: testEpoch
        )
        let payments = try #require(workspace.creditCardPaymentsGroupID)
        #expect(throws: MutationError.categoryNotAllowed) {
            try workspace.addCategory(groupID: payments, name: "Extra")
        }
    }

    // MARK: - Hide / unhide

    @Test("hideCategory archives the row and keeps its name reusable")
    func hideKeepsNameReusable() throws {
        var workspace = try makeWorkspace()
        let everyday = groupID(named: "Everyday Spending", in: workspace)
        let groceries = workspace.categoryID(named: "Groceries")
        try workspace.hideCategory(groceries)
        #expect(workspace.categories[groceries]?.hidden == true)
        // The archived name is free for a new envelope, case-insensitively.
        let replacement = try workspace.addCategory(groupID: everyday, name: "groceries")
        #expect(workspace.categories[replacement]?.hidden == false)
    }

    @Test("hideCategory rejects system categories and positive available")
    func hideGuards() throws {
        var workspace = try makeWorkspace()
        #expect(throws: MutationError.systemEntityImmutable) {
            try workspace.hideCategory(workspace.uncategorizedID)
        }
        _ = try workspace.addAccount(
            name: "Checking", type: .checking, onBudget: true,
            openingBalance: usd(100), openingDate: date("2025-01-01"), nowEpoch: testEpoch
        )
        let groceries = workspace.categoryID(named: "Groceries")
        try workspace.setBudgeted(categoryID: groceries, month: month("2025-01"), value: usd(50))
        #expect(throws: MutationError.categoryHasAvailable) {
            try workspace.hideCategory(groceries)
        }
        // Emptying the envelope back to RTA unblocks the hide.
        try workspace.moveMoney(
            source: .category(groceries), destination: .rta,
            amount: usd(50), month: month("2025-01"), nowEpoch: testEpoch
        )
        try workspace.hideCategory(groceries)
        #expect(workspace.categories[groceries]?.hidden == true)
    }

    @Test("unhideCategory restores a hidden row and is a no-op on a visible one")
    func unhideRestores() throws {
        var workspace = try makeWorkspace()
        let groceries = workspace.categoryID(named: "Groceries")
        try workspace.hideCategory(groceries)
        try workspace.unhideCategory(groceries)
        #expect(workspace.categories[groceries]?.hidden == false)
        // Visible already: nothing to do, no error.
        try workspace.unhideCategory(groceries)
        #expect(workspace.categories[groceries]?.hidden == false)
    }

    @Test("unhideCategory is refused while a visible sibling holds the name")
    func unhideBlockedByNameReuse() throws {
        var workspace = try makeWorkspace()
        let everyday = groupID(named: "Everyday Spending", in: workspace)
        let groceries = workspace.categoryID(named: "Groceries")
        try workspace.hideCategory(groceries)
        _ = try workspace.addCategory(groupID: everyday, name: "GROCERIES")
        #expect(throws: MutationError.duplicateName) {
            try workspace.unhideCategory(groceries)
        }
    }

    // MARK: - Rename category

    @Test("renameCategory trims the new name and keeps allocations attached")
    func renameCategoryTrims() throws {
        var workspace = try makeWorkspace()
        _ = try workspace.addAccount(
            name: "Checking", type: .checking, onBudget: true,
            openingBalance: usd(100), openingDate: date("2025-01-01"), nowEpoch: testEpoch
        )
        let groceries = workspace.categoryID(named: "Groceries")
        try workspace.setBudgeted(categoryID: groceries, month: month("2025-01"), value: usd(40))
        try workspace.renameCategory(groceries, to: "  Food \n")
        #expect(workspace.categories[groceries]?.name == "Food")
        #expect(try workspace.available("Food", in: "2025-01") == usd(40))
    }

    @Test("renameCategory validates emptiness and visible-sibling uniqueness")
    func renameCategoryValidation() throws {
        var workspace = try makeWorkspace()
        let groceries = workspace.categoryID(named: "Groceries")
        #expect(throws: MutationError.nameEmpty) {
            try workspace.renameCategory(groceries, to: "  ")
        }
        #expect(throws: MutationError.duplicateName) {
            try workspace.renameCategory(groceries, to: "dining")
        }
        // Renaming to its own name (any casing) is not a self-collision.
        try workspace.renameCategory(groceries, to: "GROCERIES")
        #expect(workspace.categories[groceries]?.name == "GROCERIES")
        #expect(throws: MutationError.entityNotFound) {
            try workspace.renameCategory(CategoryID(), to: "Anything")
        }
    }

    @Test("renameCategory rejects system and card payment categories")
    func renameCategoryImmutableRows() throws {
        var workspace = try makeWorkspace()
        #expect(throws: MutationError.systemEntityImmutable) {
            try workspace.renameCategory(workspace.uncategorizedID, to: "Misc")
        }
        _ = try workspace.addAccount(
            name: "Card", type: .creditCard, onBudget: true,
            openingBalance: 0, openingDate: date("2025-01-01"), nowEpoch: testEpoch
        )
        let payment = workspace.paymentCategoryIDForOnlyCard()
        #expect(throws: MutationError.systemEntityImmutable) {
            try workspace.renameCategory(payment, to: "My Card")
        }
    }

    // MARK: - Rename group

    @Test("renameCategoryGroup trims, validates uniqueness, and rejects the payments group")
    func renameGroupValidation() throws {
        var workspace = try makeWorkspace()
        let savings = groupID(named: "Savings", in: workspace)
        try workspace.renameCategoryGroup(savings, to: "  Long-Term ")
        #expect(workspace.categoryGroups[savings]?.name == "Long-Term")
        #expect(throws: MutationError.nameEmpty) {
            try workspace.renameCategoryGroup(savings, to: "")
        }
        #expect(throws: MutationError.duplicateName) {
            try workspace.renameCategoryGroup(savings, to: "everyday spending")
        }
        #expect(throws: MutationError.entityNotFound) {
            try workspace.renameCategoryGroup(CategoryGroupID(), to: "Anything")
        }

        _ = try workspace.addAccount(
            name: "Card", type: .creditCard, onBudget: true,
            openingBalance: 0, openingDate: date("2025-01-01"), nowEpoch: testEpoch
        )
        let payments = try #require(workspace.creditCardPaymentsGroupID)
        #expect(throws: MutationError.systemEntityImmutable) {
            try workspace.renameCategoryGroup(payments, to: "Cards")
        }
    }

    // MARK: - Service persistence

    @Test("category management mutations persist through the mutation service")
    func serviceRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledgerbar-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("LedgerBar.sqlite")
        let store = try LedgerWorkspaceStore(databaseURL: url)
        let service = BudgetMutationService(store: store)
        let created = try await service.createBudget(
            name: "Test Budget", currency: "USD",
            timeZoneIdentifier: "America/New_York",
            firstMonth: month("2025-01"), currentMonth: month("2025-01"),
            nowEpoch: testEpoch
        )

        let ids = try await service.transact(nowEpoch: testEpoch) { workspace in
            let goals = try workspace.addCategoryGroup(name: "Goals")
            let vacation = try workspace.addCategory(groupID: goals, name: "Vacation")
            try workspace.renameCategory(vacation, to: "Trip Fund")
            try workspace.hideCategory(workspace.categoryID(named: "Dining"))
            return (goals, vacation)
        }

        let snapshot = try #require(await service.currentSnapshot())
        #expect(snapshot.budget.revision > created.budget.revision)
        #expect(snapshot.categoryGroups.contains { $0.id == ids.0 && $0.name == "Goals" })
        #expect(snapshot.categories.contains { $0.id == ids.1 && $0.name == "Trip Fund" })
        #expect(snapshot.categories.first { $0.name == "Dining" }?.hidden == true)

        // A failed mutation leaves the persisted state untouched.
        await #expect(throws: MutationError.duplicateName) {
            try await service.transact(nowEpoch: testEpoch) { workspace in
                try workspace.addCategoryGroup(name: "goals")
            }
        }

        let reloaded = try LedgerWorkspaceStore(databaseURL: url)
            .load(budgetID: created.budget.id)
        #expect(reloaded.snapshot() == snapshot)
    }
}

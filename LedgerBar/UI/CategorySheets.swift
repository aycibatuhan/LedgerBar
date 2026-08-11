import LedgerCore
import SwiftUI

/// Rename target for the shared rename sheet: a user category or a user
/// category group.
enum CategoryRenameTarget: Identifiable, Sendable {
    case category(CategoryRow)
    case group(CategoryGroupRow)

    var id: String {
        switch self {
        case .category(let row): return "category-\(row.id.description)"
        case .group(let row): return "group-\(row.id.description)"
        }
    }

    var title: String {
        switch self {
        case .category: return "Rename Category"
        case .group: return "Rename Group"
        }
    }

    var currentName: String {
        switch self {
        case .category(let row): return row.name
        case .group(let row): return row.name
        }
    }
}

/// Creates a spending category in a chosen group. User-created categories
/// are spending-only in v1; the engine enforces name validation and rejects
/// the system-managed Credit Card Payments group.
struct AddCategorySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var groupID: CategoryGroupID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Category").font(.title3.bold())
            Form {
                TextField("Name", text: $name)
                Picker("Group", selection: $groupID) {
                    ForEach(eligibleGroups, id: \.id) { group in
                        Text(group.name).tag(group.id as CategoryGroupID?)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || groupID == nil)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { if groupID == nil { groupID = eligibleGroups.first?.id } }
    }

    /// The Credit Card Payments group is system-managed and rejected by the
    /// engine; hidden groups are not offered.
    private var eligibleGroups: [CategoryGroupRow] {
        (model.snapshot?.categoryGroups ?? [])
            .filter { !$0.hidden && $0.id != model.snapshot?.creditCardPaymentsGroupID }
            .sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) }
    }

    private func create() {
        guard let groupID else { return }
        let categoryName = name
        Task {
            let created: CategoryID? = await model.perform { workspace in
                try workspace.addCategory(groupID: groupID, name: categoryName)
            }
            if created != nil { dismiss() }
        }
    }
}

/// Creates an empty category group at the end of the grid.
struct AddCategoryGroupSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Group").font(.title3.bold())
            Form {
                TextField("Name", text: $name)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func create() {
        let groupName = name
        Task {
            let created: CategoryGroupID? = await model.perform { workspace in
                try workspace.addCategoryGroup(name: groupName)
            }
            if created != nil { dismiss() }
        }
    }
}

/// Renames a user category or group. System rows, payment categories, and
/// the Credit Card Payments group are rejected by the engine.
struct RenameCategorySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let target: CategoryRenameTarget

    @State private var name: String

    init(target: CategoryRenameTarget) {
        self.target = target
        _name = State(initialValue: target.currentName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(target.title).font(.title3.bold())
            Form {
                TextField("Name", text: $name)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Rename") { rename() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func rename() {
        let newName = name
        let target = target
        Task {
            let renamed: Bool? = await model.perform { workspace in
                switch target {
                case .category(let row):
                    try workspace.renameCategory(row.id, to: newName)
                case .group(let row):
                    try workspace.renameCategoryGroup(row.id, to: newName)
                }
                return true
            }
            if renamed != nil { dismiss() }
        }
    }
}

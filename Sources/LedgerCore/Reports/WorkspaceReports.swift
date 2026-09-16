import Foundation

extension BudgetWorkspace {

    // MARK: - Saved reports (D7.1)

    @discardableResult
    public mutating func saveReport(name: String, definition: ReportDefinition, nowEpoch: Int64) throws -> ReportID {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MutationError.nameEmpty }
        guard !reports.values.contains(where: { $0.name.compare(trimmed, options: .caseInsensitive) == .orderedSame }) else {
            throw MutationError.duplicateName
        }
        let row = ReportRow(
            budgetID: budget.id, name: trimmed, definition: definition,
            sortOrder: (reports.values.map(\.sortOrder).max() ?? -1) + 1,
            createdAtEpoch: nowEpoch, updatedAtEpoch: nowEpoch
        )
        var copy = self
        copy.setReport(row)
        try copy.bumpRevision()
        self = copy
        return row.id
    }

    public mutating func updateReportDefinition(_ id: ReportID, definition: ReportDefinition, nowEpoch: Int64) throws {
        guard var row = reports[id] else { throw MutationError.entityNotFound }
        guard row.definition != definition else { return }
        row.definition = definition
        row.updatedAtEpoch = nowEpoch
        var copy = self
        copy.setReport(row)
        try copy.bumpRevision()
        self = copy
    }

    public mutating func renameReport(_ id: ReportID, to name: String, nowEpoch: Int64) throws {
        guard var row = reports[id] else { throw MutationError.entityNotFound }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MutationError.nameEmpty }
        guard !reports.values.contains(where: { $0.id != id && $0.name.compare(trimmed, options: .caseInsensitive) == .orderedSame }) else {
            throw MutationError.duplicateName
        }
        guard row.name != trimmed else { return }
        row.name = trimmed
        row.updatedAtEpoch = nowEpoch
        var copy = self
        copy.setReport(row)
        try copy.bumpRevision()
        self = copy
    }

    @discardableResult
    public mutating func duplicateReport(_ id: ReportID, nowEpoch: Int64) throws -> ReportID {
        guard let row = reports[id] else { throw MutationError.entityNotFound }
        var name = row.name + " copy"
        var suffix = 2
        while reports.values.contains(where: { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }) {
            name = "\(row.name) copy \(suffix)"
            suffix += 1
        }
        return try saveReport(name: name, definition: row.definition, nowEpoch: nowEpoch)
    }

    public mutating func deleteReport(_ id: ReportID) throws {
        guard reports[id] != nil else { throw MutationError.entityNotFound }
        var copy = self
        copy.removeReport(id)
        try copy.bumpRevision()
        self = copy
    }
}

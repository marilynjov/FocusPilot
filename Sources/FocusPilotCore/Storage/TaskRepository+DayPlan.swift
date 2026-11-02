import Foundation
import GRDB

public enum DayPlanError: Error, Equatable {
    case blockNotFound
    /// Fixed blocks such as lunch change in Settings, not on the timeline.
    case fixedBlock
    case invalid(DayPlanProblem)
}

/// What a block edit did.
public enum DayPlanEdit: Equatable, Sendable {
    case saved(DayPlan)
    /// Nothing was saved: the block lands on these fixed blocks, and the
    /// owner has to confirm before it is placed there.
    case needsConfirmation([DayBlock])
}

/// Day plans and the preferences they start from (decision 0004). Plans are
/// owner data: clearing caches never touches them. Each edit is read,
/// checked against `DayPlanRules` and written in one write, and any edit
/// makes an approved plan a draft again.
extension TaskRepository {
    public func dayPreferences() async throws -> DayPreferences {
        try await ownerDatabase.read { db in try Self.dayPreferences(db) }
    }

    /// Saves preferences that pass `DayPreferences.problem`, or throws
    /// `invalid`. Plans already created keep what they started with.
    public func saveDayPreferences(_ preferences: DayPreferences) async throws {
        if let problem = preferences.problem { throw DayPlanError.invalid(problem) }
        try await ownerDatabase.write { db in try DayPreferencesRow(preferences).save(db) }
    }

    /// The plan for `date`, created as a draft from the current preferences
    /// the first time it is asked for.
    public func dayPlan(for date: LocalDate) async throws -> DayPlan {
        let createdAt = now()
        return try await ownerDatabase.write { db in try Self.dayPlan(date, creatingAt: createdAt, db) }
    }

    /// Adds a block to the plan for `date`, creating the plan if needed.
    /// One that lands on a fixed block is saved only when `confirmed`.
    public func addBlock(_ block: DayBlock, to date: LocalDate, confirmed: Bool = false) async throws -> DayPlanEdit {
        var block = block
        block.id = nil
        block.isFixed = false
        return try await editBlock(block, in: date, confirmed: confirmed)
    }

    /// Moves or resizes a block, or changes its kind or task. Fixed blocks
    /// are refused.
    public func updateBlock(_ block: DayBlock, in date: LocalDate, confirmed: Bool = false) async throws -> DayPlanEdit {
        guard block.id != nil else { throw DayPlanError.blockNotFound }
        return try await editBlock(block, in: date, confirmed: confirmed)
    }

    public func deleteBlock(_ id: Int64, from date: LocalDate) async throws -> DayPlan {
        try await ownerDatabase.write { db in
            let stored = try Self.storedBlock(id, in: date, db)
            guard !stored.isFixed else { throw DayPlanError.fixedBlock }
            _ = try DayBlockRow.deleteOne(db, key: id)
            try Self.markDraft(date, db)
            return try Self.dayPlan(date, db)!
        }
    }

    /// Marks the plan approved, unless `DayPlanRules` finds a problem in it.
    /// Approving does not start anything yet; following a plan is D3.
    public func approveDayPlan(for date: LocalDate) async throws -> DayPlan {
        let approvedAt = now()
        return try await ownerDatabase.write { db in
            let plan = try Self.dayPlan(date, creatingAt: approvedAt, db)
            if let problem = DayPlanRules.problems(in: plan).first { throw DayPlanError.invalid(problem) }
            try db.execute(sql: "UPDATE dayPlan SET state = 'approved', approvedAt = ? WHERE date = ? AND state = 'draft'",
                           arguments: [approvedAt, date.isoString])
            return try Self.dayPlan(date, db)!
        }
    }

    private func editBlock(_ block: DayBlock, in date: LocalDate, confirmed: Bool) async throws -> DayPlanEdit {
        let createdAt = now()
        return try await ownerDatabase.write { db in
            let plan = try Self.dayPlan(date, creatingAt: createdAt, db)
            var block = block
            if let id = block.id {
                let stored = try Self.storedBlock(id, in: date, db)
                guard !stored.isFixed else { throw DayPlanError.fixedBlock }
                block.isFixed = false
            }
            if block.kind != .task { block.taskID = nil }
            switch DayPlanRules.check(block, among: plan.blocks, workingHours: plan.workingHours) {
            case .invalid(let problem): throw DayPlanError.invalid(problem)
            case .overlapsFixed(let fixed) where !confirmed: return .needsConfirmation(fixed)
            case .fits, .overlapsFixed: break
            }
            var row = DayBlockRow(block, in: date)
            if block.id == nil { try row.insert(db) } else { try row.update(db) }
            try Self.markDraft(date, db)
            return .saved(try Self.dayPlan(date, db)!)
        }
    }

    private static func storedBlock(_ id: Int64, in date: LocalDate, _ db: Database) throws -> DayBlock {
        guard let row = try DayBlockRow.fetchOne(db, key: id), row.planDate == date.isoString else {
            throw DayPlanError.blockNotFound
        }
        return try row.block()
    }

    private static func markDraft(_ date: LocalDate, _ db: Database) throws {
        try db.execute(sql: "UPDATE dayPlan SET state = 'draft', approvedAt = NULL WHERE date = ?", arguments: [date.isoString])
    }

    /// Creates the plan from the current preferences if `date` has none.
    private static func dayPlan(_ date: LocalDate, creatingAt createdAt: Date, _ db: Database) throws -> DayPlan {
        if let plan = try dayPlan(date, db) { return plan }
        let preferences = try dayPreferences(db)
        try DayPlanRow(date: date, workingHours: preferences.workingHours, createdAt: createdAt).insert(db)
        for block in preferences.dayBlocks {
            var row = DayBlockRow(block, in: date)
            try row.insert(db)
        }
        return try dayPlan(date, db)!
    }

    private static func dayPreferences(_ db: Database) throws -> DayPreferences {
        try DayPreferencesRow.fetchOne(db, key: 1)?.preferences() ?? .standard
    }

    private static func dayPlan(_ date: LocalDate, _ db: Database) throws -> DayPlan? {
        guard let row = try DayPlanRow.fetchOne(db, key: date.isoString) else { return nil }
        let blocks = try DayBlockRow.filter(Column("planDate") == date.isoString)
            .order(Column("startTime"), Column("id")).fetchAll(db).map { try $0.block() }
        let tasks = try TaskRecord.filter(keys: Set(blocks.compactMap(\.taskID))).fetchAll(db)
        return try row.plan(blocks: blocks, taskTitles: Dictionary(uniqueKeysWithValues: tasks.map { ($0.id!, $0.title) }))
    }
}

import Foundation
import GRDB

public enum DayPlanError: Error, Equatable {
    /// Edits and approval go to a plan the owner has seen; they never
    /// create one.
    case planNotFound
    case blockNotFound
    /// The task was deleted while the block was being edited.
    case taskNotFound
    case invalid(DayPlanProblem)
}

/// What saving the day preferences did to today's plan.
public enum DayPreferencesSave: Equatable, Sendable {
    /// Today's plan, if there is one, now has the new working hours.
    case appliedToToday
    /// A block on today's plan falls outside the new hours, so today keeps
    /// these; new days start with the new ones.
    case todayKept(TimeSpan)
}

/// What a block edit did.
public enum DayPlanEdit: Equatable, Sendable {
    case saved(DayPlan)
    /// Nothing was saved: the block overlaps these blocks across the fixed
    /// line (see `DayBlockCheck.needsConfirmation`), and the owner has to
    /// confirm first.
    case needsConfirmation([DayBlock])
}

/// Day plans and the preferences they start from (decision 0004). Plans are
/// owner data: clearing caches never touches them. Each edit is read,
/// checked against `DayPlanRules` and written in one write, and any edit
/// makes an approved plan a draft again.
///
/// Only `dayPlan(for:)` creates a plan. Edits and approval name the date of
/// the plan the owner is looking at and fail with `planNotFound` if it has
/// none, so a page left open past midnight cannot approve a day it never
/// showed.
extension TaskRepository {
    public func dayPreferences() async throws -> DayPreferences {
        try await ownerDatabase.read { db in try Self.dayPreferences(db) }
    }

    /// Saves preferences that pass `DayPreferences.problem`, or throws
    /// `invalid`. The working hours also go to the plan for `today` when all
    /// its blocks fit them (owner request, 2026-11-02); its state stays, since
    /// no block moves. Fixed blocks such as lunch, and other plans already
    /// created, keep what they started with.
    @discardableResult
    public func saveDayPreferences(_ preferences: DayPreferences, today: LocalDate? = nil) async throws -> DayPreferencesSave {
        if let problem = preferences.problem { throw DayPlanError.invalid(problem) }
        return try await ownerDatabase.write { db in
            try DayPreferencesRow(preferences).save(db)
            guard let today, let plan = try Self.dayPlan(today, db), plan.workingHours != preferences.workingHours else {
                return .appliedToToday
            }
            guard DayPlanRules.problems(in: plan.blocks, workingHours: preferences.workingHours).isEmpty else {
                return .todayKept(plan.workingHours)
            }
            try db.execute(sql: "UPDATE dayPlan SET workStart = ?, workEnd = ? WHERE date = ?",
                           arguments: [preferences.workingHours.start.description, preferences.workingHours.end.description,
                                       today.isoString])
            return .appliedToToday
        }
    }

    /// The plan for `date`, created as a draft from the current preferences
    /// the first time it is asked for.
    public func dayPlan(for date: LocalDate) async throws -> DayPlan {
        let createdAt = now()
        return try await ownerDatabase.write { db in
            if let plan = try Self.dayPlan(date, db) { return plan }
            let preferences = try Self.dayPreferences(db)
            try DayPlanRow(date: date, workingHours: preferences.workingHours, createdAt: createdAt).insert(db)
            for block in preferences.dayBlocks {
                var row = DayBlockRow(block, in: date)
                try row.insert(db)
            }
            return try Self.dayPlan(date, db)!
        }
    }

    /// Adds an ordinary block to the plan for `date`. One that lands on a
    /// fixed block is saved only when `confirmed`.
    public func addBlock(_ block: DayBlock, to date: LocalDate, confirmed: Bool = false) async throws -> DayPlanEdit {
        var block = block
        block.id = nil
        block.isFixed = false
        return try await editBlock(block, in: date, confirmed: confirmed)
    }

    /// Moves or resizes a block, or changes its kind or task. A fixed block
    /// such as lunch may be moved or resized for this date only (the owner's
    /// override; Settings are unchanged); it keeps its kind and stays fixed.
    public func updateBlock(_ block: DayBlock, in date: LocalDate, confirmed: Bool = false) async throws -> DayPlanEdit {
        guard block.id != nil else { throw DayPlanError.blockNotFound }
        return try await editBlock(block, in: date, confirmed: confirmed)
    }

    /// Deletes a block. Deleting a fixed block skips it for this date only.
    public func deleteBlock(_ id: Int64, from date: LocalDate) async throws -> DayPlan {
        try await ownerDatabase.write { db in
            _ = try Self.existingPlan(date, db)
            _ = try Self.storedBlock(id, in: date, db)
            _ = try DayBlockRow.deleteOne(db, key: id)
            try Self.markDraft(date, db)
            return try Self.dayPlan(date, db)!
        }
    }

    /// Marks the plan approved, unless `DayPlanRules` finds a problem in it.
    /// The coordinator then follows it (D3, `PlanSessions`).
    public func approveDayPlan(for date: LocalDate) async throws -> DayPlan {
        let approvedAt = now()
        return try await ownerDatabase.write { db in
            let plan = try Self.existingPlan(date, db)
            if let problem = DayPlanRules.problems(in: plan).first { throw DayPlanError.invalid(problem) }
            try db.execute(sql: "UPDATE dayPlan SET state = 'approved', approvedAt = ? WHERE date = ? AND state = 'draft'",
                           arguments: [approvedAt, date.isoString])
            return try Self.dayPlan(date, db)!
        }
    }

    private func editBlock(_ block: DayBlock, in date: LocalDate, confirmed: Bool) async throws -> DayPlanEdit {
        try await ownerDatabase.write { db in
            let plan = try Self.existingPlan(date, db)
            var block = block
            if let id = block.id {
                let stored = try Self.storedBlock(id, in: date, db)
                block.isFixed = stored.isFixed
                if stored.isFixed { block.kind = stored.kind }
            }
            if block.kind != .task { block.taskID = nil }
            if let taskID = block.taskID, try !TaskRecord.exists(db, key: taskID) {
                throw DayPlanError.taskNotFound
            }
            switch DayPlanRules.check(block, among: plan.blocks, workingHours: plan.workingHours) {
            case .invalid(let problem): throw DayPlanError.invalid(problem)
            case .needsConfirmation(let overlapping) where !confirmed: return .needsConfirmation(overlapping)
            case .fits, .needsConfirmation: break
            }
            var row = DayBlockRow(block, in: date)
            if block.id == nil { try row.insert(db) } else { try row.update(db) }
            try Self.markDraft(date, db)
            return .saved(try Self.dayPlan(date, db)!)
        }
    }

    private static func existingPlan(_ date: LocalDate, _ db: Database) throws -> DayPlan {
        guard let plan = try dayPlan(date, db) else { throw DayPlanError.planNotFound }
        return plan
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

    private static func dayPreferences(_ db: Database) throws -> DayPreferences {
        try DayPreferencesRow.fetchOne(db, key: 1)?.preferences() ?? .standard
    }

    static func dayPlan(_ date: LocalDate, _ db: Database) throws -> DayPlan? {
        guard let row = try DayPlanRow.fetchOne(db, key: date.isoString) else { return nil }
        let blocks = try DayBlockRow.filter(Column("planDate") == date.isoString)
            .order(Column("startTime"), Column("id")).fetchAll(db).map { try $0.block() }
        let tasks = try TaskRecord.filter(keys: Set(blocks.compactMap(\.taskID))).fetchAll(db)
        return try row.plan(blocks: blocks, taskTitles: Dictionary(uniqueKeysWithValues: tasks.map { ($0.id!, $0.title) }))
    }
}

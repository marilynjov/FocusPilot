import Foundation
import GRDB

/// A change to the stored runs of plan blocks, written in the same write as
/// the session transition it goes with.
public enum PlanRunChange: Sendable, Equatable {
    case started(PlanRun, planDate: LocalDate, taskID: Int64)
    case breakStarted(sessionID: UUID, breakID: Int64)
    /// Applies only when the session is a block's.
    case endedEarly(sessionID: UUID, at: Date)
}

/// Runs of approved plan blocks (D3). Owner data, like the plan itself.
extension TaskRepository {
    /// The plan for `date`, if one exists, and its runs. Never creates a
    /// plan: only the owner opening the day does.
    public func planToFollow(on date: LocalDate) async throws -> (plan: DayPlan?, runs: [PlanRun]) {
        try await ownerDatabase.read { db in
            let plan = try Self.dayPlan(date, db)
            let runs = try PlanRunRow.filter(Column("planDate") == date.isoString && Column("blockId") != nil)
                .fetchAll(db).map { try $0.run() }
            return (plan, runs)
        }
    }

    /// The run of the block that started `sessionID`, if any.
    public func planRun(for sessionID: UUID) async throws -> PlanRun? {
        try await ownerDatabase.read { db in
            try PlanRunRow.filter(Column("sessionId") == sessionID.uuidString && Column("blockId") != nil).fetchOne(db)?.run()
        }
    }

    /// Records "I need more time" on the block that started `sessionID`.
    /// Returns the updated run, or nil when the session is not a block's.
    public func requestMoreTime(for sessionID: UUID) async throws -> PlanRun? {
        let at = now()
        return try await ownerDatabase.write { db in
            try db.execute(sql: "UPDATE planRun SET moreTimeRequestedAt = ? WHERE sessionId = ?",
                           arguments: [at, sessionID.uuidString])
            return try PlanRunRow.filter(Column("sessionId") == sessionID.uuidString && Column("blockId") != nil).fetchOne(db)?.run()
        }
    }

    static func apply(_ change: PlanRunChange, _ db: Database) throws {
        switch change {
        case .started(let run, let date, let taskID):
            var row = try PlanRunRow(run, planDate: date, taskID: taskID)
            try row.insert(db)
        case .breakStarted(let sessionID, let breakID):
            guard var row = try PlanRunRow.filter(Column("sessionId") == sessionID.uuidString).fetchOne(db) else { return }
            var run = try row.run()
            run.breaksStarted.insert(breakID)
            row.breaksStarted = try JSONCoding.string(run.breaksStarted.sorted())
            try row.update(db)
        case .endedEarly(let sessionID, let at):
            try db.execute(sql: "UPDATE planRun SET endedEarlyAt = ? WHERE sessionId = ? AND endedEarlyAt IS NULL",
                           arguments: [at, sessionID.uuidString])
        }
    }
}

struct PlanRunRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "planRun"

    var id: Int64?
    var blockId: Int64?
    var planDate: String
    var taskId: Int64?
    var sessionId: String
    var startedAt: Date
    var endedEarlyAt: Date?
    var moreTimeRequestedAt: Date?
    var breaksStarted: String

    init(_ run: PlanRun, planDate: LocalDate, taskID: Int64) throws {
        blockId = run.blockID
        self.planDate = planDate.isoString
        taskId = taskID
        sessionId = run.sessionID.uuidString
        startedAt = run.startedAt
        endedEarlyAt = run.endedEarlyAt
        moreTimeRequestedAt = run.moreTimeRequestedAt
        breaksStarted = try JSONCoding.string(run.breaksStarted.sorted())
    }

    /// Only rows that still have their block; callers filter the rest out.
    func run() throws -> PlanRun {
        guard let blockId, let session = UUID(uuidString: sessionId) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Unreadable plan run \(sessionId)"))
        }
        let breaks: [Int64] = try JSONCoding.value(breaksStarted)
        return PlanRun(blockID: blockId, sessionID: session, startedAt: startedAt, endedEarlyAt: endedEarlyAt,
                       moreTimeRequestedAt: moreTimeRequestedAt, breaksStarted: Set(breaks))
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

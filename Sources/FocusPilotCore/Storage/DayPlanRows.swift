import Foundation
import GRDB

/// The owner's day preferences, a single row; fixed blocks are JSON.
struct DayPreferencesRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "dayPreferences"

    var id = 1
    var workStart: String
    var workEnd: String
    var fixedBlocks: String

    init(_ preferences: DayPreferences) throws {
        workStart = preferences.workingHours.start.description
        workEnd = preferences.workingHours.end.description
        fixedBlocks = try JSONCoding.string(preferences.fixedBlocks)
    }

    func preferences() throws -> DayPreferences {
        DayPreferences(workingHours: TimeSpan(try DayPlanRow.time(workStart), try DayPlanRow.time(workEnd)),
                       fixedBlocks: try JSONCoding.value(fixedBlocks))
    }
}

/// A day plan as stored, without its blocks.
struct DayPlanRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "dayPlan"

    var date: String
    var state: String
    var workStart: String
    var workEnd: String
    var createdAt: Date
    var approvedAt: Date?

    init(date: LocalDate, workingHours: TimeSpan, createdAt: Date) {
        self.date = date.isoString
        state = DayPlan.State.draft.rawValue
        workStart = workingHours.start.description
        workEnd = workingHours.end.description
        self.createdAt = createdAt
    }

    func plan(blocks: [DayBlock], taskTitles: [Int64: String]) throws -> DayPlan {
        guard let localDate = LocalDate(isoString: date), let state = DayPlan.State(rawValue: state) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Unreadable day plan \(date)"))
        }
        return DayPlan(date: localDate, state: state, workingHours: TimeSpan(try Self.time(workStart), try Self.time(workEnd)),
                       blocks: blocks, taskTitles: taskTitles)
    }

    static func time(_ text: String) throws -> ClockTime {
        guard let time = ClockTime(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Bad time \(text)"))
        }
        return time
    }
}

/// One block of a stored day plan.
struct DayBlockRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "dayBlock"

    var id: Int64?
    var planDate: String
    var kind: String
    var startTime: String
    var endTime: String
    var taskId: Int64?
    var isFixed: Bool

    init(_ block: DayBlock, in date: LocalDate) {
        id = block.id
        planDate = date.isoString
        kind = block.kind.rawValue
        startTime = block.start.description
        endTime = block.end.description
        taskId = block.kind == .task ? block.taskID : nil
        isFixed = block.isFixed
    }

    func block() throws -> DayBlock {
        guard let kind = DayBlock.Kind(rawValue: kind) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Unknown block kind \(kind)"))
        }
        return DayBlock(id: id, kind: kind, start: try DayPlanRow.time(startTime), end: try DayPlanRow.time(endTime),
                        taskID: taskId, isFixed: isFixed)
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

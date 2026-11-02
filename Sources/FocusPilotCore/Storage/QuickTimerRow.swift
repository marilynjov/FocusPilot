import Foundation
import GRDB

/// A quick timer as stored in the owner database.
struct QuickTimerRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "quickTimer"

    var id: Int64?
    var label: String?
    var startedAt: Date
    var plannedEnd: Date
    var endedAt: Date?
    var outcome: String?
    var notified: Int

    init(label: String?, startedAt: Date, plannedEnd: Date) {
        self.label = label
        self.startedAt = startedAt
        self.plannedEnd = plannedEnd
        notified = QuickTimer.Notified.none.rawValue
    }

    init(_ timer: QuickTimer) {
        id = timer.id
        label = timer.label
        startedAt = timer.startedAt
        plannedEnd = timer.plannedEnd
        endedAt = timer.endedAt
        outcome = timer.outcome?.rawValue
        notified = timer.notified.rawValue
    }

    func timer() throws -> QuickTimer {
        guard let id, let notified = QuickTimer.Notified(rawValue: notified) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Unreadable quick timer \(String(describing: id))"))
        }
        var result: QuickTimer.Outcome?
        if let outcome {
            guard let known = QuickTimer.Outcome(rawValue: outcome) else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Unknown quick timer outcome \(outcome)"))
            }
            result = known
        }
        return QuickTimer(id: id, label: label, startedAt: startedAt, plannedEnd: plannedEnd, endedAt: endedAt,
                          outcome: result, notified: notified)
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

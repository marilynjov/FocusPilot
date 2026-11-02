import Foundation
import GRDB

/// Quick timers (D2). Owner data: clearing caches never touches them, and
/// ended timers are kept for stats (D6).
extension TaskRepository {
    /// Starts a timer of `minutes` from now, unless one is already running.
    public func startQuickTimer(minutes: Int, label: String?) async throws -> QuickTimer {
        guard QuickTimer.minutesRange.contains(minutes) else { throw QuickTimerError.invalidLength }
        let startedAt = now()
        return try await ownerDatabase.write { db in
            if try Self.runningQuickTimer(db) != nil { throw QuickTimerError.alreadyRunning }
            var row = QuickTimerRow(label: QuickTimer.cleanLabel(label), startedAt: startedAt,
                                    plannedEnd: startedAt.addingTimeInterval(TimeInterval(minutes * 60)))
            try row.insert(db)
            return try row.timer()
        }
    }

    /// Saves a running timer's notices or end. A timer that has already
    /// ended stays as it was recorded, and this throws `notRunning`.
    public func saveQuickTimer(_ timer: QuickTimer) async throws {
        try await ownerDatabase.write { db in
            guard let stored = try QuickTimerRow.fetchOne(db, key: timer.id), stored.endedAt == nil else {
                throw QuickTimerError.notRunning
            }
            try QuickTimerRow(timer).update(db)
        }
    }

    /// The timer still running, if any.
    public func runningQuickTimer() async throws -> QuickTimer? {
        try await ownerDatabase.read { db in try Self.runningQuickTimer(db) }
    }

    /// Every quick timer, newest first, for stats.
    public func quickTimers() async throws -> [QuickTimer] {
        try await ownerDatabase.read { db in
            try QuickTimerRow.order(Column("startedAt").desc, Column("id").desc).fetchAll(db).map { try $0.timer() }
        }
    }

    private static func runningQuickTimer(_ db: Database) throws -> QuickTimer? {
        try QuickTimerRow.filter(Column("endedAt") == nil).order(Column("id").desc).fetchOne(db)?.timer()
    }
}

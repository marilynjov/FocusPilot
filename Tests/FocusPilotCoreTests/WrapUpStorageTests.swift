import Foundation
import GRDB
import Testing
@testable import FocusPilotCore

@Suite("Wrap-up storage")
struct WrapUpStorageTests {
    private let location: StorageLocation
    private let clock = SettableClock(wednesdayMorningInBogota)
    private let repository: TaskRepository

    init() throws {
        location = StorageLocation(directory: try makeTemporaryDirectory())
        repository = try TaskRepository(location: location, now: { [clock] in clock.now })
    }

    private let first = WrapUp(
        outcome: "Baseline paragraph drafted in §4.2.",
        remainingWork: "Ablation sentence still needs agent 2's table.",
        returnCue: "Review agent 2's ablation table, then write one sentence under Table 3."
    )
    private let second = WrapUp(outcome: "Ablation sentence written.", remainingWork: nil, returnCue: "Proofread §4")

    /// A session on `taskID` that ended now, as the coordinator records it.
    private func endedSession(on taskID: Int64) async throws -> FocusSession {
        let session = FocusSession(id: UUID(), taskID: taskID, action: "Explain baseline results", mode: .normal,
                                   startedAt: clock.now.addingTimeInterval(-50 * 60), plannedEnd: clock.now,
                                   phase: .ended(at: clock.now, reason: .reachedPlannedEnd))
        try await repository.record(FocusTransition(session: session, effects: [.persist(session)]))
        return session
    }

    @Test func everyWrapUpIsKeptAndTheLatestDrivesTheTask() async throws {
        let task = try await repository.addTask(NewTask(title: "Explain baseline results", nextAction: "Open Overleaf"))
        let morning = try await endedSession(on: task.id!)
        try await repository.saveWrapUp(first, forTask: task.id!, session: morning.id)
        clock.set(wednesdayMorningInBogota.addingTimeInterval(3 * 3600))
        let afternoon = try await endedSession(on: task.id!)

        try await repository.saveWrapUp(second, forTask: task.id!, session: afternoon.id)

        #expect(try await repository.wrapUpHistory(forTask: task.id!) == [
            TaskWrapUp(second, session: afternoon.id, at: clock.now),
            TaskWrapUp(first, session: morning.id, at: wednesdayMorningInBogota),
        ])
        let item = try #require(try await repository.todayTasks().first)
        #expect(item.wrapUp == TaskWrapUp(second, session: afternoon.id, at: clock.now))
        #expect(item.nextAction == "Proofread §4")
        let stored = try #require(try await repository.tasks().first)
        #expect(stored.revision == task.revision + 2)
        #expect(stored.updatedAt == clock.now)
    }

    @Test func aTaskWithoutAWrapUpHasNone() async throws {
        let task = try await repository.addTask(NewTask(title: "Explain baseline results"))

        #expect(try await repository.todayTasks().first?.wrapUp == nil)
        #expect(try await repository.wrapUpHistory(forTask: task.id!).isEmpty)
    }

    @Test func markingTheNowTaskDonePromotesTheFirstNextTaskInTheSameWrite() async throws {
        let current = try await repository.addTask(NewTask(title: "Explain baseline results"))
        let following = try await repository.addTask(NewTask(title: "Write the ablation section"))
        try await repository.moveTask(current.id!, to: .now, .top)
        let session = try await endedSession(on: current.id!)
        let before = try await repository.tasks()

        try await repository.saveWrapUp(first, forTask: current.id!, session: session.id, markingDone: true)

        #expect(try await repository.todayTasks().map(\.title) == ["Write the ablation section"])
        #expect(try await repository.nowTask()?.id == following.id)
        let after = try await repository.tasks()
        #expect(after.map(\.status) == [.done, .now])
        #expect(zip(before, after).allSatisfy { $1.revision == $0.revision + 1 && $1.updatedAt == clock.now })
        #expect(try await repository.wrapUpHistory(forTask: current.id!).count == 1)
    }

    @Test func savingForATaskThatNoLongerExistsFailsAndKeepsNoRow() async throws {
        let task = try await repository.addTask(NewTask(title: "Explain baseline results"))
        let session = try await endedSession(on: task.id!)

        await #expect(throws: TaskRepository.WrapUpError.taskNotFound) {
            try await repository.saveWrapUp(first, forTask: 42, session: session.id)
        }
        let rows = try await DatabaseQueue(path: location.ownerDatabaseURL.path).read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM wrapUp")
        }
        #expect(rows == 0)
    }
}

@Suite("Owner schema migration to v8")
struct OwnerMigrationV8Tests {
    @Test func tasksSavedBeforeWrapUpsHaveNoneAndKeepTheirRevision() async throws {
        let location = StorageLocation(directory: try makeTemporaryDirectory())
        let oldDatabase = try DatabaseQueue(path: location.ownerDatabaseURL.path)
        try OwnerSchema.migrator.migrate(oldDatabase, upTo: "owner-v7-rules")
        try await oldDatabase.write { db in
            try db.execute(sql: "INSERT INTO task (title, nextAction, revision) VALUES ('Explain baseline results', 'Open Overleaf', 3)")
        }
        try oldDatabase.close()

        let repository = try TaskRepository(location: location)

        let item = try #require(try await repository.todayTasks().first)
        #expect(item.wrapUp == nil)
        #expect(item.nextAction == "Open Overleaf")
        #expect(try await repository.tasks().first?.revision == 3)
        #expect(OwnerSchema.migrator.migrations.suffix(11) == ["owner-v7-rules", "owner-v8-wrapup", "owner-v9-herdr-agents", "owner-v10-exceptions",
                                                                 "owner-v11-observe", "owner-v12-day-plan", "owner-v13-quick-timer",
                                                                 "owner-v14-plan-sessions", "owner-v15-reported-agents",
                                                                 "owner-v16-review-opened", "owner-v17-warp-windows"])
    }
}

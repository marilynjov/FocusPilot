import Foundation
import GRDB
import Testing
@testable import FocusPilotCore

@Suite("Deleting a task")
struct TaskDeletionTests {
    private let location: StorageLocation
    private let repository: TaskRepository
    private let today = LocalDate(year: 2026, month: 10, day: 14)

    init() throws {
        location = StorageLocation(directory: try makeTemporaryDirectory())
        repository = try TaskRepository(location: location, now: { wednesdayMorningInBogota })
    }

    private func count(_ table: String) throws -> Int {
        try DatabaseQueue(path: location.ownerDatabaseURL.path).read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
        }
    }

    private func session(on taskID: Int64, phase: SessionPhase) -> FocusSession {
        FocusSession(id: UUID(), taskID: taskID, action: "Write", mode: .normal, startedAt: wednesdayMorningInBogota,
                     plannedEnd: wednesdayMorningInBogota.addingTimeInterval(1500), phase: phase)
    }

    private func store(_ session: FocusSession) throws {
        try DatabaseQueue(path: location.ownerDatabaseURL.path).write { db in try SessionRow(session).save(db) }
    }

    @Test func itRemovesTheTaskItsHistoryAndItsBlocks() async throws {
        let task = try await repository.addTask(title: "Paint")
        let other = try await repository.addTask(title: "Read")
        let taskID = try #require(task.id)
        let otherID = try #require(other.id)
        try store(session(on: taskID, phase: .ended(at: wednesdayMorningInBogota, reason: .completed)))
        try store(session(on: otherID, phase: .ended(at: wednesdayMorningInBogota, reason: .completed)))
        _ = try await repository.dayPlan(for: today)
        _ = try await repository.addBlock(DayBlock(kind: .task, start: ClockTime(9, 0), end: ClockTime(10, 0), taskID: taskID), to: today)
        _ = try await repository.addBlock(DayBlock(kind: .task, start: ClockTime(10, 0), end: ClockTime(11, 0), taskID: otherID), to: today)

        let ended = session(on: taskID, phase: .ended(at: wednesdayMorningInBogota, reason: .completed))
        try store(ended)
        try await DatabaseQueue(path: location.ownerDatabaseURL.path).write { db in
            try db.execute(sql: """
                INSERT INTO wrapUp (taskId, sessionId, savedAt) VALUES (?, ?, ?)
                """, arguments: [taskID, ended.id.uuidString, wednesdayMorningInBogota])
            try db.execute(sql: """
                INSERT INTO herdrReviewItem (taskId, kind, occurredAt, agentLabel) VALUES (?, 'finished', ?, 'Agent')
                """, arguments: [taskID, wednesdayMorningInBogota])
            try db.execute(sql: """
                INSERT INTO pilotEvent (kind, at, taskId) VALUES ('sessionEnded', ?, ?)
                """, arguments: [wednesdayMorningInBogota, taskID])
            try db.execute(sql: """
                INSERT INTO reportedAgent (source, agentKey, label, taskId, linkedByOwner, state,
                                           firstReportAt, lastReportAt, stateChangedAt)
                VALUES ('command', 'k', 'Agent', ?, 1, 'working', ?, ?, ?)
                """, arguments: [taskID, wednesdayMorningInBogota, wednesdayMorningInBogota, wednesdayMorningInBogota])
        }

        try await repository.deleteTask(taskID)

        #expect(try await repository.tasks().map(\.id) == [otherID])
        #expect(try count("focusSession") == 1)
        #expect(try count("wrapUp") == 0)
        #expect(try count("herdrReviewItem") == 0)
        try await DatabaseQueue(path: location.ownerDatabaseURL.path).read { db in
            // The metric keeps its row without the task; the agent is free again.
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pilotEvent WHERE taskId IS NULL") == 1)
            let agent = try Row.fetchOne(db, sql: "SELECT taskId, linkedByOwner FROM reportedAgent")
            #expect(agent?["taskId"] as Int64? == nil)
            #expect(agent?["linkedByOwner"] as Bool? == false)
        }
        let taskBlocks = try await repository.dayPlan(for: today).blocks.filter { $0.kind == .task }
        #expect(taskBlocks.map(\.taskID) == [otherID])
    }

    /// Removing a block adds nothing the owner has not approved, and turning
    /// the plan into a draft would silently stop the rest of the day.
    @Test func anApprovedPlanStaysApproved() async throws {
        let task = try await repository.addTask(title: "Paint")
        let taskID = try #require(task.id)
        _ = try await repository.dayPlan(for: today)
        _ = try await repository.addBlock(DayBlock(kind: .task, start: ClockTime(9, 0), end: ClockTime(10, 0), taskID: taskID), to: today)
        _ = try await repository.approveDayPlan(for: today)

        try await repository.deleteTask(taskID)

        #expect(try await repository.dayPlan(for: today).state == .approved)
    }

    @Test(arguments: [SessionPhase.running, .paused(since: wednesdayMorningInBogota), .onBreak(until: wednesdayMorningInBogota),
                      .onBreak(until: wednesdayMorningInBogota, movesEnd: true)])
    func theTaskASessionIsOnIsRefused(phase: SessionPhase) async throws {
        let task = try await repository.addTask(title: "Paint")
        let taskID = try #require(task.id)
        try store(session(on: taskID, phase: phase))

        _ = try await repository.dayPlan(for: today)
        _ = try await repository.addBlock(DayBlock(kind: .task, start: ClockTime(9, 0), end: ClockTime(10, 0), taskID: taskID), to: today)

        await #expect(throws: TaskDeletionError.inRunningSession) { try await repository.deleteTask(taskID) }
        #expect(try await repository.tasks().count == 1)
        #expect(try count("focusSession") == 1)
        #expect(try await repository.dayPlan(for: today).blocks.contains { $0.taskID == taskID })
    }

    @Test func aMissingTaskIsReported() async throws {
        await #expect(throws: TaskDeletionError.notFound) { try await repository.deleteTask(999) }
    }

    @Test func aSessionCannotStartOnADeletedTask() async throws {
        let request = SessionRequest(id: UUID(), taskID: 999, action: "Paint", mode: .normal, duration: 600)
        let transition = try FocusEngine.handle(.start(request), session: nil, at: wednesdayMorningInBogota)

        await #expect(throws: FocusCoordinator.SessionError.noCurrentTask) {
            _ = try await repository.record(transition)
        }
    }

    /// The session before it becomes the latest, so nothing goes on offering
    /// the deleted task (Keep going), and a relaunch finds the same one.
    @Test func theCoordinatorForgetsTheDeletedTasksSession() async throws {
        let fixture = try await SessionFixture()
        let firstID = try await fixture.coordinator.todayTasks()[0].id
        try await fixture.coordinator.startSession(duration: 600, mode: .normal)
        _ = try await fixture.coordinator.complete()
        let first = await fixture.coordinator.snapshot().session
        try await fixture.coordinator.capture(NewTask(title: "Paint"))
        let paintID = try #require(try await fixture.coordinator.todayTasks().first { $0.id != firstID }?.id)
        try await fixture.coordinator.moveTask(paintID, to: .now, .top)
        try await fixture.coordinator.startSession(duration: 600, mode: .normal)
        _ = try await fixture.coordinator.complete()

        try await fixture.coordinator.deleteTask(paintID)

        #expect(await fixture.coordinator.snapshot().session?.id == first?.id)
        let relaunched = try fixture.relaunched()
        try await relaunched.launch()
        #expect(await relaunched.snapshot().session?.id == first?.id)
    }
}

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

        try await repository.deleteTask(taskID)

        #expect(try await repository.tasks().map(\.id) == [otherID])
        #expect(try count("focusSession") == 1)
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

    @Test(arguments: [SessionPhase.running, .paused(since: wednesdayMorningInBogota), .onBreak(until: wednesdayMorningInBogota)])
    func theTaskASessionIsOnIsRefused(phase: SessionPhase) async throws {
        let task = try await repository.addTask(title: "Paint")
        let taskID = try #require(task.id)
        try store(session(on: taskID, phase: phase))

        await #expect(throws: TaskDeletionError.inRunningSession) { try await repository.deleteTask(taskID) }
        #expect(try await repository.tasks().count == 1)
        #expect(try count("focusSession") == 1)
    }

    @Test func aMissingTaskIsReported() async throws {
        await #expect(throws: TaskDeletionError.notFound) { try await repository.deleteTask(999) }
    }
}

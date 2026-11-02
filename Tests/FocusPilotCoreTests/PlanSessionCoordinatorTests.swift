import Foundation
import GRDB
import Testing
@testable import FocusPilotCore

/// Following an approved plan through the coordinator (D3). The fixture's
/// clock starts on Wednesday 14 October 2026 at 10:00 in Bogotá; the plan has
/// the standard lunch, 12:00–13:00.
@Suite("Approved plans start sessions")
struct PlanSessionCoordinatorTests {
    private let today = LocalDate(year: 2026, month: 10, day: 14)

    private func at(_ time: String) -> Date {
        instant("2026-10-14T\(time):00-05:00")
    }

    /// A task for the block, other than the pinned Now task.
    private func reportTask(_ fixture: SessionFixture) async throws -> Int64 {
        try await fixture.coordinator.capture(NewTask(title: "Write the report"))
        return try #require(try await fixture.coordinator.todayTasks().first { $0.title == "Write the report" }?.id)
    }

    /// Plans one task block on today's plan and approves it.
    @discardableResult
    private func approve(_ fixture: SessionFixture, block start: (Int, Int), to end: (Int, Int),
                         on coordinator: FocusCoordinator? = nil) async throws -> Int64 {
        let coordinator = coordinator ?? fixture.coordinator
        let taskID = try await reportTask(fixture)
        _ = try await coordinator.dayPlan(for: today)
        let block = DayBlock(kind: .task, start: ClockTime(start.0, start.1), end: ClockTime(end.0, end.1), taskID: taskID)
        _ = try await coordinator.addBlock(block, to: today, confirmed: true)
        _ = try await coordinator.approveDayPlan(for: today)
        return taskID
    }

    private func moveClock(_ fixture: SessionFixture, to time: String) {
        fixture.advance(seconds: at(time).timeIntervalSince(fixture.clock.now))
    }

    @Test func theSessionStartsAtBlockStartAndEndsAtBlockEnd() async throws {
        let fixture = try await SessionFixture()
        let taskID = try await approve(fixture, block: (10, 30), to: (11, 30))
        #expect(await fixture.coordinator.snapshot().activeSession == nil)
        #expect(await fixture.coordinator.snapshot().nextDeadline == at("10:30"))

        moveClock(fixture, to: "10:30")
        try await fixture.coordinator.reconcile()

        let session = try #require(await fixture.coordinator.snapshot().activeSession)
        #expect(session.taskID == taskID)
        #expect(session.action == "Write the report")
        #expect(session.mode == .normal)
        #expect(session.plannedEnd == at("11:30"))
        #expect(await fixture.publisher.published.last?.session?.end == at("11:30"))
        #expect(await fixture.notices.delivered == [.planBlockStarted(title: "Write the report", end: at("11:30"))])
        #expect(await fixture.coordinator.snapshot().activePlanRun?.sessionID == session.id)

        moveClock(fixture, to: "11:30")
        try await fixture.coordinator.reconcile()
        try await fixture.coordinator.reconcile()

        let ended = try #require(await fixture.coordinator.snapshot().session)
        #expect(ended.id == session.id)
        #expect(ended.phase == .ended(at: at("11:30"), reason: .reachedPlannedEnd))
    }

    @Test func approvingDuringABlockStartsItForTheTimeLeft() async throws {
        let fixture = try await SessionFixture()

        try await approve(fixture, block: (9, 30), to: (10, 45))

        #expect(await fixture.coordinator.snapshot().activeSession?.plannedEnd == at("10:45"))
    }

    @Test func doneEarlyEndsTheBlockAndTheSessionForGood() async throws {
        let fixture = try await SessionFixture()
        try await approve(fixture, block: (9, 30), to: (11, 0))
        fixture.advance(minutes: 20)

        #expect(try await fixture.coordinator.complete() == .completed)
        try await fixture.coordinator.reconcile()

        let snapshot = await fixture.coordinator.snapshot()
        #expect(snapshot.activeSession == nil)
        #expect(snapshot.session?.phase == .ended(at: at("10:20"), reason: .completed))
        let runs = try await fixture.coordinator.repository.planToFollow(on: today).runs
        #expect(runs.map(\.endedEarlyAt) == [at("10:20")])
        // A relaunch does not start it again either.
        let relaunched = try fixture.relaunched()
        try await relaunched.launch()
        #expect(await relaunched.snapshot().activeSession == nil)
    }

    @Test func needingMoreTimeIsRecordedAndTheBlockKeepsItsEnd() async throws {
        let fixture = try await SessionFixture()
        try await approve(fixture, block: (9, 30), to: (11, 0))

        try await fixture.coordinator.requestMoreTime()

        let snapshot = await fixture.coordinator.snapshot()
        #expect(snapshot.activePlanRun?.moreTimeRequestedAt == at("10:00"))
        #expect(snapshot.activeSession?.plannedEnd == at("11:00"))
    }

    @Test func launchCatchesUpOnTheBlockInProgress() async throws {
        let fixture = try await SessionFixture()
        try await approve(fixture, block: (10, 30), to: (11, 30))
        // The app was not running at 10:30.
        moveClock(fixture, to: "10:50")

        let relaunched = try fixture.relaunched()
        try await relaunched.launch()

        let session = try #require(await relaunched.snapshot().activeSession)
        #expect(session.startedAt == at("10:50"))
        #expect(session.plannedEnd == at("11:30"))
    }

    @Test func launchAfterTheBlockEndedStartsNothing() async throws {
        let fixture = try await SessionFixture()
        try await approve(fixture, block: (10, 30), to: (11, 30))
        moveClock(fixture, to: "11:40")

        let relaunched = try fixture.relaunched()
        try await relaunched.launch()

        #expect(await relaunched.snapshot().session == nil)
    }

    @Test func aStrictSessionIsLeftAloneAndTheBlockFollowsIt() async throws {
        let fixture = try await SessionFixture()
        try await fixture.coordinator.startSession(duration: 30 * 60, mode: .strict)
        let strict = try #require(await fixture.coordinator.snapshot().activeSession)
        try await approve(fixture, block: (10, 15), to: (11, 0))

        moveClock(fixture, to: "10:15")
        try await fixture.coordinator.reconcile()
        #expect(await fixture.coordinator.snapshot().activeSession == strict)
        #expect(await fixture.publisher.published.last?.session?.mode == .strict)

        moveClock(fixture, to: "10:30")
        try await fixture.coordinator.reconcile()

        let block = try #require(await fixture.coordinator.snapshot().activeSession)
        #expect(block.id != strict.id)
        #expect(block.mode == .normal)
        #expect(block.plannedEnd == at("11:00"))
    }

    @Test func lunchInsideABlockLiftsSessionRulesUntilItEnds() async throws {
        let fixture = try await SessionFixture()
        try await approve(fixture, block: (11, 30), to: (13, 30))
        moveClock(fixture, to: "11:30")
        try await fixture.coordinator.reconcile()
        #expect(await fixture.coordinator.snapshot().nextDeadline == at("12:00"))

        moveClock(fixture, to: "12:00")
        try await fixture.coordinator.reconcile()

        #expect(await fixture.coordinator.snapshot().activeSession?.phase == .onBreak(until: at("13:00")))
        #expect(await fixture.publisher.published.last?.session?.resumesAt == at("13:00"))

        moveClock(fixture, to: "13:00")
        try await fixture.coordinator.reconcile()
        #expect(await fixture.coordinator.snapshot().activeSession?.phase == .running)
        #expect(await fixture.publisher.published.last?.session?.resumesAt == nil)
    }

    @Test func editingThePlanMakesItADraftThatStartsNothing() async throws {
        let fixture = try await SessionFixture()
        let taskID = try await approve(fixture, block: (10, 30), to: (11, 30))
        _ = try await fixture.coordinator.addBlock(
            DayBlock(kind: .task, start: ClockTime(14, 0), end: ClockTime(15, 0), taskID: taskID), to: today)
        #expect(await fixture.coordinator.snapshot().nextDeadline == nil)

        moveClock(fixture, to: "10:30")
        try await fixture.coordinator.reconcile()

        #expect(await fixture.coordinator.snapshot().session == nil)
    }

    @Test func deletingABlockKeepsItsRunAsHistory() async throws {
        let fixture = try await SessionFixture()
        try await approve(fixture, block: (9, 30), to: (11, 0))
        let plan = try await fixture.coordinator.dayPlan(for: today)
        let blockID = try #require(plan.blocks.first { $0.kind == .task }?.id)

        _ = try await fixture.coordinator.deleteBlock(blockID, from: today)

        let rows = try await DatabaseQueue(path: fixture.location.ownerDatabaseURL.path).read { db in
            try Row.fetchAll(db, sql: "SELECT blockId, planDate FROM planRun").map { row in
                (row["blockId"] as Int64?, row["planDate"] as String)
            }
        }
        #expect(rows.count == 1)
        #expect(rows.first?.0 == nil)
        #expect(rows.first?.1 == "2026-10-14")
    }
}

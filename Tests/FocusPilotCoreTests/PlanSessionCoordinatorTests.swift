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
        // The plan set lunch aside, so the session still ends with its block.
        #expect(await fixture.coordinator.snapshot().activeSession?.plannedEnd == at("13:30"))
    }

    @Test func backToTaskEndsAPlanBreakForGood() async throws {
        let fixture = try await SessionFixture()
        try await approve(fixture, block: (11, 30), to: (13, 30))
        moveClock(fixture, to: "12:00")
        try await fixture.coordinator.reconcile()
        #expect(await fixture.coordinator.snapshot().activeSession?.phase == .onBreak(until: at("13:00")))

        fixture.advance(minutes: 20)
        try await fixture.coordinator.endBreak()
        try await fixture.coordinator.reconcile()

        #expect(await fixture.coordinator.snapshot().activeSession?.phase == .running)
        #expect(await fixture.publisher.published.last?.session?.resumesAt == nil)
    }

    @Test func moreTimeOnABlockExtendsItsSessionAndIsNoted() async throws {
        let fixture = try await SessionFixture()
        try await approve(fixture, block: (9, 30), to: (11, 0))

        try await fixture.coordinator.extend(by: 10 * 60)

        let snapshot = await fixture.coordinator.snapshot()
        #expect(snapshot.activeSession?.plannedEnd == at("11:10"))
        #expect(snapshot.activePlanRun?.moreTimeRequestedAt == at("10:00"))
        #expect(await fixture.publisher.published.last?.session?.end == at("11:10"))
    }

    @Test func theRaccoonReadsTodaysPlanWithoutCreatingOne() async throws {
        let fixture = try await SessionFixture()
        #expect(try await fixture.coordinator.planToFollowToday().plan == nil)

        try await approve(fixture, block: (9, 30), to: (11, 0))

        let (plan, runs) = try await fixture.coordinator.planToFollowToday()
        #expect(plan?.state == .approved)
        #expect(runs.count == 1)
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

    /// Running sessions as stored, not as the coordinator remembers them.
    private func storedActiveSessions(_ fixture: SessionFixture) async throws -> [FocusSession] {
        try await DatabaseQueue(path: fixture.location.ownerDatabaseURL.path).read { db in
            try SessionRow.fetchAll(db).map { try $0.session() }.filter { !$0.hasEnded }
        }
    }

    @Test(arguments: 0..<8)
    func anOwnerStartAndABlockStartAtOnceLeaveOneSession(round: Int) async throws {
        let fixture = try await SessionFixture()
        try await approve(fixture, block: (10, 30), to: (11, 30))
        moveClock(fixture, to: "10:30")

        let coordinator = fixture.coordinator
        let owner = Task { try await coordinator.startSession(duration: 25 * 60, mode: .strict) }
        let plan = Task { try await coordinator.reconcile() }
        let ownerResult = await owner.result
        try await plan.value

        let stored = try await storedActiveSessions(fixture)
        #expect(stored.count == 1)
        #expect(await fixture.coordinator.snapshot().activeSession == stored.first)
        // Whichever came second was refused or waited, never stored beside it.
        if case .failure(let error) = ownerResult {
            #expect(error as? FocusEngineError == .sessionAlreadyActive)
            #expect(stored.first?.mode == .normal)
        } else {
            #expect(stored.first?.mode == .strict)
        }
    }

    @Test func storageRefusesASecondRunningSession() async throws {
        let fixture = try await SessionFixture()
        try await fixture.coordinator.startSession(duration: 25 * 60, mode: .normal)
        let other = try FocusEngine.handle(.start(SessionRequest(id: UUID(), taskID: 1, action: "Other", mode: .normal,
                                                                 duration: 600)), session: nil, at: fixture.clock.now)

        await #expect(throws: FocusEngineError.sessionAlreadyActive) {
            try await fixture.coordinator.repository.record(other)
        }
        #expect(try await storedActiveSessions(fixture).count == 1)
    }

    @Test func backToBackBlocksHandOverAtTheSharedInstant() async throws {
        let fixture = try await SessionFixture()
        let taskID = try await approve(fixture, block: (10, 30), to: (11, 0))
        _ = try await fixture.coordinator.addBlock(
            DayBlock(kind: .task, start: ClockTime(11, 0), end: ClockTime(11, 30), taskID: taskID), to: today)
        _ = try await fixture.coordinator.approveDayPlan(for: today)
        moveClock(fixture, to: "10:30")
        try await fixture.coordinator.reconcile()
        let first = try #require(await fixture.coordinator.snapshot().activeSession)
        #expect(await fixture.coordinator.snapshot().nextDeadline == at("11:00"))

        moveClock(fixture, to: "11:00")
        try await fixture.coordinator.reconcile()

        let second = try #require(await fixture.coordinator.snapshot().activeSession)
        #expect(second.id != first.id)
        #expect(second.startedAt == at("11:00"))
        #expect(second.plannedEnd == at("11:30"))
    }

    @Test func pausedThroughLunchThenResumedTakesTheRestOfLunch() async throws {
        let fixture = try await SessionFixture()
        try await approve(fixture, block: (11, 30), to: (13, 30))
        moveClock(fixture, to: "11:30")
        try await fixture.coordinator.reconcile()
        moveClock(fixture, to: "11:50")
        try await fixture.coordinator.pause()

        moveClock(fixture, to: "12:00")
        try await fixture.coordinator.reconcile()
        #expect(await fixture.coordinator.snapshot().activeSession?.phase == .paused(since: at("11:50")))

        moveClock(fixture, to: "12:30")
        try await fixture.coordinator.resume()

        #expect(await fixture.coordinator.snapshot().activeSession?.phase == .onBreak(until: at("13:00")))
        #expect(await fixture.publisher.published.last?.session?.resumesAt == at("13:00"))
    }

    @Test func aTimeZoneChangeMovesTheBlockToTheNewWallClock() async throws {
        let fixture = try await SessionFixture()
        try await approve(fixture, block: (10, 30), to: (11, 30))
        #expect(await fixture.coordinator.snapshot().activeSession == nil)

        // 10:00 in Bogotá is 11:00 in New York, inside the block there.
        fixture.zone.set(newYork)
        try await fixture.coordinator.reconcile()

        let session = try #require(await fixture.coordinator.snapshot().activeSession)
        #expect(session.plannedEnd == instant("2026-10-14T11:30:00-04:00"))
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

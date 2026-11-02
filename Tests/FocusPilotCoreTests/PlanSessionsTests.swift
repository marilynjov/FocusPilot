import Foundation
import Testing
@testable import FocusPilotCore

@Suite("Plan blocks as sessions")
struct PlanSessionsTests {
    private let today = LocalDate(year: 2026, month: 10, day: 14)
    private let sessionID = UUID()

    private func block(_ id: Int64, _ kind: DayBlock.Kind, _ start: (Int, Int), _ end: (Int, Int),
                       taskID: Int64? = nil, fixed: Bool = false) -> DayBlock {
        DayBlock(id: id, kind: kind, start: ClockTime(start.0, start.1), end: ClockTime(end.0, end.1),
                 taskID: taskID, isFixed: fixed)
    }

    private func plan(_ blocks: [DayBlock], on date: LocalDate? = nil, state: DayPlan.State = .approved) -> DayPlan {
        DayPlan(date: date ?? today, state: state, workingHours: TimeSpan(ClockTime(0, 0), ClockTime(23, 45)),
                blocks: blocks, taskTitles: [7: "Write the report"])
    }

    /// 10:30–11:30 on task 7, lunch 12:00–13:00, 12:30–14:00 on task 7 over lunch.
    private var day: DayPlan {
        plan([block(1, .task, (10, 30), (11, 30), taskID: 7),
              block(2, .lunch, (12, 0), (13, 0), fixed: true),
              block(3, .task, (12, 30), (14, 0), taskID: 7)])
    }

    private func at(_ time: String) -> Date {
        instant("2026-10-14T\(time):00-05:00")
    }

    private func step(_ plan: DayPlan, runs: [PlanRun] = [], session: FocusSession? = nil, at time: String) -> PlanStep? {
        PlanSessions.step(plan: plan, runs: runs, session: session, at: at(time), timeZone: bogota)
    }

    private func blockSession(_ phase: SessionPhase = .running) -> FocusSession {
        FocusSession(id: sessionID, taskID: 7, action: "Write the report", mode: .normal,
                     startedAt: at("12:30"), plannedEnd: at("14:00"), phase: phase)
    }

    // MARK: Mapping

    @Test func taskBlocksBecomeSessionsWithTheirBreaks() {
        let sessions = PlanSessions.sessions(in: day, timeZone: bogota)

        #expect(sessions == [
            PlannedSession(blockID: 1, taskID: 7, title: "Write the report", start: at("10:30"), end: at("11:30"), breaks: []),
            PlannedSession(blockID: 3, taskID: 7, title: "Write the report", start: at("12:30"), end: at("14:00"),
                           breaks: [PlannedBreak(blockID: 2, start: at("12:30"), end: at("13:00"))]),
        ])
    }

    @Test func draftsAndBlocksWithoutATaskStartNothing() {
        #expect(PlanSessions.sessions(in: plan(day.blocks, state: .draft), timeZone: bogota).isEmpty)
        let noTask = plan([block(1, .task, (10, 30), (11, 30)), block(2, .break, (11, 30), (11, 45))])
        #expect(PlanSessions.sessions(in: noTask, timeZone: bogota).isEmpty)
    }

    // MARK: Steps

    @Test func aBlockStartsWhenTheClockEntersIt() throws {
        #expect(step(day, at: "10:29") == nil)
        let started = try #require(step(day, at: "10:30"))
        guard case .startSession(let block) = started else { Issue.record("Expected a start"); return }
        #expect(block.blockID == 1)
        #expect(block.end == at("11:30"))
    }

    @Test func catchingUpStartsTheBlockInProgressButNotOneAlreadyOver() {
        guard case .startSession(let block) = step(day, at: "11:00") else { Issue.record("Expected a start"); return }
        #expect(block.blockID == 1)
        #expect(step(day, at: "11:30") == nil)
        #expect(step(day, at: "11:45") == nil)
    }

    @Test func aBlockRunsOnce() {
        let run = PlanRun(blockID: 1, sessionID: sessionID, startedAt: at("10:30"), endedEarlyAt: at("10:50"))
        #expect(step(day, runs: [run], at: "11:00") == nil)
    }

    @Test func anotherActiveSessionIsLeftAlone() {
        let strict = FocusSession(id: UUID(), taskID: 1, action: "Other", mode: .strict, startedAt: at("10:00"),
                                  plannedEnd: at("11:00"), phase: .running)
        #expect(step(day, session: strict, at: "10:45") == nil)
        // Once it has ended, the block runs for the time it has left.
        var ended = strict
        ended.phase = .ended(at: at("11:00"), reason: .reachedPlannedEnd)
        guard case .startSession(let block) = step(day, session: ended, at: "11:00") else { Issue.record("Expected a start"); return }
        #expect(block.blockID == 1)
    }

    @Test func lunchInsideABlockBecomesABreakOnce() {
        let run = PlanRun(blockID: 3, sessionID: sessionID, startedAt: at("12:30"))
        #expect(step(day, runs: [run], session: blockSession(), at: "12:30")
                == .startBreak(PlannedBreak(blockID: 2, start: at("12:30"), end: at("13:00")), sessionID: sessionID))
        var taken = run
        taken.breaksStarted = [2]
        #expect(step(day, runs: [taken], session: blockSession(), at: "12:40") == nil)
        #expect(step(day, runs: [run], session: blockSession(.paused(since: at("12:20"))), at: "12:40") == nil)
        #expect(step(day, runs: [run], session: blockSession(), at: "13:00") == nil)
    }

    @Test func theNextDeadlineIsTheNextBlockOrBreakStart() {
        #expect(PlanSessions.nextDeadline(plan: day, runs: [], at: at("10:00"), timeZone: bogota) == at("10:30"))
        let first = PlanRun(blockID: 1, sessionID: UUID(), startedAt: at("10:30"))
        #expect(PlanSessions.nextDeadline(plan: day, runs: [first], at: at("10:31"), timeZone: bogota) == at("12:30"))
        let second = PlanRun(blockID: 3, sessionID: sessionID, startedAt: at("12:30"), breaksStarted: [2])
        #expect(PlanSessions.nextDeadline(plan: day, runs: [first, second], at: at("12:31"), timeZone: bogota) == nil)
        #expect(PlanSessions.nextDeadline(plan: plan(day.blocks, state: .draft), runs: [], at: at("10:00"), timeZone: bogota) == nil)
    }

    // MARK: Daylight saving time (New York: 8 March 2026 skips 02:00–03:00, 1 November 2026 repeats 01:00–02:00)

    private let springForward = LocalDate(year: 2026, month: 3, day: 8)
    private let fallBack = LocalDate(year: 2026, month: 11, day: 1)

    @Test func anOrdinaryTimeIsThatWallClockInstant() {
        #expect(PlanSessions.instant(ClockTime(9, 0), on: today, in: bogota) == at("09:00"))
        #expect(PlanSessions.instant(ClockTime(1, 30), on: springForward, in: newYork) == instant("2026-03-08T01:30:00-05:00"))
        #expect(PlanSessions.instant(ClockTime(3, 0), on: springForward, in: newYork) == instant("2026-03-08T03:00:00-04:00"))
    }

    @Test func aTimeInTheSpringGapBecomesTheEndOfTheGap() {
        #expect(PlanSessions.instant(ClockTime(2, 30), on: springForward, in: newYork) == instant("2026-03-08T03:00:00-04:00"))
        #expect(PlanSessions.instant(ClockTime(2, 0), on: springForward, in: newYork) == instant("2026-03-08T03:00:00-04:00"))
    }

    @Test func aRepeatedAutumnTimeIsItsFirstOccurrence() {
        #expect(PlanSessions.instant(ClockTime(1, 30), on: fallBack, in: newYork) == instant("2026-11-01T01:30:00-04:00"))
        #expect(PlanSessions.instant(ClockTime(2, 0), on: fallBack, in: newYork) == instant("2026-11-01T02:00:00-05:00"))
    }

    @Test func blocksAcrossTransitionsKeepTheirWallClockEnds() {
        let spring = plan([block(1, .task, (1, 30), (3, 30), taskID: 7), block(2, .task, (2, 0), (2, 45), taskID: 7)],
                          on: springForward)
        let springSessions = PlanSessions.sessions(in: spring, timeZone: newYork)
        // 01:30–03:30 lasts one hour; 02:00–02:45 does not happen that day.
        #expect(springSessions.map(\.blockID) == [1])
        #expect(springSessions.first.map { $0.end.timeIntervalSince($0.start) } == 3600)

        let autumn = plan([block(1, .task, (0, 30), (1, 30), taskID: 7), block(2, .task, (1, 30), (2, 30), taskID: 7)],
                          on: fallBack)
        let autumnSessions = PlanSessions.sessions(in: autumn, timeZone: newYork)
        #expect(autumnSessions.map { $0.end.timeIntervalSince($0.start) } == [3600, 7200])
        #expect(autumnSessions[0].end == autumnSessions[1].start)
    }

    @Test func aBlockInTheRepeatedHourRunsFromTheFirstOccurrence() {
        // 01:30 first happens at 05:30 UTC (EDT); 02:00 is after the repeat, 07:00 UTC (EST).
        let autumn = plan([block(1, .task, (1, 30), (2, 0), taskID: 7)], on: fallBack)
        let session = PlanSessions.sessions(in: autumn, timeZone: newYork).first
        #expect(session?.start == instant("2026-11-01T05:30:00Z"))
        #expect(session.map { $0.end.timeIntervalSince($0.start) } == TimeInterval(90 * 60))
    }
}

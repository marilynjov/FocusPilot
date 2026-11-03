import Foundation
import Testing
@testable import FocusPilotCore

/// "Take a Break" (owner request, 2026-11-03): a break the owner takes stops
/// the countdown, so the planned end moves later by it. Plan breaks keep the
/// planned end; their tests are in FocusEngineTimeTests.
@Suite("FocusEngine owner breaks")
struct FocusEngineOwnerBreakTests {
    var clock = FakeClock()

    func start(_ mode: SessionMode = .normal, minutes: Double = 25) throws -> FocusSession {
        let request = SessionRequest(id: UUID(), taskID: 7, action: "Outline the essay", mode: mode, duration: minutes * 60)
        return try #require(FocusEngine.handle(.start(request), session: nil, at: clock.now).session)
    }

    func takeBreak(_ session: FocusSession, minutes: Double) throws -> FocusSession {
        try #require(FocusEngine.handle(.startBreak(duration: minutes * 60, movesEnd: true), session: session,
                                        at: clock.now).session)
    }

    @Test mutating func startingAnOwnerBreakAddsItsLengthAndLiftsNormalRulesUntilItEnds() throws {
        let running = try start(minutes: 25)
        clock.advance(minutes: 10)

        let transition = try FocusEngine.handle(.startBreak(duration: 5 * 60, movesEnd: true), session: running, at: clock.now)

        let onBreak = try #require(transition.session)
        let breakEnd = clock.minutes(from: clock.now, 5)
        #expect(onBreak.phase == .onBreak(until: breakEnd, movesEnd: true))
        #expect(onBreak.plannedEnd == clock.minutes(from: running.plannedEnd, 5))
        #expect(transition.effects == [
            .persist(onBreak),
            .publishPolicy(SessionPolicy(sessionID: running.id, mode: .normal, end: onBreak.plannedEnd, resumesAt: breakEnd)),
        ])
    }

    @Test mutating func aStrictSessionKeepsBlockingThroughAnOwnerBreak() throws {
        let running = try start(.strict, minutes: 25)

        let onBreak = try takeBreak(running, minutes: 5)

        #expect(FocusEngine.policy(for: onBreak) == SessionPolicy(sessionID: running.id, mode: .strict, end: onBreak.plannedEnd))
    }

    @Test mutating func theTimeLeftStandsStillThroughAnOwnerBreak() throws {
        let running = try start(minutes: 25)
        clock.advance(minutes: 10)
        let onBreak = try takeBreak(running, minutes: 5)

        #expect(onBreak.remaining(at: clock.now) == 15 * 60)
        clock.advance(minutes: 3)
        #expect(onBreak.remaining(at: clock.now) == 15 * 60)
        // A plan break's time was set aside by the plan: it counts down.
        let planBreak = try #require(FocusEngine.handle(.startBreak(duration: 5 * 60), session: running, at: clock.now).session)
        #expect(planBreak.plannedEnd == running.plannedEnd)
        clock.advance(minutes: 2)
        #expect(planBreak.remaining(at: clock.now) == 10 * 60)
    }

    @Test mutating func endingAnOwnerBreakEarlyGivesBackThePartNotTaken() throws {
        let running = try start(minutes: 25)
        clock.advance(minutes: 10)
        let onBreak = try takeBreak(running, minutes: 10)
        clock.advance(minutes: 4)

        let back = try #require(FocusEngine.handle(.endBreak, session: onBreak, at: clock.now).session)

        #expect(back.phase == .running)
        // 4 of the 10 minutes taken: the end is 4 minutes later than planned.
        #expect(back.plannedEnd == clock.minutes(from: running.plannedEnd, 4))
        #expect(back.remaining(at: clock.now) == 15 * 60)
    }

    @Test mutating func anOwnerBreakThatRunsOutAddsNothingMore() throws {
        let running = try start(minutes: 25)
        clock.advance(minutes: 10)
        let onBreak = try takeBreak(running, minutes: 5)
        clock.advance(minutes: 6)

        let transition = try FocusEngine.handle(.reconcile, session: onBreak, at: clock.now)

        let resumed = try #require(transition.session)
        #expect(resumed.phase == .running)
        #expect(resumed.plannedEnd == clock.minutes(from: running.plannedEnd, 5))
        #expect(transition.effects.contains(.notify(.breakEnded)))
        #expect(resumed.remaining(at: clock.now) == 14 * 60)
    }

    @Test mutating func endingABreakNeverPutsTheEndBeforeNow() throws {
        let running = try start(minutes: 25)
        clock.advance(minutes: 10)
        var onBreak = try takeBreak(running, minutes: 10)
        // E.g. a stored session whose end was earlier than the break's.
        onBreak.plannedEnd = clock.minutes(from: clock.now, 5)
        clock.advance(minutes: 1)

        let back = try #require(FocusEngine.handle(.endBreak, session: onBreak, at: clock.now).session)

        #expect(back.plannedEnd == clock.now)
    }

    // MARK: Storage

    @Test mutating func anOwnerBreakSurvivesARoundTripAndOldBreaksArePlanBreaks() throws {
        let onBreak = try takeBreak(try start(), minutes: 5)

        let decoded = try JSONDecoder().decode(FocusSession.self, from: JSONEncoder().encode(onBreak))
        #expect(decoded == onBreak)

        let old = try JSONDecoder().decode(SessionPhase.self, from: Data(#"{"kind":"onBreak","until":800000900}"#.utf8))
        #expect(old == .onBreak(until: Date(timeIntervalSinceReferenceDate: 800_000_900), movesEnd: false))
        // A plan break is written as before, without the flag.
        let planBreak = String(decoding: try JSONEncoder().encode(SessionPhase.onBreak(until: .now)), as: UTF8.self)
        #expect(!planBreak.contains("movesEnd"))
        let ownerBreak = String(decoding: try JSONEncoder().encode(SessionPhase.onBreak(until: .now, movesEnd: true)),
                                as: UTF8.self)
        #expect(ownerBreak.contains(#""movesEnd":true"#))
    }
}

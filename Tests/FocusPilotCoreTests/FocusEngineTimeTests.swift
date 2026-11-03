import Foundation
import Testing
@testable import FocusPilotCore

@Suite("FocusEngine over time")
struct FocusEngineTimeTests {
    var clock = FakeClock()

    func start(_ mode: SessionMode = .normal, minutes: Double = 25) throws -> FocusSession {
        let request = SessionRequest(id: UUID(), taskID: 7, action: "Outline the essay", mode: mode, duration: minutes * 60)
        return try #require(FocusEngine.handle(.start(request), session: nil, at: clock.now).session)
    }

    @Test mutating func reconcilingBeforeAnyDeadlineOnlyRepublishesThePolicy() throws {
        let running = try start()
        clock.advance(minutes: 10)

        let transition = try FocusEngine.handle(.reconcile, session: running, at: clock.now)

        #expect(transition.session == running)
        #expect(transition.effects == [
            .publishPolicy(SessionPolicy(sessionID: running.id, mode: .normal, end: running.plannedEnd)),
        ])
    }

    @Test mutating func reachingThePlannedEndEndsTheSessionAndNotifies() throws {
        let running = try start(minutes: 25)
        clock.advance(minutes: 25)

        let transition = try FocusEngine.handle(.reconcile, session: running, at: clock.now)

        let ended = try #require(transition.session)
        #expect(ended.phase == .ended(at: running.plannedEnd, reason: .reachedPlannedEnd))
        #expect(transition.effects == [.persist(ended), .publishPolicy(nil), .notify(.sessionReachedPlannedEnd)])
    }

    @Test(arguments: [SessionMode.normal, .strict])
    mutating func sleepingAcrossThePlannedEndRecordsTheEndAtThePlannedInstant(mode: SessionMode) throws {
        let running = try start(mode, minutes: 25)
        clock.advance(minutes: 10)
        // The Mac sleeps here and wakes three hours later.
        clock.advance(minutes: 180)

        let transition = try FocusEngine.handle(.reconcile, session: running, at: clock.now)

        let ended = try #require(transition.session)
        #expect(ended.phase == .ended(at: running.plannedEnd, reason: .reachedPlannedEnd))
        // For a strict session this is the app confirming the end the extensions waited for.
        #expect(transition.effects == [.persist(ended), .publishPolicy(nil), .notify(.sessionReachedPlannedEnd)])
    }

    @Test mutating func aBreakThatRunsOutResumesTheSessionAndNotifies() throws {
        let running = try start(minutes: 50)
        clock.advance(minutes: 20)
        let onBreak = try #require(FocusEngine.handle(.startBreak(duration: 5 * 60), session: running, at: clock.now).session)
        clock.advance(minutes: 6)

        let transition = try FocusEngine.handle(.reconcile, session: onBreak, at: clock.now)

        let resumed = try #require(transition.session)
        #expect(resumed.phase == .running)
        #expect(transition.effects == [
            .persist(resumed),
            .publishPolicy(SessionPolicy(sessionID: running.id, mode: .normal, end: running.plannedEnd)),
            .notify(.breakEnded),
        ])
    }

    @Test mutating func endingABreakEarlyRestoresSessionRules() throws {
        let running = try start(minutes: 50)
        let onBreak = try FocusEngine.handle(.startBreak(duration: 10 * 60), session: running, at: clock.now).session
        #expect(onBreak?.phase == .onBreak(until: clock.minutes(from: clock.now, 10)))
        clock.advance(minutes: 2)

        let transition = try FocusEngine.handle(.endBreak, session: onBreak, at: clock.now)

        #expect(transition.session?.phase == .running)
        #expect(transition.effects.last == .publishPolicy(FocusEngine.policy(for: running)))
    }

    @Test mutating func sleepingThroughABreakAndThePlannedEndOnlyReportsTheEnd() throws {
        let running = try start(minutes: 25)
        clock.advance(minutes: 20)
        let onBreak = try #require(FocusEngine.handle(.startBreak(duration: 3 * 60), session: running, at: clock.now).session)
        clock.advance(minutes: 120)

        let transition = try FocusEngine.handle(.reconcile, session: onBreak, at: clock.now)

        // Both deadlines were crossed: the break ended at minute 23, the session at 25.
        let ended = try #require(transition.session)
        #expect(ended.phase == .ended(at: running.plannedEnd, reason: .reachedPlannedEnd))
        #expect(transition.effects == [.persist(ended), .publishPolicy(nil), .notify(.sessionReachedPlannedEnd)])
    }

    @Test mutating func aPauseStopsTheCountdownAndResumingMovesTheEndLater() throws {
        let running = try start(minutes: 25)
        clock.advance(minutes: 10)
        let paused = try #require(FocusEngine.handle(.pause, session: running, at: clock.now).session)
        #expect(paused.nextDeadline == nil)
        clock.advance(minutes: 30)

        // Nothing is due while paused, and the time left stands still.
        let reconciled = try FocusEngine.handle(.reconcile, session: paused, at: clock.now)
        #expect(reconciled.session?.phase == paused.phase)
        #expect(paused.remaining(at: clock.now) == 15 * 60)

        let resumed = try #require(FocusEngine.handle(.resume, session: paused, at: clock.now).session)
        #expect(resumed.plannedEnd == clock.minutes(from: running.plannedEnd, 30))
        #expect(resumed.remaining(at: clock.now) == 15 * 60)
    }

    /// Breaks come from the day plan, which already set their time aside.
    @Test mutating func aBreakKeepsThePlannedEnd() throws {
        let running = try start(minutes: 50)
        clock.advance(minutes: 20)
        let onBreak = try #require(FocusEngine.handle(.startBreak(duration: 10 * 60), session: running, at: clock.now).session)
        #expect(onBreak.plannedEnd == running.plannedEnd)
        clock.advance(minutes: 4)
        #expect(onBreak.remaining(at: clock.now) == 26 * 60)

        let back = try #require(FocusEngine.handle(.endBreak, session: onBreak, at: clock.now).session)
        #expect(back.plannedEnd == running.plannedEnd)
    }

    @Test mutating func anEventArrivingAfterAMissedPlannedEndIsJudgedAgainstTheEndedSession() throws {
        let running = try start(minutes: 25)
        clock.advance(minutes: 40)

        #expect(throws: FocusEngineError.noActiveSession) {
            try FocusEngine.handle(.pause, session: running, at: clock.now)
        }
    }

    @Test mutating func theNextDeadlineIsTheEarlierOfBreakEndAndPlannedEnd() throws {
        let running = try start(minutes: 25)
        #expect(running.nextDeadline == running.plannedEnd)

        clock.advance(minutes: 10)
        let shortBreak = try FocusEngine.handle(.startBreak(duration: 5 * 60), session: running, at: clock.now).session
        #expect(shortBreak?.nextDeadline == clock.minutes(from: clock.now, 5))

        let longBreak = try FocusEngine.handle(.startBreak(duration: 60 * 60), session: running, at: clock.now).session
        #expect(longBreak?.nextDeadline == running.plannedEnd)

        let ended = try FocusEngine.handle(.complete, session: running, at: clock.now).session
        #expect(ended?.nextDeadline == nil)
    }

    @Test mutating func endingABreakThatAlreadyRanOutSucceedsWithTheBreaksOwnEnd() throws {
        let running = try start(minutes: 50)
        let onBreak = try #require(FocusEngine.handle(.startBreak(duration: 5 * 60), session: running, at: clock.now).session)
        clock.advance(minutes: 7)

        let transition = try FocusEngine.handle(.endBreak, session: onBreak, at: clock.now)

        let resumed = try #require(transition.session)
        #expect(resumed.phase == .running)
        #expect(transition.effects == [
            .persist(resumed),
            .publishPolicy(SessionPolicy(sessionID: running.id, mode: .normal, end: running.plannedEnd)),
            .notify(.breakEnded),
        ])
    }

    @Test(arguments: [25.0, 40.0])
    mutating func completingAtOrAfterThePlannedEndRecordsThePlannedEnd(minutesLater: Double) throws {
        let running = try start(minutes: 25)
        clock.advance(minutes: minutesLater)

        let transition = try FocusEngine.handle(.complete, session: running, at: clock.now)

        let ended = try #require(transition.session)
        #expect(ended.phase == .ended(at: running.plannedEnd, reason: .reachedPlannedEnd))
        #expect(transition.effects == [.persist(ended), .publishPolicy(nil), .notify(.sessionReachedPlannedEnd)])
    }

    @Test mutating func completingASessionThatAlreadyEndedIsRejected() throws {
        let running = try start(minutes: 25)
        let ended = try FocusEngine.handle(.complete, session: running, at: clock.now).session

        #expect(throws: FocusEngineError.noActiveSession) {
            try FocusEngine.handle(.complete, session: ended, at: clock.now)
        }
    }
}

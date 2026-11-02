import Foundation
import Testing
@testable import FocusPilotCore

/// Owner decision 2026-10-14: strict sessions keep session rules through pauses
/// and breaks; normal sessions lift them until the session runs again.
@Suite("FocusEngine policy")
struct FocusEnginePolicyTests {
    var clock = FakeClock()

    func start(_ mode: SessionMode) throws -> FocusSession {
        let request = SessionRequest(id: UUID(), taskID: 7, action: "Outline the essay", mode: mode, duration: 50 * 60)
        return try #require(FocusEngine.handle(.start(request), session: nil, at: clock.now).session)
    }

    func publishedPolicy(_ transition: FocusTransition) -> SessionPolicy?? {
        for case .publishPolicy(let policy) in transition.effects { return policy }
        return nil
    }

    @Test(arguments: [FocusEvent.pause, .startBreak(duration: 5 * 60)])
    mutating func strictSessionsKeepBlockingWhileInterrupted(by interruption: FocusEvent) throws {
        let running = try start(.strict)
        clock.advance(minutes: 10)

        let interrupted = try FocusEngine.handle(interruption, session: running, at: clock.now)

        // A break moves the end later by its length as it starts; a pause
        // only when it ends.
        let end = interruption == .pause ? running.plannedEnd : clock.minutes(from: running.plannedEnd, 5)
        #expect(publishedPolicy(interrupted) == .some(SessionPolicy(sessionID: running.id, mode: .strict, end: end)))
    }

    @Test mutating func normalSessionsLiftSessionRulesWhilePaused() throws {
        let running = try start(.normal)
        clock.advance(minutes: 10)

        let paused = try FocusEngine.handle(.pause, session: running, at: clock.now)

        #expect(publishedPolicy(paused) == .some(nil))
    }

    /// The break end travels with the policy so extensions resume blocking on
    /// their own if the app crashes mid-break.
    @Test mutating func normalBreaksPublishWhenBlockingResumes() throws {
        let running = try start(.normal)
        clock.advance(minutes: 10)

        let onBreak = try FocusEngine.handle(.startBreak(duration: 5 * 60), session: running, at: clock.now)

        let breakEnd = clock.minutes(from: clock.now, 5)
        #expect(publishedPolicy(onBreak) == .some(SessionPolicy(
            sessionID: running.id, mode: .normal, end: clock.minutes(from: running.plannedEnd, 5), resumesAt: breakEnd
        )))
    }

    @Test(arguments: [SessionMode.normal, .strict])
    mutating func resumingPublishesTheSessionRulesWithAnEndLaterByThePause(mode: SessionMode) throws {
        let running = try start(mode)
        clock.advance(minutes: 10)
        let paused = try FocusEngine.handle(.pause, session: running, at: clock.now).session
        clock.advance(minutes: 15)

        let resumed = try FocusEngine.handle(.resume, session: paused, at: clock.now)

        #expect(publishedPolicy(resumed) == .some(SessionPolicy(sessionID: running.id, mode: mode,
                                                                end: clock.minutes(from: running.plannedEnd, 15))))
    }

    @Test mutating func aStrictBreakThatRunsOutKeepsTheSamePolicy() throws {
        let running = try start(.strict)
        let onBreak = try FocusEngine.handle(.startBreak(duration: 5 * 60), session: running, at: clock.now).session
        clock.advance(minutes: 6)

        let transition = try FocusEngine.handle(.reconcile, session: onBreak, at: clock.now)

        #expect(publishedPolicy(transition) == .some(SessionPolicy(sessionID: running.id, mode: .strict,
                                                                   end: clock.minutes(from: running.plannedEnd, 5))))
        #expect(transition.effects.last == .notify(.breakEnded))
    }
}

import Foundation
import Testing
@testable import FocusPilotCore

@Suite("FocusEngine lifecycle")
struct FocusEngineLifecycleTests {
    var clock = FakeClock()
    let sessionID = UUID()

    func startRequest(mode: SessionMode = .normal, minutes: Double = 25) -> SessionRequest {
        SessionRequest(id: sessionID, taskID: 7, action: "Outline the essay", mode: mode, duration: minutes * 60)
    }

    @Test func startingRunsASessionUntilAnAbsolutePlannedEnd() throws {
        let transition = try FocusEngine.handle(.start(startRequest(minutes: 25)), session: nil, at: clock.now)

        let expected = FocusSession(
            id: sessionID, taskID: 7, action: "Outline the essay", mode: .normal,
            startedAt: clock.now, plannedEnd: clock.minutes(from: clock.now, 25), phase: .running
        )
        #expect(transition.session == expected)
        #expect(transition.effects == [
            .persist(expected),
            .publishPolicy(SessionPolicy(sessionID: sessionID, mode: .normal, end: expected.plannedEnd)),
        ])
    }

    @Test mutating func pausingLiftsSessionRulesAndResumingRestoresThemWithAnEndLaterByThePause() throws {
        let started = try FocusEngine.handle(.start(startRequest(minutes: 25)), session: nil, at: clock.now).session
        clock.advance(minutes: 5)

        let paused = try FocusEngine.handle(.pause, session: started, at: clock.now)
        #expect(paused.session?.phase == .paused(since: clock.now))
        #expect(paused.effects == [.persist(paused.session!), .publishPolicy(nil)])

        clock.advance(minutes: 3)
        let resumed = try FocusEngine.handle(.resume, session: paused.session, at: clock.now)
        #expect(resumed.session?.phase == .running)
        let later = clock.minutes(from: started!.plannedEnd, 3)
        #expect(resumed.session?.plannedEnd == later)
        #expect(resumed.effects == [
            .persist(resumed.session!),
            .publishPolicy(SessionPolicy(sessionID: sessionID, mode: .normal, end: later)),
        ])
    }

    @Test(arguments: [FocusEvent.pause, .startBreak(duration: 300)])
    mutating func completingEndsTheSessionNowAndClearsSessionRules(from before: FocusEvent) throws {
        let started = try FocusEngine.handle(.start(startRequest()), session: nil, at: clock.now).session
        clock.advance(minutes: 10)
        let interrupted = try FocusEngine.handle(before, session: started, at: clock.now).session
        clock.advance(minutes: 2)

        let completed = try FocusEngine.handle(.complete, session: interrupted, at: clock.now)

        #expect(completed.session?.phase == .ended(at: clock.now, reason: .completed))
        #expect(completed.effects == [.persist(completed.session!), .publishPolicy(nil)])
    }

    @Test func eventsWithoutASessionAreRejected() {
        for event in [FocusEvent.pause, .resume, .startBreak(duration: 300), .endBreak, .complete] {
            #expect(throws: FocusEngineError.noActiveSession) {
                try FocusEngine.handle(event, session: nil, at: clock.now)
            }
        }
    }

    @Test func startingWhileASessionIsActiveIsRejected() throws {
        let running = try FocusEngine.handle(.start(startRequest()), session: nil, at: clock.now).session

        #expect(throws: FocusEngineError.sessionAlreadyActive) {
            try FocusEngine.handle(.start(startRequest()), session: running, at: clock.now)
        }
    }

    @Test func startingAfterTheLastSessionEndedIsAllowed() throws {
        let running = try FocusEngine.handle(.start(startRequest()), session: nil, at: clock.now).session
        let ended = try FocusEngine.handle(.complete, session: running, at: clock.now).session

        let next = try FocusEngine.handle(.start(startRequest()), session: ended, at: clock.now)

        #expect(next.session?.phase == .running)
    }

    @Test func aSessionNeedsAPositiveDuration() {
        #expect(throws: FocusEngineError.nonPositiveDuration) {
            try FocusEngine.handle(.start(startRequest(minutes: 0)), session: nil, at: clock.now)
        }
    }

    @Test func eventsThatDoNotFitThePhaseAreRejected() throws {
        let running = try FocusEngine.handle(.start(startRequest()), session: nil, at: clock.now).session
        let paused = try FocusEngine.handle(.pause, session: running, at: clock.now).session

        #expect(throws: FocusEngineError.notAllowed(.resume, in: .running)) {
            try FocusEngine.handle(.resume, session: running, at: clock.now)
        }
        #expect(throws: FocusEngineError.notAllowed(.endBreak, in: .running)) {
            try FocusEngine.handle(.endBreak, session: running, at: clock.now)
        }
        #expect(throws: FocusEngineError.notAllowed(.startBreak(duration: 300), in: paused!.phase)) {
            try FocusEngine.handle(.startBreak(duration: 300), session: paused, at: clock.now)
        }
    }
}

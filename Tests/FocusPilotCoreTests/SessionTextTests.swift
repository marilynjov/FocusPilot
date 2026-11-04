import Foundation
import Testing
@testable import FocusPilotCore

@Suite("SessionText")
struct SessionTextTests {
    private let start = wednesdayMorningInBogota

    private func session(_ phase: SessionPhase, mode: SessionMode = .normal, minutes: Double = 25) -> FocusSession {
        FocusSession(id: UUID(), taskID: 1, action: "Explain baseline results", mode: mode,
                     startedAt: start, plannedEnd: start.addingTimeInterval(minutes * 60), phase: phase)
    }

    @Test func phasesHaveShortLabels() {
        #expect(SessionText(session(.running)).phase == "Focusing")
        #expect(SessionText(session(.paused(since: start))).phase == "Paused")
        #expect(SessionText(session(.onBreak(until: start))).phase == "On a break")
        #expect(SessionText(session(.ended(at: start, reason: .completed))).phase == "Ended")
    }

    @Test func timeLeftStandsStillWhilePaused() {
        let paused = SessionText(session(.paused(since: start.addingTimeInterval(52))))

        #expect(paused.timeLeft(at: start.addingTimeInterval(52)) == "24:08")
        #expect(paused.timeLeft(at: start.addingTimeInterval(40 * 60)) == "24:08")
    }

    @Test func reducedMotionShowsWholeMinutesLeft() {
        let text = SessionText(session(.running))

        #expect(text.minutesLeft(at: start.addingTimeInterval(52)) == "25 min left")
        #expect(text.minutesLeft(at: start.addingTimeInterval(24 * 60 + 30)) == "1 min left")
        #expect(text.minutesLeft(at: start.addingTimeInterval(25 * 60)) == "0 min left")
    }

    @Test func plannedEndIsShownInTheMacZone() {
        #expect(SessionText.endsAt(start.addingTimeInterval(50 * 60), from: start, timeZone: bogota, clock: .twentyFourHour)
            == "Ends at 10:50 · Bogotá")
        #expect(SessionText.endsAt(start.addingTimeInterval(14 * 3600), from: start, timeZone: bogota, clock: .twentyFourHour)
            == "Ends tomorrow at 00:00 · Bogotá")
        #expect(SessionText.endsAt(start.addingTimeInterval(50 * 60), from: start, timeZone: bogota, clock: .twelveHour)
            == "Ends at 10:50 AM · Bogotá")
    }

    @Test func earlyEndCountdownSaysWhenEndingIsPossible() {
        let availableAt = start.addingTimeInterval(60)

        #expect(SessionText.earlyEnd(availableAt: availableAt, now: start.addingTimeInterval(18)) == "You can end it in 0:42")
        #expect(SessionText.earlyEnd(availableAt: availableAt, now: availableAt) == "You can end it now")
    }
}

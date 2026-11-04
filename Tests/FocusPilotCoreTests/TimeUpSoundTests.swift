import Foundation
import Testing
@testable import FocusPilotCore

/// The sound for time running out (owner request, 2026-11-03): once per
/// event, read from two snapshots in a row, and never for stale ends.
@Suite("Time-up sound")
struct TimeUpSoundTests {
    private let id = UUID()
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func minutes(_ m: Double) -> Date { start.addingTimeInterval(m * 60) }

    private func session(_ phase: SessionPhase, end: Double = 25, id: UUID? = nil) -> FocusSnapshot {
        FocusSnapshot(session: FocusSession(id: id ?? self.id, taskID: 7, action: "Outline the essay", mode: .normal,
                                            startedAt: start, plannedEnd: minutes(end), phase: phase))
    }

    private func timer(_ notified: QuickTimer.Notified, id: Int64 = 1, outcome: QuickTimer.Outcome? = nil) -> FocusSnapshot {
        FocusSnapshot(quickTimer: QuickTimer(id: id, label: nil, startedAt: start, plannedEnd: minutes(20),
                                             endedAt: outcome == nil ? nil : minutes(80), outcome: outcome,
                                             notified: notified))
    }

    @Test func reachingThePlannedEndSoundsOnce() {
        let ended = session(.ended(at: minutes(25), reason: .reachedPlannedEnd))

        #expect(TimeUpSound.due(from: session(.running), to: ended, at: minutes(25)) == .up)
        // The next snapshot shows the same end: no second sound.
        #expect(TimeUpSound.due(from: ended, to: ended, at: minutes(25.1)) == nil)
        // Completing is the owner's own doing.
        let completed = session(.ended(at: minutes(20), reason: .completed))
        #expect(TimeUpSound.due(from: session(.running), to: completed, at: minutes(20)) == nil)
    }

    @Test func anEndLongAgoIsSilent() {
        // The Mac woke, or the app relaunched, long after the end.
        let ended = session(.ended(at: minutes(25), reason: .reachedPlannedEnd))
        #expect(TimeUpSound.due(from: session(.running), to: ended, at: minutes(90)) == nil)
        // A launch starts from an empty snapshot: nothing to compare.
        #expect(TimeUpSound.due(from: FocusSnapshot(), to: ended, at: minutes(25)) == nil)
    }

    @Test func aPlanBlockTakingOverStillSoundsForTheEnd() {
        let next = session(.running, end: 60, id: UUID())
        #expect(TimeUpSound.due(from: session(.running), to: next, at: minutes(25)) == .up)
        // An owner start after Complete is not an end.
        #expect(TimeUpSound.due(from: session(.running), to: next, at: minutes(20)) == nil)
    }

    @Test func aNewSessionReplacingAnEndedOneIsSilent() {
        // The end already sounded; the next session starting is not an end.
        let ended = session(.ended(at: minutes(25), reason: .reachedPlannedEnd))
        let next = session(.running, end: 60, id: UUID())
        #expect(TimeUpSound.due(from: ended, to: next, at: minutes(25.5)) == nil)
        // Nor after Complete, nor from no session at all.
        let completed = session(.ended(at: minutes(20), reason: .completed))
        #expect(TimeUpSound.due(from: completed, to: next, at: minutes(20)) == nil)
        #expect(TimeUpSound.due(from: FocusSnapshot(), to: next, at: minutes(20)) == nil)
    }

    @Test func aBreakThatRunsOutSoundsButBackToTaskDoesNot() {
        let onBreak = session(.onBreak(until: minutes(15), movesEnd: true), end: 30)
        #expect(TimeUpSound.due(from: onBreak, to: session(.running, end: 30), at: minutes(15)) == .up)
        #expect(TimeUpSound.due(from: onBreak, to: session(.running, end: 28), at: minutes(13)) == nil)
        let planBreak = session(.onBreak(until: minutes(15)))
        #expect(TimeUpSound.due(from: planBreak, to: session(.running), at: minutes(15.2)) == .up)
    }

    @Test func aQuickTimerSoundsSoftlyAtTwoMinutesAndThenWhenUp() {
        #expect(TimeUpSound.due(from: timer(.none), to: timer(.almostUp), at: minutes(18)) == .soon)
        #expect(TimeUpSound.due(from: timer(.almostUp), to: timer(.almostUp), at: minutes(19)) == nil)
        #expect(TimeUpSound.due(from: timer(.almostUp), to: timer(.up), at: minutes(20)) == .up)
        // Late, or closed unattended, it is silent; so is another timer.
        #expect(TimeUpSound.due(from: timer(.almostUp), to: timer(.up), at: minutes(25)) == nil)
        #expect(TimeUpSound.due(from: timer(.almostUp), to: timer(.up, outcome: .expired), at: minutes(20)) == nil)
        #expect(TimeUpSound.due(from: timer(.none, id: 2), to: timer(.almostUp), at: minutes(18)) == nil)
    }

    @Test func theLouderSoundWinsWhenTwoAreDue() {
        var old = session(.running)
        old.quickTimer = timer(.none).quickTimer
        var new = session(.ended(at: minutes(25), reason: .reachedPlannedEnd))
        new.quickTimer = timer(.almostUp).quickTimer
        #expect(TimeUpSound.due(from: old, to: new, at: minutes(25)) == .up)
    }
}

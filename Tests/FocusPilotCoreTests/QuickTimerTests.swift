import Foundation
import GRDB
import Testing
@testable import FocusPilotCore

@Suite("Quick timer")
struct QuickTimerTests {
    private func timer(minutes: Double, notified: QuickTimer.Notified = .none) -> QuickTimer {
        QuickTimer(id: 1, label: nil, startedAt: wednesdayMorningInBogota,
                   plannedEnd: wednesdayMorningInBogota.addingTimeInterval(minutes * 60), notified: notified)
    }

    private func at(minutes: Double) -> Date {
        wednesdayMorningInBogota.addingTimeInterval(minutes * 60)
    }

    // MARK: The timer on its own

    @Test func deadlinesAreTwoMinutesLeftThenTheEndThenTheUnattendedClose() {
        #expect(timer(minutes: 20).nextDeadline == at(minutes: 18))
        #expect(timer(minutes: 20, notified: .almostUp).nextDeadline == at(minutes: 20))
        #expect(timer(minutes: 20, notified: .up).nextDeadline == at(minutes: 80))
    }

    @Test func aTimerOfTwoMinutesOrLessHasNoWarning() {
        let short = timer(minutes: 2)

        #expect(short.nextDeadline == at(minutes: 2))
        #expect(short.reconciled(at: at(minutes: 1)).1.isEmpty)
    }

    @Test func eachNoticeComesOnce() {
        let (warned, first) = timer(minutes: 20).reconciled(at: at(minutes: 18))
        #expect(first == [.quickTimerAlmostUp(label: nil)])
        #expect(warned.reconciled(at: at(minutes: 19)).1.isEmpty)

        let (up, second) = warned.reconciled(at: at(minutes: 20))
        #expect(second == [.quickTimerUp(label: nil)])
        #expect(up.isRunning)
        #expect(up.reconciled(at: at(minutes: 30)).1.isEmpty)
    }

    @Test func afterSleepingPastTheEndOnlyTheEndIsAnnounced() {
        let (up, notices) = timer(minutes: 20).reconciled(at: at(minutes: 25))

        #expect(notices == [.quickTimerUp(label: nil)])
        #expect(up.notified == .up)
        #expect(up.isRunning)
    }

    @Test func aTimerNobodyFinishesIsClosedAnHourAfterItsEnd() {
        let (closed, _) = timer(minutes: 20, notified: .up).reconciled(at: at(minutes: 200))

        #expect(closed.outcome == .expired)
        #expect(closed.endedAt == at(minutes: 80))
        #expect(closed.actualLength == nil)
        #expect(closed.nextDeadline == nil)
    }

    @Test func closingAnUnattendedTimerAnnouncesNothing() {
        let (closed, notices) = timer(minutes: 20).reconciled(at: at(minutes: 12 * 60))

        #expect(closed.outcome == .expired)
        #expect(notices.isEmpty)
    }

    @Test func labelsAreTrimmedAndEmptyMeansNone() {
        #expect(QuickTimer.cleanLabel("  Reply to Ana \n") == "Reply to Ana")
        #expect(QuickTimer.cleanLabel("   ") == nil)
        #expect(QuickTimer.cleanLabel(nil) == nil)
    }

    @Test func statusReadsTimeLeftThenTimeOver() {
        let twenty = timer(minutes: 20)

        #expect(QuickTimerText.status(twenty, at: at(minutes: 7.5)) == "12:30 left")
        #expect(QuickTimerText.minutesStatus(twenty, at: at(minutes: 7.5)) == "13 min left")
        #expect(QuickTimerText.status(twenty, at: at(minutes: 20)) == "Time’s up")
        #expect(QuickTimerText.status(twenty, at: at(minutes: 23.5)) == "Time’s up · 3 min over")
        #expect(QuickTimerText.planned(twenty) == "20-minute timer")
    }

    @Test func noticesNameTheLabel() throws {
        let text = try #require(QuickTimerText.notice(.quickTimerAlmostUp(label: "Reply to Ana")))
        #expect(text.title == "2 minutes left")
        #expect(text.body == "Quick timer: Reply to Ana")
        #expect(QuickTimerText.notice(.quickTimerUp(label: nil))?.body == "Your quick timer has ended.")
        #expect(QuickTimerText.notice(.breakEnded) == nil)
    }

    // MARK: Through the coordinator

    @Test func startingSetsAnAbsoluteEndAndPublishesNoPolicy() async throws {
        let fixture = try await SessionFixture()
        let policiesBefore = await fixture.publisher.published.count

        try await fixture.coordinator.startQuickTimer(minutes: 20, label: " Reply to Ana ")

        let timer = try #require(await fixture.coordinator.snapshot().quickTimer)
        #expect(timer.label == "Reply to Ana")
        #expect(timer.plannedEnd == at(minutes: 20))
        #expect(await fixture.publisher.published.count == policiesBefore)
        #expect(await fixture.coordinator.snapshot().activeSession == nil)
    }

    @Test func oneTimerRunsAtATime() async throws {
        let fixture = try await SessionFixture()
        try await fixture.coordinator.startQuickTimer(minutes: 10, label: nil)

        await #expect(throws: QuickTimerError.alreadyRunning) {
            try await fixture.coordinator.startQuickTimer(minutes: 20, label: nil)
        }
    }

    @Test(arguments: [0, -5, 241])
    func lengthsOutsideTheRangeAreRefused(minutes: Int) async throws {
        let fixture = try await SessionFixture()

        await #expect(throws: QuickTimerError.invalidLength) {
            try await fixture.coordinator.startQuickTimer(minutes: minutes, label: nil)
        }
        #expect(await fixture.coordinator.snapshot().quickTimer == nil)
    }

    @Test func noticesArriveAtTwoMinutesLeftAndAtTheEnd() async throws {
        let fixture = try await SessionFixture()
        try await fixture.coordinator.startQuickTimer(minutes: 10, label: "Inbox")

        fixture.advance(minutes: 7)
        try await fixture.coordinator.reconcileQuickTimer()
        #expect(await fixture.notices.delivered.isEmpty)

        fixture.advance(minutes: 1)
        try await fixture.coordinator.reconcileQuickTimer()
        try await fixture.coordinator.reconcileQuickTimer()
        #expect(await fixture.notices.delivered == [.quickTimerAlmostUp(label: "Inbox")])

        fixture.advance(minutes: 2)
        try await fixture.coordinator.reconcileQuickTimer()
        #expect(await fixture.notices.delivered == [.quickTimerAlmostUp(label: "Inbox"), .quickTimerUp(label: "Inbox")])
        #expect(await fixture.coordinator.snapshot().quickTimer?.isRunning == true)
    }

    @Test func finishingRecordsPlannedAndActualLength() async throws {
        let fixture = try await SessionFixture()
        try await fixture.coordinator.startQuickTimer(minutes: 20, label: nil)
        fixture.advance(minutes: 23)

        try await fixture.coordinator.finishQuickTimer()

        #expect(await fixture.coordinator.snapshot().quickTimer == nil)
        let recorded = try #require(try await fixture.coordinator.repository.quickTimers().first)
        #expect(recorded.outcome == .finished)
        #expect(recorded.plannedLength == 20 * 60)
        #expect(abs(try #require(recorded.actualLength) - 23 * 60) < 0.01) // dates are stored to the millisecond
    }

    @Test func stoppingEarlyRecordsItAsStopped() async throws {
        let fixture = try await SessionFixture()
        try await fixture.coordinator.startQuickTimer(minutes: 30, label: nil)
        fixture.advance(minutes: 4)

        try await fixture.coordinator.stopQuickTimer()

        let recorded = try #require(try await fixture.coordinator.repository.quickTimers().first)
        #expect(recorded.outcome == .stopped)
        #expect(abs(try #require(recorded.actualLength) - 4 * 60) < 0.01) // dates are stored to the millisecond
        await #expect(throws: QuickTimerError.notRunning) { try await fixture.coordinator.stopQuickTimer() }
    }

    @Test func aNewTimerCanStartAfterTheLastEnded() async throws {
        let fixture = try await SessionFixture()
        try await fixture.coordinator.startQuickTimer(minutes: 10, label: "First")
        try await fixture.coordinator.finishQuickTimer()

        try await fixture.coordinator.startQuickTimer(minutes: 45, label: "Second")

        #expect(try await fixture.coordinator.repository.quickTimers().map(\.label) == ["Second", "First"])
    }

    @Test func relaunchingKeepsTheSameEnd() async throws {
        let fixture = try await SessionFixture()
        try await fixture.coordinator.startQuickTimer(minutes: 20, label: nil)
        fixture.advance(minutes: 5)

        let relaunched = try fixture.relaunched()
        try await relaunched.launch()

        let timer = try #require(await relaunched.snapshot().quickTimer)
        #expect(timer.remaining(at: fixture.clock.now) == 15 * 60)
        #expect(await fixture.notices.delivered.isEmpty)
    }

    @Test func relaunchingAfterTheEndAnnouncesItOnce() async throws {
        let fixture = try await SessionFixture()
        try await fixture.coordinator.startQuickTimer(minutes: 10, label: nil)
        fixture.advance(minutes: 12)

        try await fixture.relaunched().launch()
        try await fixture.relaunched().launch()

        #expect(await fixture.notices.delivered == [.quickTimerUp(label: nil)])
    }

    @Test func aTimerForgottenOvernightIsClosedAsExpired() async throws {
        let fixture = try await SessionFixture()
        try await fixture.coordinator.startQuickTimer(minutes: 20, label: nil)
        fixture.advance(minutes: 12 * 60)

        let relaunched = try fixture.relaunched()
        try await relaunched.launch()

        #expect(await relaunched.snapshot().quickTimer == nil)
        let recorded = try #require(try await relaunched.repository.quickTimers().first)
        #expect(recorded.outcome == .expired)
        #expect(recorded.endedAt == at(minutes: 80))
        #expect(recorded.actualLength == nil)
        #expect(await fixture.notices.delivered.isEmpty)
    }

    @Test func finishingPastTheUnattendedLimitKeepsItExpired() async throws {
        let fixture = try await SessionFixture()
        try await fixture.coordinator.startQuickTimer(minutes: 20, label: nil)
        fixture.advance(minutes: 5 * 60)

        try await fixture.coordinator.finishQuickTimer()

        let recorded = try #require(try await fixture.coordinator.repository.quickTimers().first)
        #expect(recorded.outcome == .expired)
    }

    @Test func clearingCachesKeepsTimers() async throws {
        let fixture = try await SessionFixture()
        try await fixture.coordinator.startQuickTimer(minutes: 20, label: "Kept")
        try await fixture.coordinator.finishQuickTimer()

        try await fixture.coordinator.repository.clearCaches()

        #expect(try await TaskRepository(location: fixture.location).quickTimers().map(\.label) == ["Kept"])
    }

    @Test func stoppingThenStartingAgainGivesTheNewTimerItsOwnNotices() async throws {
        let fixture = try await SessionFixture()
        try await fixture.coordinator.startQuickTimer(minutes: 10, label: "First")
        fixture.advance(minutes: 8)
        try await fixture.coordinator.reconcileQuickTimer()
        try await fixture.coordinator.stopQuickTimer()

        try await fixture.coordinator.startQuickTimer(minutes: 10, label: "Second")
        fixture.advance(minutes: 8)
        try await fixture.coordinator.reconcileQuickTimer()

        #expect(await fixture.notices.delivered == [.quickTimerAlmostUp(label: "First"), .quickTimerAlmostUp(label: "Second")])
    }

    @Test func aClockSetBackNeverRecordsANegativeLength() async throws {
        let fixture = try await SessionFixture()
        try await fixture.coordinator.startQuickTimer(minutes: 20, label: nil)
        fixture.clock.set(at(minutes: -30))

        try await fixture.coordinator.finishQuickTimer()

        let recorded = try #require(try await fixture.coordinator.repository.quickTimers().first)
        #expect(try #require(recorded.actualLength) >= 0)
    }

    @Test func concurrentReconcilesDeliverEachNoticeOnce() async throws {
        let fixture = try await SessionFixture()
        try await fixture.coordinator.startQuickTimer(minutes: 10, label: nil)
        fixture.advance(minutes: 10)

        async let first: Void = fixture.coordinator.reconcileQuickTimer()
        async let second: Void = fixture.coordinator.reconcileQuickTimer()
        async let third: Void = fixture.coordinator.reconcileQuickTimer()
        _ = try await (first, second, third)

        #expect(await fixture.notices.delivered == [.quickTimerUp(label: nil)])
    }

    @Test func theDatabaseHoldsOneRunningTimerAndAnOutcomeOnlyWithAnEnd() async throws {
        let fixture = try await SessionFixture()
        try await fixture.coordinator.startQuickTimer(minutes: 10, label: nil)
        let database = try DatabaseQueue(path: fixture.location.ownerDatabaseURL.path)

        #expect(throws: DatabaseError.self) {
            try database.write { db in
                try db.execute(sql: "INSERT INTO quickTimer (startedAt, plannedEnd) VALUES ('2026-10-14 15:00:00.000', '2026-10-14 15:10:00.000')")
            }
        }
        #expect(throws: DatabaseError.self) {
            try database.write { db in
                try db.execute(sql: "UPDATE quickTimer SET outcome = 'finished'")
            }
        }
        #expect(throws: DatabaseError.self) {
            try database.write { db in
                try db.execute(sql: "INSERT INTO quickTimer (startedAt, plannedEnd, endedAt, outcome) VALUES ('2026-10-14 15:00:00.000', '2026-10-14 15:10:00.000', '2026-10-14 15:05:00.000', 'paused')")
            }
        }
    }

    @Test func aTimerRunsAlongsideAFocusSessionWithoutTouchingIt() async throws {
        let fixture = try await SessionFixture()
        try await fixture.coordinator.startSession(duration: 50 * 60, mode: .normal)
        let policies = await fixture.publisher.published

        try await fixture.coordinator.startQuickTimer(minutes: 10, label: nil)
        fixture.advance(minutes: 10)
        try await fixture.coordinator.reconcileQuickTimer()
        try await fixture.coordinator.finishQuickTimer()

        #expect(await fixture.publisher.published == policies)
        #expect(await fixture.coordinator.snapshot().activeSession != nil)
    }
}

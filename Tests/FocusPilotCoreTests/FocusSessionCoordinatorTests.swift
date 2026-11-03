import Foundation
import GRDB
import Testing
@testable import FocusPilotCore

@Suite("Focus sessions through the coordinator")
struct FocusSessionCoordinatorTests {
    @Test func startingNeedsAPinnedNowTask() async throws {
        let coordinator = FocusCoordinator(repository: try TaskRepository(location: StorageLocation(directory: makeTemporaryDirectory())))

        await #expect(throws: FocusCoordinator.SessionError.noCurrentTask) {
            try await coordinator.startSession(duration: 25 * 60, mode: .normal)
        }
    }

    @Test func startingRunsTheNowTaskAndPublishesAWrappedPolicy() async throws {
        let fixture = try await SessionFixture()

        try await fixture.coordinator.startSession(duration: 50 * 60, mode: .normal)

        let session = try #require(await fixture.coordinator.snapshot().activeSession)
        #expect(session.action == "Explain baseline results")
        #expect(session.plannedEnd == wednesdayMorningInBogota.addingTimeInterval(50 * 60))
        let policy = try #require(await fixture.publisher.published.last)
        #expect(policy.schemaVersion == CompiledPolicy.currentSchemaVersion)
        #expect(policy.revision == 1)
        #expect(policy.effectiveAt == wednesdayMorningInBogota)
        #expect(policy.session?.end == session.plannedEnd)
    }

    @Test func pausingKeepsThePlannedEndAndLiftsNormalRules() async throws {
        let fixture = try await SessionFixture()
        try await fixture.coordinator.startSession(duration: 25 * 60, mode: .normal)
        fixture.advance(minutes: 5)

        try await fixture.coordinator.pause()

        let session = try #require(await fixture.coordinator.snapshot().activeSession)
        #expect(session.plannedEnd == wednesdayMorningInBogota.addingTimeInterval(25 * 60))
        #expect(await fixture.publisher.published.last?.session == nil)
        try await fixture.coordinator.resume()
        #expect(await fixture.publisher.published.last?.session != nil)
    }

    @Test func strictPauseKeepsTheRules() async throws {
        let fixture = try await SessionFixture()
        try await fixture.coordinator.startSession(duration: 25 * 60, mode: .strict)

        try await fixture.coordinator.pause()

        #expect(await fixture.publisher.published.last?.session?.mode == .strict)
    }

    @Test func relaunchingMidSessionRestoresTheRemainingTime() async throws {
        let fixture = try await SessionFixture()
        try await fixture.coordinator.startSession(duration: 25 * 60, mode: .normal)
        fixture.advance(minutes: 10)

        let relaunched = try fixture.relaunched()
        try await relaunched.launch()

        let session = try #require(await relaunched.snapshot().activeSession)
        #expect(session.plannedEnd.timeIntervalSince(fixture.clock.now) == 15 * 60)
        #expect(await fixture.publisher.published.map(\.revision) == [1, 2])
    }

    // #15: the mode is chosen at start and stored with the session.
    @Test(arguments: [SessionMode.normal, .strict])
    func relaunchingMidSessionKeepsTheModeChosenAtStart(mode: SessionMode) async throws {
        let fixture = try await SessionFixture()
        try await fixture.coordinator.startSession(duration: 25 * 60, mode: mode)
        fixture.advance(minutes: 10)

        let relaunched = try fixture.relaunched()
        try await relaunched.launch()

        #expect(await relaunched.snapshot().activeSession?.mode == mode)
        #expect(await fixture.publisher.published.last?.session?.mode == mode)
    }

    @Test func relaunchingAfterThePlannedEndRecordsTheEndAndTellsTheOwner() async throws {
        let fixture = try await SessionFixture()
        try await fixture.coordinator.startSession(duration: 25 * 60, mode: .normal)
        fixture.advance(minutes: 90)

        let relaunched = try fixture.relaunched()
        try await relaunched.launch()

        let session = try #require(await relaunched.snapshot().session)
        #expect(session.phase == .ended(at: session.plannedEnd, reason: .reachedPlannedEnd))
        #expect(await relaunched.snapshot().activeSession == nil)
        #expect(await fixture.publisher.published.last?.session == nil)
        #expect(await fixture.notices.delivered == [.sessionReachedPlannedEnd])
    }

    @Test func reconcilingAtThePlannedEndEndsTheSession() async throws {
        let fixture = try await SessionFixture()
        try await fixture.coordinator.startSession(duration: 25 * 60, mode: .normal)
        #expect(await fixture.coordinator.snapshot().nextDeadline == wednesdayMorningInBogota.addingTimeInterval(25 * 60))
        fixture.advance(minutes: 25)

        try await fixture.coordinator.reconcile()

        #expect(await fixture.coordinator.snapshot().activeSession == nil)
        #expect(await fixture.coordinator.snapshot().nextDeadline == nil)
    }

    @Test func completingANormalSessionEndsItRightAway() async throws {
        let fixture = try await SessionFixture()
        try await fixture.coordinator.startSession(duration: 25 * 60, mode: .normal)
        fixture.advance(minutes: 3)

        let result = try await fixture.coordinator.complete()

        #expect(result == .completed)
        #expect(await fixture.coordinator.snapshot().session?.phase == .ended(at: fixture.clock.now, reason: .completed))
    }

    @Test func startingAgainWhileASessionRunsIsRefused() async throws {
        let fixture = try await SessionFixture()
        try await fixture.coordinator.startSession(duration: 25 * 60, mode: .normal)

        await #expect(throws: FocusEngineError.sessionAlreadyActive) {
            try await fixture.coordinator.startSession(duration: 25 * 60, mode: .normal)
        }
    }

    // MARK: +10 min and Keep going (D12)

    @Test func takingABreakStopsTheCountdownAndBackToTaskGivesBackTheRest() async throws {
        let fixture = try await SessionFixture()
        try await fixture.coordinator.startSession(duration: 25 * 60, mode: .normal)
        fixture.advance(minutes: 10)

        try await fixture.coordinator.takeBreak(duration: 10 * 60)

        let onBreak = try #require(await fixture.coordinator.snapshot().activeSession)
        #expect(onBreak.plannedEnd == wednesdayMorningInBogota.addingTimeInterval(35 * 60))
        #expect(await fixture.publisher.published.last?.session?.resumesAt == fixture.clock.now.addingTimeInterval(10 * 60))

        fixture.advance(minutes: 4)
        try await fixture.coordinator.endBreak()

        let back = try #require(await fixture.coordinator.snapshot().activeSession)
        #expect(back.phase == .running)
        #expect(back.plannedEnd == wednesdayMorningInBogota.addingTimeInterval(29 * 60))
    }

    @Test func moreTimeMovesThePlannedEndAndTheNextDeadline() async throws {
        let fixture = try await SessionFixture()
        try await fixture.coordinator.startSession(duration: 25 * 60, mode: .strict)
        fixture.advance(minutes: 20)

        try await fixture.coordinator.extend(by: 10 * 60)

        let later = wednesdayMorningInBogota.addingTimeInterval(35 * 60)
        #expect(await fixture.coordinator.snapshot().activeSession?.plannedEnd == later)
        #expect(await fixture.coordinator.snapshot().nextDeadline == later)
        #expect(await fixture.publisher.published.last?.session?.end == later)
    }

    @Test func keepGoingStartsTheSameTaskInTheSameModeOnceTheSessionEnded() async throws {
        let fixture = try await SessionFixture()
        try await fixture.coordinator.startSession(duration: 25 * 60, mode: .strict)
        let first = try #require(await fixture.coordinator.snapshot().activeSession)

        await #expect(throws: FocusEngineError.sessionAlreadyActive) {
            try await fixture.coordinator.keepGoing(duration: 10 * 60)
        }
        fixture.advance(minutes: 25)
        try await fixture.coordinator.reconcile()
        try await fixture.coordinator.keepGoing(duration: 10 * 60)

        let next = try #require(await fixture.coordinator.snapshot().activeSession)
        #expect(next.id != first.id)
        #expect(next.taskID == first.taskID)
        #expect(next.action == first.action)
        #expect(next.mode == .strict)
        #expect(next.plannedEnd == fixture.clock.now.addingTimeInterval(10 * 60))
    }

    @Test(arguments: ["UPDATE task SET status = 'done' WHERE id = ?", "DELETE FROM task WHERE id = ?"])
    func keepGoingNeedsTheTaskStillOpen(change: String) async throws {
        let fixture = try await SessionFixture()
        try await fixture.coordinator.startSession(duration: 25 * 60, mode: .normal)
        let first = try #require(await fixture.coordinator.snapshot().activeSession)
        fixture.advance(minutes: 25)
        try await fixture.coordinator.reconcile()
        try await DatabaseQueue(path: fixture.location.ownerDatabaseURL.path).write { db in
            try db.execute(sql: change, arguments: [first.taskID])
        }

        await #expect(throws: FocusCoordinator.SessionError.noCurrentTask) {
            try await fixture.coordinator.keepGoing(duration: 10 * 60)
        }
        #expect(await fixture.coordinator.snapshot().activeSession == nil)
    }

    @Test func keepGoingUsesTheTasksCurrentTitle() async throws {
        let fixture = try await SessionFixture()
        try await fixture.coordinator.startSession(duration: 25 * 60, mode: .normal)
        let first = try #require(await fixture.coordinator.snapshot().activeSession)
        fixture.advance(minutes: 25)
        try await fixture.coordinator.reconcile()
        try await DatabaseQueue(path: fixture.location.ownerDatabaseURL.path).write { db in
            try db.execute(sql: "UPDATE task SET title = 'Explain the results' WHERE id = ?", arguments: [first.taskID])
        }

        try await fixture.coordinator.keepGoing(duration: 10 * 60)

        #expect(await fixture.coordinator.snapshot().activeSession?.action == "Explain the results")
    }

    @Test func keepGoingNeedsASessionFirst() async throws {
        let fixture = try await SessionFixture()
        await #expect(throws: FocusCoordinator.SessionError.noCurrentTask) {
            try await fixture.coordinator.keepGoing(duration: 10 * 60)
        }
    }
}

@Suite("Ending a strict session early")
struct StrictEarlyEndTests {
    // Confirmed by the owner on PR #37 (decision 0003).
    @Test func theWaitIsSixtySeconds() {
        #expect(StrictEarlyEnd.wait == 60)
    }

    // Review of PR #37: every way of completing, the Task menu included,
    // goes through the owner's confirmation first.
    @Test func completingEarlyFirstAsksForConfirmationAndChangesNothing() async throws {
        let fixture = try await SessionFixture()
        try await fixture.coordinator.startSession(duration: 25 * 60, mode: .strict)
        fixture.advance(minutes: 5)

        #expect(try await fixture.coordinator.complete() == .needsConfirmation)
        #expect(await fixture.coordinator.snapshot().activeSession != nil)
        #expect(await fixture.coordinator.snapshot().earlyEndAvailableAt == nil)
    }

    @Test func confirmingStartsTheWaitAndKeepsTheSessionRunning() async throws {
        let fixture = try await SessionFixture()
        try await fixture.coordinator.startSession(duration: 25 * 60, mode: .strict)
        fixture.advance(minutes: 5)
        let requestedAt = fixture.clock.now

        let first = try await fixture.coordinator.complete(confirmed: true)

        #expect(first == .waitUntil(requestedAt.addingTimeInterval(StrictEarlyEnd.wait)))
        #expect(await fixture.coordinator.snapshot().activeSession != nil)
        #expect(await fixture.coordinator.snapshot().earlyEndAvailableAt == requestedAt.addingTimeInterval(StrictEarlyEnd.wait))
        fixture.advance(minutes: 0.5)
        #expect(try await fixture.coordinator.complete() == .waitUntil(requestedAt.addingTimeInterval(StrictEarlyEnd.wait)))
    }

    @Test func completingAfterTheWaitEndsTheSession() async throws {
        let fixture = try await SessionFixture()
        try await fixture.coordinator.startSession(duration: 25 * 60, mode: .strict)
        _ = try await fixture.coordinator.complete(confirmed: true)
        fixture.advance(minutes: 1)

        #expect(try await fixture.coordinator.complete() == .completed)
        #expect(await fixture.coordinator.snapshot().activeSession == nil)
        #expect(await fixture.coordinator.snapshot().earlyEndAvailableAt == nil)
    }

    // Review of PR #37: the wait is measured on a monotonic clock.
    @Test func movingTheWallClockForwardDoesNotSkipTheWait() async throws {
        let fixture = try await SessionFixture()
        try await fixture.coordinator.startSession(duration: 25 * 60, mode: .strict)
        _ = try await fixture.coordinator.complete(confirmed: true)
        fixture.advance(seconds: 10)
        fixture.clock.set(fixture.clock.now.addingTimeInterval(5 * 60))

        #expect(try await fixture.coordinator.complete() == .waitUntil(fixture.clock.now.addingTimeInterval(50)))
        #expect(await fixture.coordinator.snapshot().earlyEndAvailableAt == fixture.clock.now.addingTimeInterval(50))
    }

    @Test func cancellingTheEarlyEndStartsOverWithConfirmation() async throws {
        let fixture = try await SessionFixture()
        try await fixture.coordinator.startSession(duration: 25 * 60, mode: .strict)
        _ = try await fixture.coordinator.complete(confirmed: true)
        fixture.advance(minutes: 1)

        await fixture.coordinator.cancelEarlyEnd()

        #expect(await fixture.coordinator.snapshot().earlyEndAvailableAt == nil)
        #expect(try await fixture.coordinator.complete() == .needsConfirmation)
        #expect(try await fixture.coordinator.complete(confirmed: true) == .waitUntil(fixture.clock.now.addingTimeInterval(StrictEarlyEnd.wait)))
    }

    @Test func aStrictSessionPastItsPlannedEndCompletesWithoutWaiting() async throws {
        let fixture = try await SessionFixture()
        try await fixture.coordinator.startSession(duration: 25 * 60, mode: .strict)
        fixture.advance(minutes: 26)

        #expect(try await fixture.coordinator.complete() == .completed)
    }
}

@Suite("Snapshot stream")
struct SnapshotStreamTests {
    @Test func subscribersSeeSessionAndNowChanges() async throws {
        let fixture = try await SessionFixture()
        let stream = await fixture.coordinator.snapshots()
        var iterator = stream.makeAsyncIterator()

        #expect(await iterator.next()?.currentTaskTitle == "Explain baseline results")
        try await fixture.coordinator.startSession(duration: 25 * 60, mode: .normal)
        #expect(await iterator.next()?.activeSession != nil)
        try await fixture.coordinator.capture(NewTask(title: "Reply to co-advisor"))
        let next = try await fixture.coordinator.todayTasks().last!.id
        try await fixture.coordinator.moveTask(next, to: .now, .top)
        var latest = await iterator.next()
        while latest?.currentTaskTitle != "Reply to co-advisor" { latest = await iterator.next() }
        #expect(latest?.activeSession != nil)
    }

    // Review of PR #37: the app keeps the newest of streamed and fetched
    // snapshots by comparing revisions.
    @Test func everyChangeGetsAHigherSnapshotRevision() async throws {
        let fixture = try await SessionFixture()
        let before = await fixture.coordinator.snapshot().revision

        #expect(await fixture.coordinator.snapshot().revision == before)
        try await fixture.coordinator.startSession(duration: 25 * 60, mode: .normal)
        let started = await fixture.coordinator.snapshot().revision
        #expect(started > before)
        try await fixture.coordinator.pause()
        #expect(await fixture.coordinator.snapshot().revision > started)
    }
}

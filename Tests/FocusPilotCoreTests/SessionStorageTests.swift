import Foundation
import GRDB
import Testing
@testable import FocusPilotCore

@Suite("Session storage")
struct SessionStorageTests {
    private let location: StorageLocation
    private let repository: TaskRepository

    init() async throws {
        location = StorageLocation(directory: try makeTemporaryDirectory())
        repository = try TaskRepository(location: location)
        // The task `FocusSession.sample` is on; a session needs its task.
        _ = try await repository.addTask(title: "Write the essay")
    }

    private func transition(_ session: FocusSession?, publishes: Int) -> FocusTransition {
        FocusTransition(session: session,
                        effects: (session.map { [.persist($0)] } ?? []) + Array(repeating: .publishPolicy(nil), count: publishes))
    }

    @Test func aRecordedSessionIsTheLatestAfterReopening() async throws {
        let session = FocusSession.sample(phase: .paused(since: FocusSession.sampleStart.addingTimeInterval(60)))

        _ = try await repository.record(transition(session, publishes: 1))

        #expect(try await TaskRepository(location: location).latestSession() == session)
    }

    @Test func recordingTheSameSessionAgainUpdatesIt() async throws {
        var session = FocusSession.sample(phase: .running)
        _ = try await repository.record(transition(session, publishes: 1))
        session.phase = .ended(at: session.plannedEnd, reason: .reachedPlannedEnd)

        _ = try await repository.record(transition(session, publishes: 1))

        #expect(try await repository.latestSession() == session)
    }

    @Test func eachPublishGetsTheNextRevisionEvenAfterReopening() async throws {
        #expect(try await repository.record(transition(nil, publishes: 2)).revisions == [1, 2])

        let reopened = try TaskRepository(location: location)

        #expect(try await reopened.record(transition(FocusSession.sample(phase: .running), publishes: 1)).revisions == [3])
    }

    @Test func aNewerSessionReplacesTheOlderAsLatest() async throws {
        let older = FocusSession.sample(phase: .ended(at: FocusSession.sampleStart.addingTimeInterval(60), reason: .completed))
        var newer = FocusSession.sample(phase: .running)
        newer.startedAt = FocusSession.sampleStart.addingTimeInterval(3600)
        _ = try await repository.record(transition(older, publishes: 0))

        _ = try await repository.record(transition(newer, publishes: 0))

        #expect(try await repository.latestSession() == newer)
    }

    // Review of PR #37: a clock set back must not hide the newest session.
    @Test func theLastStartedSessionIsLatestEvenIfItsClockReadsEarlier() async throws {
        var first = FocusSession.sample(phase: .ended(at: FocusSession.sampleStart.addingTimeInterval(60), reason: .completed))
        first.startedAt = FocusSession.sampleStart.addingTimeInterval(3600)
        var second = FocusSession.sample(phase: .running)
        second.id = UUID()
        _ = try await repository.record(transition(first, publishes: 0))
        _ = try await repository.record(transition(second, publishes: 0))

        _ = try await repository.record(transition(first, publishes: 0))

        #expect(try await repository.latestSession() == second)
    }

    @Test func noSessionBeforeTheFirstOne() async throws {
        #expect(try await repository.latestSession() == nil)
    }

    @Test func sessionsLiveInTheOwnerDatabase() throws {
        let owner = try DatabaseInspection(fileAt: location.ownerDatabaseURL)

        #expect(owner.tables.isSuperset(of: ["focusSession", "policyPublication"]))
    }
}

import Foundation
import Synchronization
@testable import FocusPilotCore

/// Keeps every policy the coordinator publishes, in order.
actor RecordingPolicyPublisher: PolicyPublisher {
    private(set) var deliveries: [PolicyDelivery] = []

    var published: [CompiledPolicy] { deliveries.map(\.policy) }

    func publish(_ delivery: PolicyDelivery) async {
        deliveries.append(delivery)
    }
}

/// Keeps every notice the coordinator delivers, in order.
actor RecordingNoticeSink: FocusNoticeSink {
    private(set) var delivered: [FocusNotice] = []

    func deliver(_ notice: FocusNotice) async {
        delivered.append(notice)
    }
}

/// A coordinator over a fresh database with a pinned Now task, a movable
/// clock and recording publisher and notices.
struct SessionFixture {
    let location: StorageLocation
    let clock: SettableClock
    let uptime = SettableUptime()
    let publisher = RecordingPolicyPublisher()
    let notices = RecordingNoticeSink()
    let coordinator: FocusCoordinator

    init(at start: Date = wednesdayMorningInBogota) async throws {
        location = StorageLocation(directory: try makeTemporaryDirectory())
        clock = SettableClock(start)
        coordinator = try Self.coordinator(at: location, clock: clock, uptime: uptime, publisher: publisher, notices: notices)
        try await coordinator.capture(NewTask(title: "Explain baseline results"))
        let id = try await coordinator.todayTasks()[0].id
        try await coordinator.moveTask(id, to: .now, .top)
    }

    /// A second coordinator on the same database, as after quitting and relaunching.
    func relaunched() throws -> FocusCoordinator {
        try Self.coordinator(at: location, clock: clock, uptime: uptime, publisher: publisher, notices: notices)
    }

    /// Lets time pass on both the wall clock and the monotonic clock.
    func advance(minutes: Double) {
        advance(seconds: minutes * 60)
    }

    func advance(seconds: Double) {
        clock.set(clock.now.addingTimeInterval(seconds))
        uptime.advance(seconds)
    }

    private static func coordinator(at location: StorageLocation, clock: SettableClock, uptime: SettableUptime,
                                    publisher: RecordingPolicyPublisher, notices: RecordingNoticeSink) throws -> FocusCoordinator {
        let now: @Sendable () -> Date = { clock.now }
        return FocusCoordinator(repository: try TaskRepository(location: location, now: now),
                                publisher: publisher, notices: notices, now: now,
                                uptime: { uptime.now }, timeZone: { bogota })
    }
}

/// A monotonic clock the test moves; the wall clock can jump without it.
final class SettableUptime: Sendable {
    private let elapsed = Mutex(Duration.zero)

    var now: Duration { elapsed.withLock { $0 } }

    func advance(_ seconds: Double) {
        elapsed.withLock { $0 += .seconds(seconds) }
    }
}

import Foundation
import Testing
@testable import FocusPilotCore

/// Herdr's agents as each test sets them; records every call in order.
final class FakeHerdrAgents: HerdrAgentSource, @unchecked Sendable {
    enum Call: Equatable {
        case list
        case read(String)
        case focus(String)
    }

    private let lock = NSLock()
    private var current: HerdrAgents
    private var recorded: [Call] = []
    var screen: String? = "Ablation table ready: 5 rows.\nSeed 3 underperforms."
    var focusSucceeds = true

    init(_ current: HerdrAgents) { self.current = current }

    func set(_ agents: HerdrAgents) { lock.withLock { current = agents } }
    var calls: [Call] { lock.withLock { recorded } }

    func agents() async -> HerdrAgents {
        lock.withLock {
            recorded.append(.list)
            return current
        }
    }

    func output(of paneID: String, on server: HerdrServer) async -> String? {
        lock.withLock { recorded.append(.read(paneID)) }
        return screen
    }

    func focus(_ paneID: String, on server: HerdrServer) async -> Bool {
        lock.withLock { recorded.append(.focus(paneID)) }
        return focusSucceeds
    }
}

@Suite("Herdr agents through the coordinator")
struct HerdrAgentCoordinatorTests {
    private let repository: TaskRepository
    private let herdr = FakeHerdrAgents(.connected(herdrServer, [agent(.working)]))
    private let coordinator: FocusCoordinator

    init() throws {
        repository = try TaskRepository(location: StorageLocation(directory: makeTemporaryDirectory()))
        coordinator = FocusCoordinator(repository: repository, agents: herdr)
    }

    /// A task with the working agent linked to it.
    private func linkedTask() async throws -> (task: Int64, link: TaskAgentLink) {
        let task = try await repository.addTask(NewTask(title: "Explain baseline results")).id!
        let link = try await coordinator.linkAgent(agent(.working), on: herdrServer, workspaceLabel: "NLP report",
                                                   toTask: task)
        return (task, link)
    }

    @Test func withoutLinkedAgentsHerdrsAgentsAreNotPolled() async {
        #expect(await coordinator.refreshHerdrAgents() == nil)
        #expect(herdr.calls.isEmpty)
    }

    @Test func pollingQueuesTheResultWithItsOutput() async throws {
        _ = try await linkedTask()
        herdr.set(.connected(herdrServer, [agent(.done)]))

        #expect(await coordinator.refreshHerdrAgents() == .connected(herdrServer, [agent(.done)]))

        #expect(herdr.calls == [.list, .read("w4:p2")])
        let item = try #require(try await coordinator.reviewQueue().first)
        #expect(item.output?.lines == ["Ablation table ready: 5 rows.", "Seed 3 underperforms."])
    }

    @Test func linkingAnAgentAlreadyWaitingQueuesItsApprovalWithItsScreen() async throws {
        let task = try await repository.addTask(NewTask(title: "Explain baseline results")).id!
        _ = try await coordinator.linkAgent(agent(.blocked), on: herdrServer, workspaceLabel: nil, toTask: task)

        #expect(herdr.calls == [.read("w4:p2")])
        let item = try #require(try await coordinator.reviewQueue().first)
        #expect(item.kind == .approval)
        #expect(item.output?.lines.first == "Ablation table ready: 5 rows.")
    }

    @Test func pollingNeverFocusesWhateverHappens() async throws {
        _ = try await linkedTask()
        for status in [HerdrAgentStatus.blocked, .working, .done, .unknown, .idle, .working, .idle] {
            herdr.set(.connected(herdrServer, [agent(status)]))
            _ = await coordinator.refreshHerdrAgents()
        }
        #expect(!herdr.calls.contains { if case .focus = $0 { true } else { false } })
    }

    @Test func pollingWhileUnchangedReadsNothing() async throws {
        _ = try await linkedTask()
        _ = await coordinator.refreshHerdrAgents()
        _ = await coordinator.refreshHerdrAgents()
        #expect(herdr.calls == [.list, .list])
    }

    @Test func anUnreadableScreenStillQueuesTheResult() async throws {
        _ = try await linkedTask()
        herdr.screen = nil
        herdr.set(.connected(herdrServer, [agent(.idle)]))
        _ = await coordinator.refreshHerdrAgents()
        #expect(try await coordinator.reviewQueue().first?.output == nil)
        #expect(try await coordinator.reviewQueue().count == 1)
    }

    @Test func openAgentFocusesTheLinkedPane() async throws {
        let (_, link) = try await linkedTask()

        #expect(await coordinator.openAgent(link.id) == .opened)
        #expect(herdr.calls.last == .focus("w4:p2"))
    }

    @Test func openAgentRecordsAFinishedRunBeforeFocusClearsIt() async throws {
        // Focus turns Herdr's done into idle, so the result is queued first.
        let (_, link) = try await linkedTask()
        herdr.set(.connected(herdrServer, [agent(.done)]))

        #expect(await coordinator.openAgent(link.id) == .opened)

        #expect(herdr.calls == [.list, .read("w4:p2"), .focus("w4:p2")])
        #expect(try await coordinator.reviewQueue().map(\.kind) == [.finished])
    }

    @Test func openAgentRefusesAPaneThatNowHoldsAnotherAgent() async throws {
        let (_, link) = try await linkedTask()
        herdr.set(.connected(herdrServer, [agent(.idle, kind: "codex")]))
        #expect(await coordinator.openAgent(link.id) == .replaced)
        #expect(herdr.calls == [.list])
    }

    @Test func openAgentOnARenamedAgentAsksForRelinkAndDoesNotFocus() async throws {
        let (task, link) = try await linkedTask()
        herdr.set(.connected(herdrServer, [agent(.idle, name: "ablation-2")]))

        #expect(await coordinator.openAgent(link.id) == .renamed("ablation-2"))
        #expect(herdr.calls == [.list])

        #expect(await coordinator.relinkAgent(link.id) == true)
        #expect(try await repository.agentLinks(forTask: task).first?.name == "ablation-2")
        #expect(herdr.calls == [.list, .list])
    }

    @Test func relinkDoesNothingUnlessTheAgentWasRenamed() async throws {
        let (_, link) = try await linkedTask()
        herdr.set(.connected(herdrServer, [agent(.idle, kind: "codex")]))
        #expect(await coordinator.relinkAgent(link.id) == false)
    }

    @Test func openAgentRefusesAfterAHerdrRestart() async throws {
        let (_, link) = try await linkedTask()
        herdr.set(.connected(restartedHerdrServer, [agent(.working)]))
        #expect(await coordinator.openAgent(link.id) == .notFound)
        #expect(herdr.calls == [.list])
    }

    @Test func openAgentWithoutHerdrDoesNothing() async throws {
        let (_, link) = try await linkedTask()
        herdr.set(.disconnected(.notRunning))
        #expect(await coordinator.openAgent(link.id) == .herdrUnavailable)
        #expect(herdr.calls == [.list])
    }

    @Test func aFailedFocusIsReported() async throws {
        let (_, link) = try await linkedTask()
        herdr.focusSucceeds = false
        #expect(await coordinator.openAgent(link.id) == .herdrUnavailable)
    }

    @Test func anUnlinkedAgentCannotBeOpened() async throws {
        let (_, link) = try await linkedTask()
        try await coordinator.unlinkAgent(link.id)
        #expect(await coordinator.openAgent(link.id) == .notFound)
        #expect(herdr.calls.isEmpty)
    }

    @Test func resultsNeverChangeNow() async throws {
        let now = try await repository.addTask(NewTask(title: "Write intro")).id!
        try await coordinator.moveTask(now, to: .now, .top)
        _ = try await linkedTask()
        herdr.set(.connected(herdrServer, [agent(.done)]))

        _ = await coordinator.refreshHerdrAgents()

        #expect(await coordinator.snapshot().currentTaskTitle == "Write intro")
    }

    @Test func markingReviewedEmptiesTheQueue() async throws {
        _ = try await linkedTask()
        herdr.set(.connected(herdrServer, [agent(.idle)]))
        _ = await coordinator.refreshHerdrAgents()
        let item = try #require(try await coordinator.reviewQueue().first)

        try await coordinator.markReviewed(item.id)

        #expect(try await coordinator.reviewQueue().isEmpty)
    }

    @Test func openingAnItemKeepsItQueuedAsRead() async throws {
        _ = try await linkedTask()
        herdr.set(.connected(herdrServer, [agent(.idle)]))
        _ = await coordinator.refreshHerdrAgents()
        let item = try #require(try await coordinator.reviewQueue().first)

        try await coordinator.markOpened(item.id)

        #expect(try await coordinator.reviewQueue().map(\.isUnread) == [false])
    }
}

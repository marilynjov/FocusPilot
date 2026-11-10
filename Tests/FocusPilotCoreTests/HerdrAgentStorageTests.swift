import Foundation
import GRDB
import Testing
@testable import FocusPilotCore

func agent(_ status: HerdrAgentStatus, pane: String = "w4:p2", name: String? = "ablation", kind: String = "claude",
           title: String? = "Ablation table") -> HerdrAgent {
    HerdrAgent(paneID: pane, workspaceID: String(pane.prefix { $0 != ":" }), tabID: "w4:t2", name: name, kind: kind,
               status: status, title: title)
}

@Suite("Herdr agents on tasks: storage")
struct HerdrAgentStorageTests {
    private let directory: URL
    private let clock = SettableClock(wednesdayMorningInBogota)
    private let repository: TaskRepository

    init() throws {
        directory = try makeTemporaryDirectory()
        let clock = clock
        repository = try TaskRepository(location: StorageLocation(directory: directory), now: { clock.now })
    }

    private func task(_ title: String = "Explain baseline results") async throws -> Int64 {
        try await repository.addTask(NewTask(title: title)).id!
    }

    private func link(_ agent: HerdrAgent, to taskID: Int64, on server: HerdrServer = herdrServer) async throws -> TaskAgentLink {
        try await repository.linkAgent(agent, on: server, workspaceLabel: "NLP report", toTask: taskID)
    }

    @Test func aLinkKeepsTheServerInstanceWithThePane() async throws {
        let taskID = try await task()
        let link = try await link(agent(.working), to: taskID)

        #expect(try await repository.agentLinks(forTask: taskID) == [link])
        #expect(link.server == herdrServer)
        #expect(link.paneID == "w4:p2")
        #expect(link.name == "ablation")
        #expect(link.kind == "claude")
        #expect(link.label == "ablation")
        #expect(link.workspaceLabel == "NLP report")
        #expect(link.lastStatus == .working)
    }

    @Test func linkingTheSameAgentTwiceKeepsOneLink() async throws {
        let taskID = try await task()
        _ = try await link(agent(.working), to: taskID)
        _ = try await link(agent(.idle), to: taskID)
        #expect(try await repository.agentLinks(forTask: taskID).count == 1)
    }

    @Test func anUnnamedAgentIsLabelledByItsTitleThenItsKind() async throws {
        let taskID = try await task()
        #expect(try await link(agent(.idle, pane: "w4:p3", name: nil), to: taskID).label == "Ablation table")
        #expect(try await link(agent(.idle, pane: "w4:p4", name: nil, kind: "codex", title: nil), to: taskID).label == "codex")
    }

    @Test func finishingAddsAResultWithoutTouchingTheTaskOrNow() async throws {
        let nowTask = try await task("Write intro")
        try await repository.moveTask(nowTask, to: .now, .top)
        let taskID = try await task()
        let before = try await repository.tasks()
        _ = try await link(agent(.working), to: taskID)

        clock.set(instant("2026-10-14T14:28:00-05:00"))
        let new = try await repository.recordAgents([agent(.done)], on: herdrServer)

        #expect(new.map(\.paneID) == ["w4:p2"])
        let queue = try await repository.reviewQueue()
        #expect(queue.map(\.kind) == [.finished])
        #expect(queue.first?.taskID == taskID)
        #expect(queue.first?.taskTitle == "Explain baseline results")
        #expect(queue.first?.occurredAt == instant("2026-10-14T14:28:00-05:00"))
        #expect(queue.first?.summary == "Ablation table")
        // Agent completion never completes the task, and nothing changes Now.
        #expect(try await repository.tasks() == before)
    }

    @Test func unknownNeverAddsAResultButWorkSeenBeforeItStillCounts() async throws {
        let taskID = try await task()
        _ = try await link(agent(.working), to: taskID)

        #expect(try await repository.recordAgents([agent(.unknown)], on: herdrServer).isEmpty)
        #expect(try await repository.reviewQueue().isEmpty)
        #expect(try await repository.agentLinks(forTask: taskID).first?.lastStatus == .working)

        #expect(try await repository.recordAgents([agent(.idle)], on: herdrServer).count == 1)
    }

    @Test func linkedWhileReadyAddsNothingUntilItWorks() async throws {
        let taskID = try await task()
        _ = try await link(agent(.done), to: taskID)
        #expect(try await repository.recordAgents([agent(.done)], on: herdrServer).isEmpty)
        _ = try await repository.recordAgents([agent(.working)], on: herdrServer)
        #expect(try await repository.recordAgents([agent(.idle)], on: herdrServer).count == 1)
    }

    @Test func waitingAtAnApprovalIsQueuedAndReplacedByWhatFollows() async throws {
        let taskID = try await task()
        _ = try await link(agent(.working), to: taskID)

        _ = try await repository.recordAgents([agent(.blocked)], on: herdrServer)
        #expect(try await repository.reviewQueue().map(\.kind) == [.approval])

        _ = try await repository.recordAgents([agent(.idle)], on: herdrServer)
        #expect(try await repository.reviewQueue().map(\.kind) == [.finished])
    }

    @Test func anApprovalIsClearedOnceTheAgentLeavesBlocked() async throws {
        // Approved in Herdr: the agent works again and nothing is left to answer.
        let taskID = try await task()
        _ = try await link(agent(.working), to: taskID)
        _ = try await repository.recordAgents([agent(.blocked)], on: herdrServer)

        _ = try await repository.recordAgents([agent(.working)], on: herdrServer)

        #expect(try await repository.reviewQueue().isEmpty)
    }

    @Test func anUnknownReadingKeepsTheApproval() async throws {
        let taskID = try await task()
        _ = try await link(agent(.working), to: taskID)
        _ = try await repository.recordAgents([agent(.blocked)], on: herdrServer)

        _ = try await repository.recordAgents([agent(.unknown)], on: herdrServer)

        #expect(try await repository.reviewQueue().map(\.kind) == [.approval])
    }

    @Test func aRenamedAgentIsFollowedAgainOnlyAfterRelink() async throws {
        let taskID = try await task()
        let link = try await link(agent(.working), to: taskID)

        try await repository.relinkAgent(link.id, to: agent(.working, name: "ablation-2"))

        let relinked = try #require(try await repository.agentLinks(forTask: taskID).first)
        #expect(relinked.name == "ablation-2")
        #expect(relinked.label == "ablation-2")
        #expect(try await repository.recordAgents([agent(.idle, name: "ablation-2")], on: herdrServer).count == 1)
    }

    @Test func relinkRefusesAnotherPaneOrProgram() async throws {
        let taskID = try await task()
        let link = try await link(agent(.working), to: taskID)
        await #expect(throws: (any Error).self) { try await repository.relinkAgent(link.id, to: agent(.idle, kind: "codex")) }
        await #expect(throws: (any Error).self) { try await repository.relinkAgent(link.id, to: agent(.idle, pane: "w4:p9")) }
    }

    @Test func todayItemsCarryTheirProjectID() async throws {
        let id = try await repository.addTask(NewTask(title: "Explain baseline results", projectName: "NLP report")).id!
        let item = try #require(try await repository.todayTasks().first { $0.id == id })
        #expect(item.projectID == (try await repository.projects().first { $0.title == "NLP report" }?.id))
    }

    @Test func eachFinishedRunIsKept() async throws {
        let taskID = try await task()
        _ = try await link(agent(.working), to: taskID)
        for status in [HerdrAgentStatus.idle, .working, .done] {
            clock.set(clock.now + 60)
            _ = try await repository.recordAgents([agent(status)], on: herdrServer)
        }
        #expect(try await repository.reviewQueue().map(\.kind) == [.finished, .finished])
    }

    @Test func anotherServerInstanceOrAnotherAgentInThePaneIsNotRecorded() async throws {
        let taskID = try await task()
        _ = try await link(agent(.working), to: taskID)

        _ = try await repository.recordAgents([agent(.idle)], on: restartedHerdrServer)
        _ = try await repository.recordAgents([agent(.idle, kind: "codex")], on: herdrServer)
        _ = try await repository.recordAgents([agent(.idle, name: "other")], on: herdrServer)

        #expect(try await repository.reviewQueue().isEmpty)
        #expect(try await repository.agentLinks(forTask: taskID).first?.lastStatus == .working)
    }

    @Test func theLastStatusSurvivesARestartOfFocusPilot() async throws {
        let taskID = try await task()
        _ = try await link(agent(.working), to: taskID)

        let reopened = try TaskRepository(location: StorageLocation(directory: directory))
        #expect(try await reopened.recordAgents([agent(.done)], on: herdrServer).count == 1)
    }

    @Test func theChangeTimeMovesOnlyWhenTheStatusChanges() async throws {
        let taskID = try await task()
        _ = try await link(agent(.working), to: taskID)
        clock.set(clock.now + 120)
        _ = try await repository.recordAgents([agent(.working)], on: herdrServer)
        #expect(try await repository.agentLinks(forTask: taskID).first?.statusChangedAt == wednesdayMorningInBogota)

        _ = try await repository.recordAgents([agent(.idle)], on: herdrServer)
        #expect(try await repository.agentLinks(forTask: taskID).first?.statusChangedAt == wednesdayMorningInBogota + 120)
    }

    @Test func outputIsStoredAsPlainTextOnTheItem() async throws {
        let taskID = try await task()
        _ = try await link(agent(.working), to: taskID)
        let item = try #require(try await repository.recordAgents([agent(.idle)], on: herdrServer).first)

        try await repository.storeOutput(AgentOutputPreview("\u{1B}[1mReady\u{1B}[0m\nrm -rf ~"), forReviewItem: item.id)

        let output = try #require(try await repository.reviewQueue().first?.output)
        #expect(output.lines == ["Ready", "rm -rf ~"])
        #expect(output.totalLineCount == 2)
    }

    @Test func markingReviewedTakesTheItemOffTheQueue() async throws {
        let taskID = try await task()
        _ = try await link(agent(.working), to: taskID)
        let item = try #require(try await repository.recordAgents([agent(.idle)], on: herdrServer).first)

        try await repository.markReviewed(item.id)

        #expect(try await repository.reviewQueue().isEmpty)
    }

    @Test func anItemIsUnreadUntilFirstOpened() async throws {
        let taskID = try await task()
        _ = try await link(agent(.working), to: taskID)
        let item = try #require(try await repository.recordAgents([agent(.idle)], on: herdrServer).first)
        #expect(try await repository.reviewQueue().first?.isUnread == true)

        try await repository.markOpened(item.id)
        clock.set(clock.now + 60)
        try await repository.markOpened(item.id)

        // Opened once, it stays on the queue as read, keeping the first time.
        let opened = try #require(try await repository.reviewQueue().first)
        #expect(!opened.isUnread)
        #expect(opened.openedAt == wednesdayMorningInBogota)
    }

    @Test func theQueueIsNewestFirst() async throws {
        let first = try await task("Explain baseline results")
        let second = try await task("PhD shortlist")
        _ = try await link(agent(.working, pane: "w4:p2"), to: first)
        _ = try await link(agent(.working, pane: "w5:p1", name: "phd"), to: second)
        _ = try await repository.recordAgents([agent(.idle, pane: "w4:p2")], on: herdrServer)
        clock.set(clock.now + 60)
        _ = try await repository.recordAgents([agent(.blocked, pane: "w5:p1", name: "phd")], on: herdrServer)

        #expect(try await repository.reviewQueue().map(\.taskTitle) == ["PhD shortlist", "Explain baseline results"])
    }

    @Test func unlinkingKeepsQueuedResultsButStopsWatching() async throws {
        let taskID = try await task()
        let link = try await link(agent(.working), to: taskID)
        _ = try await repository.recordAgents([agent(.idle)], on: herdrServer)

        try await repository.unlinkAgent(link.id)

        #expect(try await repository.agentLinks(forTask: taskID).isEmpty)
        let queued = try #require(try await repository.reviewQueue().first)
        #expect(queued.linkID == nil)
        #expect(queued.agentLabel == "ablation")
        _ = try await repository.recordAgents([agent(.working)], on: herdrServer)
        #expect(try await repository.recordAgents([agent(.idle)], on: herdrServer).isEmpty)
    }

    @Test func undoingAHerdrAddRemovesItsLinksAndItems() async throws {
        let request = HerdrAddRequest(text: "Check seeds", capturedAt: wednesdayMorningInBogota, timeZone: bogota, caller: nil)
        let added = try await repository.addFromHerdr(request)
        _ = try await link(agent(.working), to: added.taskID)
        _ = try await repository.recordAgents([agent(.idle)], on: herdrServer)

        try await repository.undoHerdrAdd(added.taskID)

        #expect(try await repository.reviewQueue().isEmpty)
        #expect(try await repository.agentLinks().isEmpty)
    }
}

@Suite("Herdr agent link state")
struct AgentLinkStateTests {
    private let link = TaskAgentLink(id: 1, taskID: 1, server: herdrServer, paneID: "w4:p2", workspaceID: "w4",
                                     tabID: "w4:t2", name: "ablation", kind: "claude", label: "ablation",
                                     workspaceLabel: "NLP report", lastStatus: .working,
                                     statusChangedAt: wednesdayMorningInBogota)

    @Test func theSameAgentInThePaneIsLive() {
        let live = agent(.idle)
        #expect(AgentLinkState(link, .connected(herdrServer, [live])) == .live(live))
    }

    @Test func anotherProgramOrAnUnnamedAgentInThePaneIsReplaced() {
        #expect(AgentLinkState(link, .connected(herdrServer, [agent(.idle, kind: "codex")])) == .replaced)
        // Herdr clears a name when its agent exits, so no name means a new occupant.
        #expect(AgentLinkState(link, .connected(herdrServer, [agent(.idle, name: nil)])) == .replaced)
    }

    @Test func theSameProgramUnderANewNameIsRenamed() {
        let renamed = agent(.idle, name: "ablation-2")
        #expect(AgentLinkState(link, .connected(herdrServer, [renamed])) == .renamed(renamed))
    }

    @Test func aMissingPaneOrARestartedServerIsNotFound() {
        #expect(AgentLinkState(link, .connected(herdrServer, [])) == .notFound)
        #expect(AgentLinkState(link, .connected(restartedHerdrServer, [agent(.idle)])) == .notFound)
    }

    @Test func withoutHerdrNothingIsKnown() {
        #expect(AgentLinkState(link, .disconnected(.notRunning)) == .unknown)
        #expect(AgentLinkState(link, nil) == .unknown)
    }
}

@Suite("Owner schema migration to v16")
struct OwnerMigrationV16Tests {
    @Test func resultsQueuedBeforeTheMigrationAreUnread() async throws {
        let location = StorageLocation(directory: try makeTemporaryDirectory())
        let oldDatabase = try DatabaseQueue(path: location.ownerDatabaseURL.path)
        try OwnerSchema.migrator.migrate(oldDatabase, upTo: "owner-v15-reported-agents")
        try await oldDatabase.write { db in
            try db.execute(sql: "INSERT INTO task (title) VALUES ('Explain baseline results')")
            try db.execute(sql: """
                INSERT INTO herdrReviewItem (taskId, kind, occurredAt, agentLabel)
                VALUES (1, 'finished', '2026-11-10 14:00:00.000', 'ablation')
                """)
        }
        try oldDatabase.close()

        let repository = try TaskRepository(location: location)

        let item = try #require(try await repository.reviewQueue().first)
        #expect(item.isUnread)
        #expect(item.agentLabel == "ablation")
    }
}

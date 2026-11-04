import Foundation
import Testing
@testable import FocusPilotCore

/// Reported agents in the owner database (decision 0005, step 1): the
/// monitoring setting, state changes, folder matching, the owner's links
/// and the Review queue.
@Suite("Reported agents: storage")
struct ReportedAgentStorageTests {
    private let directory: URL
    private let clock = SettableClock(wednesdayMorningInBogota)
    private let repository: TaskRepository
    private let nlpFolder = "/Users/owner/Projects/NLP/nlp_project"

    init() throws {
        directory = try makeTemporaryDirectory()
        let clock = clock
        repository = try TaskRepository(location: StorageLocation(directory: directory), now: { clock.now })
    }

    private func report(_ status: AgentReport.Status, session: String = "s1", folder: String? = "/tmp/elsewhere",
                        summary: String? = nil, taskID: Int64? = nil) async throws -> AgentReportReceipt? {
        let report = AgentReport(source: .claudeCodeHook, status: status, label: "Claude Code · nlp", key: session,
                                 folder: folder, summary: summary, terminal: TerminalPlace(app: "WarpTerminal"),
                                 taskID: taskID)
        return try await repository.recordAgentReport(try report.sanitized().report)
    }

    private func task(_ title: String = "Explain baseline results", project: String? = nil) async throws -> Int64 {
        try await repository.addTask(NewTask(title: title, projectName: project)).id!
    }

    @Test func monitoringIsOffByDefaultAndRefusesReports() async throws {
        #expect(try await repository.isAgentMonitoringOn() == false)
        #expect(try await report(.working) == nil)
        #expect(try await repository.reportedAgents().isEmpty)
    }

    @Test func turningMonitoringOffAgainRefusesOnceMore() async throws {
        try await repository.setAgentMonitoring(true)
        #expect(try await report(.working) != nil)
        try await repository.setAgentMonitoring(false)
        #expect(try await report(.done) == nil)
        #expect(try await repository.reportedAgents().first?.reportedState == .working)
    }

    @Test func reportsFromOneSessionUpdateOneAgent() async throws {
        try await repository.setAgentMonitoring(true)
        _ = try await report(.working)
        clock.set(wednesdayMorningInBogota.addingTimeInterval(60))
        let receipt = try #require(try await report(.needsInput, summary: "Claude needs your permission"))

        #expect(receipt.state == .needsYou)
        #expect(receipt.needsYouNow)
        let agents = try await repository.reportedAgents()
        #expect(agents.count == 1)
        let agent = try #require(agents.first)
        #expect(agent.source == .claudeCodeHook)
        #expect(agent.reportedState == .needsYou)
        #expect(agent.lastMessage == "Claude needs your permission")
        #expect(agent.stateChangedAt == wednesdayMorningInBogota.addingTimeInterval(60))
        #expect(agent.terminal.app == "WarpTerminal")
        #expect(agent.taskID == nil)
    }

    @Test func aStaleWorkingAgentShowsUnknownNotDone() async throws {
        try await repository.setAgentMonitoring(true)
        _ = try await report(.working)
        let agent = try #require(try await repository.reportedAgents().first)
        #expect(agent.state(at: wednesdayMorningInBogota.addingTimeInterval(3600)) == .unknown)
    }

    @Test func theProjectFolderMatchesTheNowTaskInThatProject() async throws {
        try await repository.setAgentMonitoring(true)
        try await repository.importHerdrWorkspaces([nlpWorkspace], on: herdrServer)
        let id = try await task(project: "NLP report")
        try await repository.moveTask(id, to: .now, .top)

        let receipt = try #require(try await report(.working, folder: nlpFolder + "/src"))
        #expect(receipt.taskTitle == "Explain baseline results")
        #expect(try await repository.reportedAgents().first?.taskID == id)
    }

    @Test func aProjectFolderWithoutItsTaskInNowMatchesNothing() async throws {
        try await repository.setAgentMonitoring(true)
        try await repository.importHerdrWorkspaces([nlpWorkspace], on: herdrServer)
        _ = try await task(project: "NLP report")

        #expect(try await report(.working, folder: nlpFolder)?.taskTitle == nil)
    }

    @Test func aHandLinkIsFollowedByLaterAgentsInTheSameFolder() async throws {
        try await repository.setAgentMonitoring(true)
        let id = try await task()
        let first = try #require(try await report(.working, session: "s1", folder: "/Users/owner/thesis"))
        try await repository.linkReportedAgent(first.agentID, toTask: id)

        let second = try #require(try await report(.working, session: "s2", folder: "/Users/owner/thesis/ch2"))
        #expect(second.taskTitle == "Explain baseline results")
    }

    @Test func anOwnerUnlinkIsKeptThroughLaterReports() async throws {
        try await repository.setAgentMonitoring(true)
        let id = try await task()
        let receipt = try #require(try await report(.working, taskID: id))
        #expect(receipt.taskTitle != nil)
        try await repository.linkReportedAgent(receipt.agentID, toTask: nil)

        _ = try await report(.working, taskID: id)
        let agent = try #require(try await repository.reportedAgents().first)
        #expect(agent.taskID == nil)
        #expect(agent.isLinkedByOwner)
    }

    @Test func aFinishedTurnGoesToTheReviewQueueOnceWithoutTouchingTheTask() async throws {
        try await repository.setAgentMonitoring(true)
        let id = try await task()
        try await repository.moveTask(id, to: .now, .top)
        _ = try await report(.working, taskID: id)
        let done = try #require(try await report(.done, summary: "Table updated.\nTests pass."))
        #expect(done.queuedResult)
        // The same result again is not queued twice.
        #expect(try await report(.done, summary: "Table updated.\nTests pass.")?.queuedResult == false)

        let queue = try await repository.reviewQueue()
        #expect(queue.count == 1)
        let item = try #require(queue.first)
        #expect(item.taskID == id)
        #expect(item.reportedAgentID == done.agentID)
        #expect(item.source == .claudeCodeHook)
        #expect(item.agentState == .ready)
        #expect(item.summary == "Table updated.")
        #expect(item.output?.lines == ["Table updated.", "Tests pass."])
        #expect(item.workspaceLabel == "elsewhere")
        #expect(try await repository.todayTasks().first { $0.id == id }?.status == .now)
    }

    @Test func aFailedRunIsQueuedAsFailed() async throws {
        try await repository.setAgentMonitoring(true)
        let id = try await task()
        _ = try await report(.failed, summary: "Exited with status 3.", taskID: id)
        #expect(try await repository.reviewQueue().first?.agentState == .failed)
    }

    @Test func anUnlinkedAgentsResultStaysOnTheAgent() async throws {
        try await repository.setAgentMonitoring(true)
        #expect(try await report(.done, summary: "Done.")?.queuedResult == false)
        #expect(try await repository.reviewQueue().isEmpty)
        #expect(try await repository.reportedAgents().first?.lastMessage == "Done.")
    }

    @Test func forgettingAnAgentKeepsItsResults() async throws {
        try await repository.setAgentMonitoring(true)
        let id = try await task()
        let receipt = try #require(try await report(.done, summary: "Done.", taskID: id))
        try await repository.forgetReportedAgent(receipt.agentID)

        #expect(try await repository.reportedAgents().isEmpty)
        let item = try #require(try await repository.reviewQueue().first)
        #expect(item.reportedAgentID == nil)
        #expect(item.agentLabel == "Claude Code · nlp")
    }

    @Test func agentsSilentForAWeekAreForgotten() async throws {
        try await repository.setAgentMonitoring(true)
        _ = try await report(.done, session: "old")
        clock.set(wednesdayMorningInBogota.addingTimeInterval(8 * 24 * 3600))
        _ = try await report(.working, session: "new")
        #expect(try await repository.reportedAgents().map(\.key) == ["new"])
    }
}

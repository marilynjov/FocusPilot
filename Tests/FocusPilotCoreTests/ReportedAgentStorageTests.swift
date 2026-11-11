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
                        summary: String? = nil, taskID: Int64? = nil, label: String = "Claude Code · nlp",
                        fallback: Bool = false, at reportedAt: Date? = nil, window: String? = nil,
                        source: AgentSource = .claudeCodeHook) async throws -> AgentReportReceipt? {
        let report = AgentReport(source: source, status: status, label: label, key: session,
                                 folder: folder, summary: summary, terminal: TerminalPlace(app: "WarpTerminal"),
                                 taskID: taskID, labelIsFallback: fallback, reportedAt: reportedAt, warpWindow: window)
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

    // MARK: Warp windows

    @Test func aNewerClaudeCodeReportWithoutTheWindowClearsIt() async throws {
        try await repository.setAgentMonitoring(true)
        _ = try await report(.working, window: "3fa9c01b")
        #expect(try await repository.reportedAgents().first?.warpWindow == "3fa9c01b")
        // An older report from before the window, arriving late, leaves it.
        _ = try await report(.done, at: wednesdayMorningInBogota.addingTimeInterval(-60))
        #expect(try await repository.reportedAgents().first?.warpWindow == "3fa9c01b")
        // The chat was quit and resumed in an ordinary tab.
        clock.set(wednesdayMorningInBogota.addingTimeInterval(60))
        _ = try await report(.working)
        #expect(try await repository.reportedAgents().first?.warpWindow == nil)
    }

    @Test func aCommandReportWithoutTheWindowKeepsIt() async throws {
        try await repository.setAgentMonitoring(true)
        _ = try await report(.working, window: "3fa9c01b", source: .command)
        clock.set(wednesdayMorningInBogota.addingTimeInterval(60))
        _ = try await report(.done, source: .command)
        #expect(try await repository.reportedAgents().first?.warpWindow == "3fa9c01b")
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

        let second = try #require(try await report(.working, session: "s2", folder: "/Users/owner/thesis"))
        #expect(second.taskTitle == "Explain baseline results")
        // Only that folder: one inside it may be other work.
        #expect(try await report(.working, session: "s3", folder: "/Users/owner/thesis/ch2")?.taskTitle == nil)
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

    // MARK: Out of order, labels, floods

    @Test func aLateReportDoesNotTurnTheStateBack() async throws {
        try await repository.setAgentMonitoring(true)
        let id = try await task()
        let start = wednesdayMorningInBogota.addingTimeInterval(-60)
        // The next prompt's report arrives before the turn's Stop.
        _ = try await report(.working, taskID: id, at: start.addingTimeInterval(20))
        let late = try #require(try await report(.done, summary: "Turn one done.", at: start.addingTimeInterval(10)))

        #expect(late.state == .working)
        #expect(!late.needsYouNow)
        let agent = try #require(try await repository.reportedAgents().first)
        #expect(agent.reportedState == .working)
        #expect(agent.lastMessage == nil)
        #expect(agent.lastReportAt == start.addingTimeInterval(20))
        // The finished turn was real, so its result is queued, once.
        #expect(late.queuedResult)
        #expect(try await report(.done, summary: "Turn one done.", at: start.addingTimeInterval(10))?.queuedResult == false)
        #expect(try await repository.reviewQueue().map(\.summary) == ["Turn one done."])
    }

    @Test func aLateNeedsYouDoesNotCallTheOwner() async throws {
        try await repository.setAgentMonitoring(true)
        let start = wednesdayMorningInBogota.addingTimeInterval(-60)
        _ = try await report(.done, summary: "Done.", at: start.addingTimeInterval(20))
        let late = try #require(try await report(.needsInput, at: start.addingTimeInterval(10)))
        #expect(!late.needsYouNow)
        #expect(try await repository.reportedAgents().first?.reportedState == .ready)
    }

    @Test func aTimeInTheFutureCountsAsNow() async throws {
        try await repository.setAgentMonitoring(true)
        _ = try await report(.working, at: wednesdayMorningInBogota.addingTimeInterval(86_400))
        #expect(try await repository.reportedAgents().first?.lastReportAt == wednesdayMorningInBogota)
    }

    @Test func aTimeLongAgoCountsAsFiveMinutesAgo() async throws {
        try await repository.setAgentMonitoring(true)
        _ = try await report(.working, at: wednesdayMorningInBogota.addingTimeInterval(-86_400))
        #expect(try await repository.reportedAgents().first?.lastReportAt
            == wednesdayMorningInBogota.addingTimeInterval(-ReportedAgentStore.oldestReport))
        // So a report from the last minutes still counts as newer.
        _ = try await report(.done, at: wednesdayMorningInBogota.addingTimeInterval(-60))
        #expect(try await repository.reportedAgents().first?.reportedState == .ready)
    }

    @Test func aFallbackLabelKeepsTheTitleGivenBefore() async throws {
        try await repository.setAgentMonitoring(true)
        _ = try await report(.working, label: "Ablation fixes")
        let receipt = try #require(try await report(.done, label: "Claude Code · nlp", fallback: true))
        #expect(receipt.label == "Ablation fixes")
        #expect(try await repository.reportedAgents().first?.label == "Ablation fixes")
        // A new agent still starts with one.
        #expect(try await report(.working, session: "s2", label: "Claude Code · nlp", fallback: true)?.label
            == "Claude Code · nlp")
    }

    @Test func tooManyNewAgentsInAMinuteAreRefused() async throws {
        try await repository.setAgentMonitoring(true)
        for index in 0..<ReportedAgentStore.newAgentsPerMinute {
            _ = try await report(.working, session: "s\(index)")
        }
        await #expect(throws: ReportedAgentStore.Refusal.tooManyNewAgents) {
            _ = try await self.report(.working, session: "one-too-many")
        }
        // Agents already known still report.
        #expect(try await report(.done, session: "s0") != nil)
        clock.set(wednesdayMorningInBogota.addingTimeInterval(61))
        #expect(try await report(.working, session: "one-too-many") != nil)
    }
}

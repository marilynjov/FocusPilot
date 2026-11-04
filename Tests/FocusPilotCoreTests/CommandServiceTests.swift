import Foundation
import Testing
@testable import FocusPilotCore

@Suite("Add rate limit")
struct AddRateLimitTests {
    private let start = wednesdayMorningInBogota

    @Test func allowsTwentyAddsPerMinutePerPane() {
        var limit = AddRateLimit()
        let allowed = (0..<21).map { limit.allow("w4:p2", at: start.addingTimeInterval(Double($0))) }
        #expect(allowed == Array(repeating: true, count: 20) + [false])
    }

    @Test func eachPaneHasItsOwnBudget() {
        var limit = AddRateLimit()
        for second in 0..<20 { _ = limit.allow("w4:p2", at: start.addingTimeInterval(Double(second))) }
        let otherPane = limit.allow("w5:p1", at: start.addingTimeInterval(20))
        #expect(otherPane)
    }

    @Test func theBudgetComesBackAMinuteLater() {
        var limit = AddRateLimit()
        for _ in 0..<20 { _ = limit.allow("w4:p2", at: start) }
        let withinTheMinute = limit.allow("w4:p2", at: start.addingTimeInterval(59))
        #expect(!withinTheMinute)
        let aMinuteLater = limit.allow("w4:p2", at: start.addingTimeInterval(60))
        #expect(aMinuteLater)
    }

    @Test func refusedAddsDoNotExtendTheWait() {
        var limit = AddRateLimit()
        for _ in 0..<20 { _ = limit.allow("w4:p2", at: start) }
        for second in 1..<60 { _ = limit.allow("w4:p2", at: start.addingTimeInterval(Double(second))) }
        let aMinuteLater = limit.allow("w4:p2", at: start.addingTimeInterval(60))
        #expect(aMinuteLater)
    }
}

extension AddRateLimitTests {
    @Test func panesIdleForAMinuteAreForgotten() {
        var limit = AddRateLimit()
        for pane in 0..<50 { _ = limit.allow("w4:p\(pane)", at: start) }
        #expect(limit.trackedPanes == 50)

        _ = limit.allow("w5:p1", at: start.addingTimeInterval(61))

        #expect(limit.trackedPanes == 1)
    }
}

@Suite("Command service")
struct CommandServiceTests {
    private let repository: TaskRepository
    private let service: CommandService

    init() throws {
        repository = try TaskRepository(location: StorageLocation(directory: makeTemporaryDirectory()),
                                        now: { wednesdayMorningInBogota })
        service = CommandService(repository: repository, now: { wednesdayMorningInBogota })
    }

    @Test func addIsStoredAndReported() async throws {
        let response = await service.handle(.add(herdrAdd("Reply to co-advisor")))

        guard case .added(let result) = response else {
            Issue.record("expected an add, got \(response)")
            return
        }
        #expect(result.title == "Reply to co-advisor")
        #expect(try await repository.tasks().count == 1)
    }

    @Test func aBurstFromOnePaneIsRefusedWithAMessage() async throws {
        for index in 0..<20 { _ = await service.handle(.add(herdrAdd("Task \(index)"))) }

        let response = await service.handle(.add(herdrAdd("One too many")))

        #expect(response == .refused(CommandService.rateLimitMessage))
        #expect(try await repository.tasks().count == 20)
    }

    @Test func addsOutsideHerdrShareOneBudget() async throws {
        for index in 0..<20 { _ = await service.handle(.add(herdrAdd("Task \(index)", from: nil))) }
        #expect(await service.handle(.add(herdrAdd("One too many", from: nil))) == .refused(CommandService.rateLimitMessage))
    }

    @Test func tasksReturnsTheScope() async throws {
        _ = await service.handle(.add(herdrAdd("Reply to co-advisor", from: nil)))
        #expect(await service.handle(.tasks(nil)) == .tasks(HerdrTaskScope(now: nil, projectTitle: nil, tasks: [])))
    }

    @Test func aBlankAddIsRefused() async throws {
        #expect(await service.handle(.add(herdrAdd("   "))) == .refused("Nothing to add: the task needs a title."))
    }
}

/// Agent reports over the socket: each agent, all agents together and new
/// agents each have a budget per minute (decision 0005).
@Suite("Command service: agent reports")
struct AgentReportServiceTests {
    private let repository: TaskRepository
    private let service: CommandService

    init() throws {
        repository = try TaskRepository(location: StorageLocation(directory: makeTemporaryDirectory()),
                                        now: { wednesdayMorningInBogota })
        service = CommandService(repository: repository, now: { wednesdayMorningInBogota })
    }

    private func report(_ session: String) -> CommandRequest {
        .agentReport(AgentReport(source: .command, status: .working, label: "bot", key: session))
    }

    private func isRecorded(_ response: CommandResponse) -> Bool {
        if case .agentRecorded = response { true } else { false }
    }

    @Test func monitoringOffIsRefusedWithItsMessage() async {
        #expect(await service.handle(report("a")) == .refused(CommandService.monitoringOffMessage))
    }

    @Test func oneAgentGetsTwentyAMinute() async throws {
        try await repository.setAgentMonitoring(true)
        for _ in 0..<AddRateLimit.limit { #expect(isRecorded(await service.handle(report("a")))) }
        #expect(await service.handle(report("a")) == .refused(CommandService.reportRateLimitMessage))
        #expect(isRecorded(await service.handle(report("b"))))
    }

    @Test func allAgentsTogetherGetSixtyAMinute() async throws {
        try await repository.setAgentMonitoring(true)
        for agent in 0..<3 {
            for _ in 0..<AddRateLimit.limit { #expect(isRecorded(await service.handle(report("agent\(agent)")))) }
        }
        #expect(await service.handle(report("agent4")) == .refused(CommandService.allReportsLimitMessage))
    }

    @Test func tooManyNewAgentsAreRefused() async throws {
        try await repository.setAgentMonitoring(true)
        for agent in 0..<ReportedAgentStore.newAgentsPerMinute {
            #expect(isRecorded(await service.handle(report("new\(agent)"))))
        }
        #expect(await service.handle(report("flood")) == .refused(CommandService.newAgentsLimitMessage))
    }
}

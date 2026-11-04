import Foundation
import Synchronization
import Testing
@testable import FocusPilotCore

/// `focuspilot agent report` and `focuspilot run` end to end: arguments,
/// stdin and terminal in, text and exit status out, through a real socket
/// to a `CommandService`.
@Suite("focuspilot agent commands")
final class AgentCommandTests {
    private let location: StorageLocation
    private let repository: TaskRepository
    private var server: CommandSocketServer?
    /// What the stand-in child was asked to run.
    private let children = Children()

    final class Children: Sendable {
        let commands = Mutex<[[String]]>([])
    }

    init() throws {
        location = StorageLocation(directory: try makeShortDirectory())
        repository = try TaskRepository(location: location, now: { wednesdayMorningInBogota })
    }

    deinit {
        server?.stop()
        try? FileManager.default.removeItem(at: location.directory)
    }

    private func startApp(monitoring: Bool = true) async throws {
        try await repository.setAgentMonitoring(monitoring)
        let service = CommandService(repository: repository, now: { wednesdayMorningInBogota })
        let server = CommandSocketServer(path: location.commandSocketPath) { await service.handle($0) }
        try server.start()
        self.server = server
    }

    private func run(_ arguments: [String], stdin: String = "", childStatus: Int32? = 0,
                     environment: [String: String] = ["TERM_PROGRAM": "WarpTerminal"]) async -> FocusPilotCommand.Outcome {
        let children = children
        let system = AgentCommandSystem(standardInput: { Data(stdin.utf8) }, controllingTerminal: { "/dev/ttys004" },
                                        currentDirectory: { "/Users/owner/thesis" },
                                        runChild: { command in children.commands.withLock { $0.append(command) }; return childStatus },
                                        newRunID: { "run-1" })
        let command = FocusPilotCommand(location: location, environment: environment, now: wednesdayMorningInBogota,
                                        timeZone: bogota, system: system)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: command.run(arguments)) }
        }
    }

    // MARK: agent report

    @Test func aReportIsRecordedWithTheTerminalItRunsIn() async throws {
        try await startApp()
        let outcome = await run(["agent", "report", "needs-input", "--name", "ablation", "--summary", "Approve rm?"])

        #expect(outcome.status == 0)
        #expect(outcome.output == "Reported ablation: Needs you, not linked to a task yet.\n")
        let agent = try #require(try await repository.reportedAgents().first)
        #expect(agent.source == .command)
        #expect(agent.reportedState == .needsYou)
        #expect(agent.folder == "/Users/owner/thesis")
        #expect(agent.terminal == TerminalPlace(app: "WarpTerminal", tty: "/dev/ttys004"))
    }

    @Test func givenOptionsWinOverTheTerminal() async throws {
        try await startApp()
        let outcome = await run(["agent", "report", "working", "--name", "a", "--folder", "sub", "--terminal",
                                 "iTerm.app", "--tty", "ttys009", "--session", "w0t0p0:XYZ"])
        #expect(outcome.status == 0)
        let agent = try #require(try await repository.reportedAgents().first)
        #expect(agent.folder == "/Users/owner/thesis/sub")
        #expect(agent.key == "w0t0p0:XYZ")
        #expect(agent.terminal == TerminalPlace(app: "iTerm.app", tty: "/dev/ttys009", sessionID: "w0t0p0:XYZ"))
    }

    @Test func monitoringOffRefusesWithAClearMessage() async throws {
        try await startApp(monitoring: false)
        let outcome = await run(["agent", "report", "done", "--name", "ablation"])

        #expect(outcome.status == 1)
        #expect(outcome.output.isEmpty)
        #expect(outcome.error == CommandService.monitoringOffMessage + "\n")
        #expect(try await repository.reportedAgents().isEmpty)
    }

    @Test func badArgumentsAreUsageErrors() async throws {
        try await startApp()
        #expect(await run(["agent", "report", "finished", "--name", "a"]).status == 2)
        #expect(await run(["agent", "report", "done"]).status == 2)
        #expect(await run(["agent", "report", "done", "--name"]).status == 2)
        #expect(await run(["agent", "report", "done", "--name", "a", "--colour", "red"]).status == 2)
        #expect(await run(["agent", "report", "done", "--name", "a", "--task", "x"]).status == 2)
        #expect(await run(["agent", "status"]).status == 2)
        #expect(try await repository.reportedAgents().isEmpty)
    }

    @Test func invalidValuesAreDroppedWithANote() async throws {
        try await startApp()
        let outcome = await run(["agent", "report", "working", "--name", "a", "--tty", "../../etc"])
        #expect(outcome.status == 0)
        #expect(outcome.error == "Note: Ignored --tty: it isn’t valid.\n")
        #expect(try await repository.reportedAgents().first?.terminal.tty == nil)
    }

    @Test func withTheAppClosedTheReportFails() async {
        let outcome = await run(["agent", "report", "working", "--name", "a"])
        #expect(outcome.status == 1)
        #expect(outcome.error == "FocusPilot is not running, so the report was not recorded.\n")
    }

    // MARK: --from-claude-hook

    private let stopPayload = #"{"session_id":"abc","cwd":"/Users/owner/nlp","hook_event_name":"Stop","last_assistant_message":"Done."}"#

    @Test func aHookReportPrintsNothingOnStdout() async throws {
        try await startApp()
        let outcome = await run(["agent", "report", "--from-claude-hook", "Stop"], stdin: stopPayload)

        #expect(outcome == FocusPilotCommand.Outcome(status: 0))
        let agent = try #require(try await repository.reportedAgents().first)
        #expect(agent.source == .claudeCodeHook)
        #expect(agent.key == "abc")
        #expect(agent.label == "Claude Code · nlp")
        #expect(agent.reportedState == .ready)
        #expect(agent.lastMessage == "Done.")
        #expect(agent.terminal.tty == "/dev/ttys004")
    }

    @Test func aHookNeverExitsTwoSinceThatWouldKeepClaudeFromStopping() async throws {
        try await startApp(monitoring: false)
        let refused = await run(["agent", "report", "--from-claude-hook", "Stop"], stdin: stopPayload)
        #expect(refused.status == 1)
        #expect(refused.output.isEmpty)
        #expect(refused.error == CommandService.monitoringOffMessage + "\n")

        for arguments in [["agent", "report", "--from-claude-hook"], ["agent", "report", "--from-claude-hook", "PreToolUse"],
                          ["agent", "report", "--from-claude-hook", "Stop", "--colour", "red"],
                          ["agent", "report", "--name", "x", "--from-claude-hook", "Stop"],
                          ["agent", "report", "done", "--from-claude-hook", "Stop"]] {
            let outcome = await run(arguments, stdin: stopPayload)
            #expect(outcome.status == 1)
            #expect(outcome.output.isEmpty)
        }
        let unreadable = await run(["agent", "report", "--from-claude-hook", "Stop"], stdin: "{")
        #expect(unreadable.status == 1)
        #expect(unreadable.output.isEmpty)
    }

    @Test func anIgnoredNotificationSucceedsQuietly() async throws {
        try await startApp()
        let idle = #"{"session_id":"abc","cwd":"/p","hook_event_name":"Notification","message":"m","notification_type":"idle_prompt"}"#
        #expect(await run(["agent", "report", "--from-claude-hook", "Notification"], stdin: idle)
            == FocusPilotCommand.Outcome(status: 0))
        #expect(try await repository.reportedAgents().isEmpty)
    }

    // MARK: run

    @Test func runReportsWorkingThenTheExitStatus() async throws {
        try await startApp()
        let id = try await repository.addTask(NewTask(title: "Re-run ablation")).id!
        let outcome = await run(["run", "--task", String(id), "--", "codex", "exec", "fix it"], childStatus: 3)

        #expect(outcome.status == 3)
        #expect(children.commands.withLock { $0 } == [["codex", "exec", "fix it"]])
        let agent = try #require(try await repository.reportedAgents().first)
        #expect(agent.source == .run)
        #expect(agent.label == "codex")
        #expect(agent.taskID == id)
        #expect(agent.reportedState == .failed)
        #expect(agent.lastMessage == "Exited with status 3.")
        #expect(try await repository.reviewQueue().first?.agentState == .failed)
    }

    @Test func aSuccessfulRunIsReady() async throws {
        try await startApp()
        let outcome = await run(["run", "--name", "tests", "--", "swift", "test"], childStatus: 0)
        #expect(outcome.status == 0)
        let agent = try #require(try await repository.reportedAgents().first)
        #expect(agent.label == "tests")
        #expect(agent.reportedState == .ready)
    }

    @Test func aRunStoppedBySignalSaysSo() async throws {
        try await startApp()
        #expect(await run(["run", "--", "sleep", "100"], childStatus: 130).status == 130)
        #expect(try await repository.reportedAgents().first?.lastMessage == "Stopped by signal 2.")
    }

    @Test func withMonitoringOffNothingRuns() async throws {
        try await startApp(monitoring: false)
        let outcome = await run(["run", "--", "codex"])
        #expect(outcome.status == 1)
        #expect(outcome.error.contains("agent monitoring is off"))
        #expect(outcome.error.hasSuffix("The command was not run.\n"))
        #expect(children.commands.withLock { $0 }.isEmpty)
    }

    @Test func aCommandThatCannotStartFails() async throws {
        try await startApp()
        let outcome = await run(["run", "--", "no-such-tool"], childStatus: nil)
        #expect(outcome.status == 127)
        #expect(try await repository.reportedAgents().first?.reportedState == .failed)
    }

    @Test func runNeedsACommand() async {
        #expect(await run(["run"]).status == 2)
        #expect(await run(["run", "--task"]).status == 2)
        #expect(await run(["run", "--task", "0", "--", "x"]).status == 2)
    }

    // MARK: The real child

    @Test func theRealChildReturnsItsExitStatus() {
        #expect(ChildProcess.run(["/bin/sh", "-c", "exit 7"]) == 7)
        #expect(ChildProcess.run(["true"]) == 0)
        #expect(ChildProcess.run(["/bin/sh", "-c", "kill -TERM $$"]) == 128 + SIGTERM)
        #expect(ChildProcess.run(["focuspilot-no-such-command-here"]) == nil)
    }
}

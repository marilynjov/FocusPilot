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

    private func run(_ arguments: [String], stdin: String = "", child: ChildExit? = .exited(0),
                     environment: [String: String] = ["TERM_PROGRAM": "WarpTerminal"]) async -> FocusPilotCommand.Outcome {
        let children = children
        let system = AgentCommandSystem(standardInput: { Data(stdin.utf8) }, controllingTerminal: { "/dev/ttys004" },
                                        currentDirectory: { "/Users/owner/thesis" },
                                        runChild: { command in children.commands.withLock { $0.append(command) }; return child },
                                        newRunID: { "run-1" }, clock: { wednesdayMorningInBogota })
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

    // MARK: FOCUSPILOT_TASK

    @Test func aHookInAWindowFocusPilotStartedReportsLinkedToItsTask() async throws {
        try await startApp()
        let id = try await repository.addTask(NewTask(title: "Write chapter 2")).id!
        let outcome = await run(["agent", "report", "--from-claude-hook", "Stop"], stdin: stopPayload,
                                environment: ["TERM_PROGRAM": "WarpTerminal", "FOCUSPILOT_TASK": String(id)])

        #expect(outcome == FocusPilotCommand.Outcome(status: 0))
        #expect(try await repository.reportedAgents().first?.taskID == id)
    }

    @Test func taskWinsOverTheEnvironment() async throws {
        try await startApp()
        let named = try await repository.addTask(NewTask(title: "Named")).id!
        let fromEnvironment = try await repository.addTask(NewTask(title: "From environment")).id!
        let environment = ["FOCUSPILOT_TASK": String(fromEnvironment)]

        let outcome = await run(["agent", "report", "working", "--name", "a", "--task", String(named)], environment: environment)
        #expect(outcome.output == "Reported a: Working, for “Named”.\n")
        _ = await run(["agent", "report", "working", "--name", "b"], environment: environment)
        let agents = try await repository.reportedAgents()
        #expect(agents.first { $0.label == "a" }?.taskID == named)
        #expect(agents.first { $0.label == "b" }?.taskID == fromEnvironment)
    }

    @Test func aBadTaskInTheEnvironmentIsOnlyNoted() async throws {
        try await startApp()
        for value in ["12; rm -rf ~", "0", "-3"] {
            let outcome = await run(["agent", "report", "working", "--name", "a"], environment: ["FOCUSPILOT_TASK": value])
            #expect(outcome.status == 0)
            #expect(outcome.error == "Note: Ignored FOCUSPILOT_TASK: it isn’t a task number.\n")
        }
        let hook = await run(["agent", "report", "--from-claude-hook", "Stop"], stdin: stopPayload,
                             environment: ["FOCUSPILOT_TASK": "x"])
        #expect(hook.status == 0)
        #expect(hook.output.isEmpty)
        // A task that doesn't exist links nothing, as with --task.
        _ = await run(["agent", "report", "working", "--name", "c"], environment: ["FOCUSPILOT_TASK": "999"])
        #expect(try await repository.reportedAgents().allSatisfy { $0.taskID == nil })
    }

    @Test func theOwnersUnlinkHoldsAgainstTheEnvironment() async throws {
        try await startApp()
        let id = try await repository.addTask(NewTask(title: "Write chapter 2")).id!
        let environment = ["FOCUSPILOT_TASK": String(id)]
        _ = await run(["agent", "report", "--from-claude-hook", "Stop"], stdin: stopPayload, environment: environment)
        let agent = try #require(try await repository.reportedAgents().first)
        try await repository.linkReportedAgent(agent.id, toTask: nil)

        _ = await run(["agent", "report", "--from-claude-hook", "Stop"], stdin: stopPayload, environment: environment)
        #expect(try await repository.reportedAgents().first?.taskID == nil)
    }

    @Test func theWindowTokenIsStoredAndKeptByReportsWithout() async throws {
        try await startApp()
        let id = try await repository.addTask(NewTask(title: "Work")).id!
        _ = await run(["agent", "report", "--from-claude-hook", "Stop"], stdin: stopPayload,
                      environment: ["FOCUSPILOT_TASK": String(id), "FOCUSPILOT_WINDOW": "3fa9c01b"])
        #expect(try await repository.reportedAgents().first?.warpWindow == "3fa9c01b")
        // The same chat reporting from its old tab, without the variable, keeps it.
        _ = await run(["agent", "report", "--from-claude-hook", "Stop"], stdin: stopPayload)
        let agent = try #require(try await repository.reportedAgents().first)
        #expect(agent.warpWindow == "3fa9c01b")
        #expect(agent.taskID == id)

        _ = await run(["agent", "report", "working", "--name", "a"], environment: ["FOCUSPILOT_WINDOW": "0000000a"])
        #expect(try await repository.reportedAgents().first { $0.label == "a" }?.warpWindow == "0000000a")
    }

    @Test func aBadWindowTokenIsOnlyNoted() async throws {
        try await startApp()
        for value in ["../../etc/passwd", "3FA9C01B", "3fa9c01b; rm -rf ~"] {
            let outcome = await run(["agent", "report", "working", "--name", "a"], environment: ["FOCUSPILOT_WINDOW": value])
            #expect(outcome.status == 0)
            #expect(outcome.error == "Note: Ignored FOCUSPILOT_WINDOW: it isn’t valid.\n")
        }
        let hook = await run(["agent", "report", "--from-claude-hook", "Stop"], stdin: stopPayload,
                             environment: ["FOCUSPILOT_WINDOW": "x"])
        #expect(hook.status == 0)
        #expect(hook.output.isEmpty)
        #expect(try await repository.reportedAgents().allSatisfy { $0.warpWindow == nil })
    }

    // MARK: run

    @Test func runReportsWorkingThenTheExitStatus() async throws {
        try await startApp()
        let id = try await repository.addTask(NewTask(title: "Re-run ablation")).id!
        let outcome = await run(["run", "--task", String(id), "--", "codex", "exec", "fix it"], child: .exited(3))

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
        let outcome = await run(["run", "--name", "tests", "--", "swift", "test"], child: .exited(0))
        #expect(outcome.status == 0)
        let agent = try #require(try await repository.reportedAgents().first)
        #expect(agent.label == "tests")
        #expect(agent.reportedState == .ready)
    }

    @Test func aRunStoppedBySignalSaysSo() async throws {
        try await startApp()
        let outcome = await run(["run", "--", "sleep", "100"], child: .signaled(SIGINT))
        #expect(outcome.status == 130)
        #expect(outcome.raisesSignal == SIGINT)
        #expect(try await repository.reportedAgents().first?.lastMessage == "Stopped by signal 2.")
    }

    @Test func aLostChildIsAnErrorNotAStatus() async throws {
        try await startApp()
        let outcome = await run(["run", "--", "x"], child: .waitFailed(ECHILD))
        #expect(outcome.status == 1)
        #expect(outcome.error.contains("couldn’t wait for x"))
        #expect(try await repository.reportedAgents().first?.reportedState == .failed)
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
        let outcome = await run(["run", "--", "no-such-tool"], child: nil)
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
        #expect(ChildProcess.run(["/bin/sh", "-c", "exit 7"]) == .exited(7))
        #expect(ChildProcess.run(["true"]) == .exited(0))
        #expect(ChildProcess.run(["/bin/sh", "-c", "kill -TERM $$"]) == .signaled(SIGTERM))
        #expect(ChildProcess.run(["focuspilot-no-such-command-here"]) == nil)
    }
}

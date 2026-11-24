import Darwin
import Foundation

/// What `agent report` and `run` need from the process around them, so
/// tests can stand in for stdin, the terminal and the child.
public struct AgentCommandSystem: Sendable {
    /// The hook's JSON, at most `ClaudeHookEvent.payloadLimit` bytes and one more.
    public var standardInput: @Sendable () -> Data
    /// The controlling terminal's device, e.g. "/dev/ttys003", if any.
    public var controllingTerminal: @Sendable () -> String?
    public var currentDirectory: @Sendable () -> String
    /// Runs the command with the terminal and says how it ended, or nil if
    /// it could not be started.
    public var runChild: @Sendable ([String]) -> ChildExit?
    /// A new ID for one run.
    public var newRunID: @Sendable () -> String
    /// The time now, for a run's final report.
    public var clock: @Sendable () -> Date

    public init(standardInput: @escaping @Sendable () -> Data, controllingTerminal: @escaping @Sendable () -> String?,
                currentDirectory: @escaping @Sendable () -> String, runChild: @escaping @Sendable ([String]) -> ChildExit?,
                newRunID: @escaping @Sendable () -> String, clock: @escaping @Sendable () -> Date = Date.init) {
        self.standardInput = standardInput
        self.controllingTerminal = controllingTerminal
        self.currentDirectory = currentDirectory
        self.runChild = runChild
        self.newRunID = newRunID
        self.clock = clock
    }

    public static let live = AgentCommandSystem(
        standardInput: { (try? FileHandle.standardInput.read(upToCount: ClaudeHookEvent.payloadLimit + 1)) ?? Data() },
        controllingTerminal: ChildProcess.controllingTerminal,
        currentDirectory: { FileManager.default.currentDirectoryPath },
        runChild: ChildProcess.run,
        newRunID: { UUID().uuidString })
}

/// `focuspilot agent report` and `focuspilot run` (decision 0005, step 1).
/// They only report status; FocusPilot never answers, prompts or stops the
/// agent. Usage errors exit 2, except from a Claude Code hook: there exit 2
/// on Stop would keep Claude from stopping (code.claude.com/docs/en/hooks),
/// so hook mode exits 0 or 1 only and never prints to stdout, which Claude
/// Code could read as a decision or as context.
extension FocusPilotCommand {
    /// The options `agent report` and `run` take, as given.
    struct AgentOptions {
        var name: String?
        var folder: String?
        var summary: String?
        var terminal: String?
        var tty: String?
        var session: String?
        var task: String?
        var hookEvent: String?
    }

    /// Reads `--option value` pairs up to `--` or the first other word,
    /// returning what is left. Nil for an unknown option or a missing value.
    static func agentOptions(_ arguments: ArraySlice<String>, allowed: Set<String>)
        -> (options: AgentOptions, rest: ArraySlice<String>)? {
        var options = AgentOptions()
        var rest = arguments
        while let word = rest.first, word.hasPrefix("-") {
            rest = rest.dropFirst()
            if word == "--" { return (options, rest) }
            guard allowed.contains(word), let value = rest.first else { return nil }
            rest = rest.dropFirst()
            switch word {
            case "--name": options.name = value
            case "--folder": options.folder = value
            case "--summary": options.summary = value
            case "--terminal": options.terminal = value
            case "--tty": options.tty = value
            case "--session": options.session = value
            case "--task": options.task = value
            case "--from-claude-hook": options.hookEvent = value
            default: return nil
            }
        }
        return (options, rest)
    }

    static let reportOptions: Set<String> = ["--name", "--folder", "--summary", "--terminal", "--tty", "--session", "--task"]

    // MARK: agent report

    func agentReport(_ arguments: [String]) -> Outcome {
        // Anywhere in the line: a hook must never get a usage error's exit 2.
        if arguments.contains("--from-claude-hook") {
            return claudeHookReport(arguments[...])
        }
        guard let word = arguments.first, let status = AgentReport.Status(rawValue: word),
              let (options, rest) = Self.agentOptions(arguments.dropFirst(), allowed: Self.reportOptions), rest.isEmpty
        else { return Outcome(status: 2, error: Self.usage) }
        guard let name = options.name else {
            return Outcome(status: 2, error: "The report needs --name <label>.\n\n" + Self.usage)
        }
        var taskID: Int64?
        var notes: [String] = []
        if let task = options.task {
            guard let id = Int64(task), id > 0 else { return Outcome(status: 2, error: "--task needs a task number.\n") }
            taskID = id
        } else {
            (taskID, notes) = taskFromEnvironment()
        }
        let report = AgentReport(
            source: .command, status: status, label: name, key: options.session,
            folder: options.folder.map(absolute) ?? system.currentDirectory(), summary: options.summary,
            terminal: terminalPlace(app: options.terminal, tty: options.tty, session: options.session), taskID: taskID,
            reportedAt: now, warpWindow: warpWindowFromEnvironment)
        return send(report, notesOnly: false, notes: notes)
    }

    /// The task in `FOCUSPILOT_TASK`, set for Claude Code in a Warp window
    /// FocusPilot started for a task (`WarpLaunch`), so its reports come
    /// already linked. Checked like `--task`, but a bad value is only noted:
    /// the owner didn't type it. As with `--task`, the app links only to an
    /// open task, and never against the owner's own link or unlink.
    /// The Warp window FocusPilot opened for this agent, from
    /// `FOCUSPILOT_WINDOW`. Untrusted like the rest: `sanitized()` keeps only
    /// a token's exact form and notes anything else.
    private var warpWindowFromEnvironment: String? {
        environment[WarpLaunch.windowVariable].flatMap { $0.isEmpty ? nil : $0 }
    }

    private func taskFromEnvironment() -> (Int64?, notes: [String]) {
        guard let value = environment[WarpLaunch.taskVariable], !value.isEmpty else { return (nil, []) }
        guard let id = Int64(value), id > 0 else {
            return (nil, ["Ignored \(WarpLaunch.taskVariable): it isn’t a task number."])
        }
        return (id, [])
    }

    /// `--from-claude-hook <event> [--name <label>]`, with the hook's JSON on stdin.
    private func claudeHookReport(_ arguments: ArraySlice<String>) -> Outcome {
        guard let (options, rest) = Self.agentOptions(arguments, allowed: ["--from-claude-hook", "--name"]), rest.isEmpty,
              let name = options.hookEvent
        else { return Outcome(status: 1, error: "focuspilot: use --from-claude-hook <event> [--name <label>].\n") }
        guard let event = ClaudeHookEvent(rawValue: name) else {
            let known = ClaudeHookEvent.allCases.map(\.rawValue).joined(separator: ", ")
            return Outcome(status: 1, error: "focuspilot: \(name) isn’t a hook FocusPilot listens to (\(known)).\n")
        }
        switch event.outcome(payload: system.standardInput(), name: options.name,
                             terminal: terminalPlace(app: nil, tty: nil, session: nil)) {
        case .ignore: return Outcome(status: 0)
        case .unreadable: return Outcome(status: 1, error: "focuspilot: the hook's JSON on stdin could not be read.\n")
        case .report(var report):
            // `now` was taken when the process started, before stdin was read.
            report.reportedAt = now
            let (taskID, notes) = taskFromEnvironment()
            report.taskID = taskID
            report.warpWindow = warpWindowFromEnvironment
            return send(report, notesOnly: true, notes: notes)
        }
    }

    /// Sends the report. `notesOnly` (hook mode) keeps stdout empty and
    /// turns every failure into status 1.
    private func send(_ raw: AgentReport, notesOnly: Bool, notes earlier: [String] = []) -> Outcome {
        let report: AgentReport
        var notes: [String]
        do {
            (report, notes) = try raw.sanitized()
            notes = earlier + notes
        } catch {
            return Outcome(status: notesOnly ? 1 : 2, error: "The report needs a --name with some text in it.\n")
        }
        let noteText = notes.map { "Note: \($0)\n" }.joined()
        switch deliver(report) {
        case .success(let receipt):
            if notesOnly { return Outcome(status: 0, error: noteText) }
            let task = receipt.taskTitle.map { "for “\($0)”" } ?? "not linked to a task yet"
            return Outcome(status: 0, output: "Reported \(receipt.label): \(receipt.state.title), \(task).\n",
                           error: noteText)
        case .failure(let message):
            return Outcome(status: 1, error: noteText + message + "\n")
        }
    }

    private enum Delivery {
        case success(AgentReportReceipt)
        case failure(String)
    }

    private func deliver(_ report: AgentReport) -> Delivery {
        do {
            switch try CommandSocketClient(path: location.commandSocketPath).send(.agentReport(report)) {
            case .agentRecorded(let receipt): return .success(receipt)
            case .refused(let message), .failed(let message): return .failure(message)
            case .added, .tasks, .exception, .exceptionCancelled: return .failure("FocusPilot gave an unexpected answer.")
            }
        } catch .pathTooLong {
            return .failure("The FocusPilot data folder path is too long for its socket.")
        } catch {
            // Reports are not queued: an old status is worse than none.
            return .failure("FocusPilot is not running, so the report was not recorded.")
        }
    }

    /// The terminal as given, else as this process's environment and
    /// controlling terminal say.
    private func terminalPlace(app: String?, tty: String?, session: String?) -> TerminalPlace {
        TerminalPlace(app: app ?? environment["TERM_PROGRAM"].flatMap { $0.isEmpty ? nil : $0 },
                      tty: tty ?? system.controllingTerminal(),
                      sessionID: session ?? ["ITERM_SESSION_ID", "TERM_SESSION_ID"].lazy
                        .compactMap { environment[$0] }.first { !$0.isEmpty })
    }

    private func absolute(_ path: String) -> String {
        path.hasPrefix("/") ? path : (system.currentDirectory() as NSString).appendingPathComponent(path)
    }

    // MARK: run

    func runCommand(_ arguments: [String]) -> Outcome {
        guard let (options, command) = Self.agentOptions(arguments[...], allowed: ["--task", "--name"]),
              let program = command.first
        else { return Outcome(status: 2, error: Self.usage) }
        var taskID: Int64?
        if let task = options.task {
            guard let id = Int64(task), id > 0 else { return Outcome(status: 2, error: "--task needs a task number.\n") }
            taskID = id
        }
        let label = options.name ?? (program as NSString).lastPathComponent
        var report = AgentReport(source: .run, status: .working, label: label, key: system.newRunID(),
                                 folder: system.currentDirectory(), terminal: terminalPlace(app: nil, tty: nil, session: nil),
                                 taskID: taskID, reportedAt: now)
        // Nothing runs unless FocusPilot took the first report: with
        // monitoring off the owner hears why at once, not after the run.
        guard let (clean, _) = try? report.sanitized() else {
            return Outcome(status: 2, error: "The run needs a --name with some text in it.\n")
        }
        report = clean
        if case .failure(let message) = deliver(report) {
            return Outcome(status: 1, error: "focuspilot run: \(message) The command was not run.\n")
        }
        let exit = system.runChild(Array(command))
        report.reportedAt = system.clock()
        var outcome: Outcome
        switch exit {
        case nil:
            report.status = .failed
            report.summary = "Could not start \(program)."
            outcome = Outcome(status: 127, error: "focuspilot run: \(program): command not found or not runnable.\n")
        case .exited(let status):
            report.status = status == 0 ? .done : .failed
            report.summary = "Exited with status \(status)."
            outcome = Outcome(status: status)
        case .signaled(let signal):
            report.status = .failed
            report.summary = "Stopped by signal \(signal)."
            // Ended the same way as the child, so a shell or script sees it.
            outcome = Outcome(status: 128 + signal, raisesSignal: signal)
        case .waitFailed(let error):
            report.status = .failed
            report.summary = "FocusPilot lost track of the command."
            outcome = Outcome(status: 1, error: "focuspilot run: couldn’t wait for \(program): \(String(cString: strerror(error))).\n")
        }
        if case .failure(let message) = deliver(report) {
            outcome.error += "focuspilot run: the result was not recorded: \(message)\n"
        }
        return outcome
    }
}

/// How `focuspilot run`'s child ended.
public enum ChildExit: Equatable, Sendable {
    case exited(Int32)
    case signaled(Int32)
    /// `waitpid` failed with this errno; how the child ended is unknown.
    case waitFailed(Int32)
}

/// The child of `focuspilot run`, and the terminal it shares.
enum ChildProcess {
    /// Runs `command` (looked up on the PATH) with this process's terminal,
    /// environment and folder, and waits for it. Ctrl-C and Ctrl-\ go to the
    /// child, as they would without focuspilot; this process ignores them
    /// meanwhile so it can still report how the child ended. Nil if it
    /// could not be started.
    static let run: @Sendable ([String]) -> ChildExit? = { command in
        var attributes = posix_spawnattr_t(nil as OpaquePointer?)
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for signal in [SIGINT, SIGQUIT, SIGTSTP, SIGPIPE] { sigaddset(&defaults, signal) }
        var empty = sigset_t()
        sigemptyset(&empty)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        posix_spawnattr_setsigmask(&attributes, &empty)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))

        let previousInterrupt = signal(SIGINT, SIG_IGN)
        let previousQuit = signal(SIGQUIT, SIG_IGN)
        defer {
            signal(SIGINT, previousInterrupt)
            signal(SIGQUIT, previousQuit)
        }
        var arguments = command.map { strdup($0) } + [nil]
        defer { arguments.forEach { free($0) } }
        var pid = pid_t()
        guard posix_spawnp(&pid, command[0], nil, &attributes, &arguments, environ) == 0 else { return nil }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 {
            guard errno == EINTR else { return .waitFailed(errno) }
        }
        // WIFEXITED / WEXITSTATUS / WTERMSIG, which Swift does not import.
        let signal = status & 0x7f
        return signal == 0 ? .exited((status >> 8) & 0xff) : .signaled(signal)
    }

    /// The controlling terminal's device, from the kernel's view of this
    /// process, so it is found even when stdin is a pipe, as in a hook.
    static let controllingTerminal: @Sendable () -> String? = {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &info, size) == size, info.e_tdev != UInt32.max,
              let name = devname(dev_t(bitPattern: info.e_tdev), S_IFCHR)
        else { return nil }
        return "/dev/" + String(cString: name)
    }
}

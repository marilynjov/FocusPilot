import Foundation

/// The `focuspilot` command: adds a task or reads tasks from a Herdr pane,
/// and lets agents report their status (`agent report`, `run`; see
/// `FocusPilotCommand+Agents.swift`).
///
/// It never writes the database itself. Adds go to the running app over the
/// owner-only socket, or into the inbox when the app is closed. There is no
/// command that changes Now, the order, deadlines or an existing task.
public struct FocusPilotCommand: Sendable {
    public struct Outcome: Equatable, Sendable {
        public var status: Int32
        public var output = ""
        public var error = ""
    }

    public static let usage = """
        Usage:
          focuspilot add [--json] [--] <text>
                                           Add a task to the end of Next, marked from Herdr.
                                           A trailing deadline is read like quick capture:
                                           focuspilot add "Re-run ablation by fri 23:59"
                                           Options go before the text; after -- everything is text.
          focuspilot tasks [--json]        Show the owner's Now and this workspace's project.
          focuspilot agent report <working|needs-input|done|failed> --name <label>
                                  [--folder <path>] [--summary <text>] [--task <id>]
                                  [--terminal <app>] [--tty <device>] [--session <id>]
                                           Tell FocusPilot what an agent is doing. The folder
                                           defaults to this one; the terminal to this one.
          focuspilot agent report --from-claude-hook <event> [--name <label>]
                                           For Claude Code hooks: reads the hook's JSON on stdin.
          focuspilot run [--task <id>] [--name <label>] -- <command> [args...]
                                           Runs the command here, reporting it working, then
                                           done or failed by its exit status, which it returns.

        Tasks go to the project linked to this Herdr workspace, or to No project.
        focuspilot cannot change Now, the order, deadlines or existing tasks.
        Agent reports need Agent monitoring on in FocusPilot's settings.

        """

    let location: StorageLocation
    let environment: [String: String]
    private let now: Date
    private let timeZone: TimeZone
    private let socketCreationDate: @Sendable (URL) -> Date?
    /// What the process and its terminal give agent reports; tests replace them.
    let system: AgentCommandSystem

    public init(location: StorageLocation, environment: [String: String], now: Date, timeZone: TimeZone,
                socketCreationDate: @escaping @Sendable (URL) -> Date? = {
                    try? FileManager.default.attributesOfItem(atPath: $0.path)[.creationDate] as? Date
                },
                system: AgentCommandSystem = .live) {
        self.location = location
        self.environment = environment
        self.now = now
        self.timeZone = timeZone
        self.socketCreationDate = socketCreationDate
        self.system = system
    }

    public func run(_ arguments: [String]) -> Outcome {
        switch arguments.first {
        case "add":
            guard let (json, text) = Self.options(before: arguments.dropFirst()) else {
                return Outcome(status: 2, error: Self.usage)
            }
            return add(text.joined(separator: " "), json: json)
        case "tasks":
            guard let (json, rest) = Self.options(before: arguments.dropFirst()), rest.isEmpty else {
                return Outcome(status: 2, error: Self.usage)
            }
            return tasks(json: json)
        case "agent":
            guard arguments.dropFirst().first == "report" else { return Outcome(status: 2, error: Self.usage) }
            return agentReport(Array(arguments.dropFirst(2)))
        case "run":
            return runCommand(Array(arguments.dropFirst()))
        case "help", "--help", "-h": return Outcome(status: 0, output: Self.usage)
        default: return Outcome(status: 2, error: Self.usage)
        }
    }

    /// Reads options up to the first word that is not one, or up to `--`;
    /// the rest is the task text, kept as typed even if it contains
    /// "--json". Nil for an unknown option.
    private static func options(before arguments: ArraySlice<String>) -> (json: Bool, rest: ArraySlice<String>)? {
        var json = false
        var rest = arguments
        while let word = rest.first, word.hasPrefix("-") {
            rest = rest.dropFirst()
            switch word {
            case "--": return (json, rest)
            case "--json": json = true
            default: return nil
            }
        }
        return (json, rest)
    }

    // MARK: add

    private func add(_ text: String, json: Bool) -> Outcome {
        let request = HerdrAddRequest(text: text, capturedAt: now, timeZone: timeZone, caller: caller)
        guard request.capture.task.isValid else {
            return Outcome(status: 2, error: "Nothing to add: the task needs a title.\n\n" + Self.usage)
        }
        do {
            switch try CommandSocketClient(path: location.commandSocketPath).send(.add(request)) {
            case .added(let result): return added(result, json: json)
            case .refused(let message), .failed(let message): return Outcome(status: 1, error: message + "\n")
            case .tasks, .exception, .exceptionCancelled, .agentRecorded: return Outcome(status: 1, error: "FocusPilot gave an unexpected answer.\n")
            }
        } catch .pathTooLong {
            return Outcome(status: 1, error: "The FocusPilot data folder path is too long for its socket.\n")
        } catch {
            // Not running, or no reply: queue it. If the app did save it, the
            // request ID keeps the import from adding it twice.
            return queue(request, json: json)
        }
    }

    private func added(_ result: HerdrAddResult, json: Bool) -> Outcome {
        if json {
            return Outcome(status: 0, output: Self.json([
                "status": result.wasAlreadyAdded ? "alreadyAdded" : "added", "title": result.title,
                "project": result.projectTitle ?? NSNull(), "deadline": result.deadlineDescription ?? NSNull(),
                "hints": result.hints,
            ]))
        }
        let place = result.projectTitle.map { "in \($0)" } ?? "under No project"
        var lines = [result.wasAlreadyAdded
            ? "Already added: “\(result.title)” is in Next \(place), marked from Herdr."
            : "Added “\(result.title)” to the end of Next \(place), marked from Herdr."]
        if let deadline = result.deadlineDescription { lines.append("Deadline: \(deadline)") }
        if result.workspaceHasNoProject { lines.append("This Herdr workspace has no linked project in FocusPilot.") }
        if caller == nil { lines.append("Not run from a Herdr pane, so no project was chosen.") }
        lines += result.hints.map { "Note: \($0)" }
        return Outcome(status: 0, output: lines.joined(separator: "\n") + "\n")
    }

    private func queue(_ request: HerdrAddRequest, json: Bool) -> Outcome {
        do {
            try location.inbox.enqueue(request)
        } catch TaskInbox.Refusal.rateLimited {
            return Outcome(status: 1, error: CommandService.rateLimitMessage + "\n")
        } catch {
            return Outcome(status: 1, error: "FocusPilot is not running and the task could not be queued: \(error.localizedDescription)\n")
        }
        let (task, hints) = request.capture
        if json {
            return Outcome(status: 0, output: Self.json(["status": "queued", "title": task.title, "hints": hints]))
        }
        let lines = ["FocusPilot is not running. Queued “\(task.title)”; it will be added when FocusPilot starts."]
            + hints.map { "Note: \($0)" }
        return Outcome(status: 0, output: lines.joined(separator: "\n") + "\n")
    }

    // MARK: tasks

    private func tasks(json: Bool) -> Outcome {
        let scope: HerdrTaskScope
        do {
            switch try CommandSocketClient(path: location.commandSocketPath).send(.tasks(caller)) {
            case .tasks(let answer): scope = answer
            case .refused(let message), .failed(let message): return Outcome(status: 1, error: message + "\n")
            case .added, .exception, .exceptionCancelled, .agentRecorded: return Outcome(status: 1, error: "FocusPilot gave an unexpected answer.\n")
            }
        } catch .pathTooLong {
            return Outcome(status: 1, error: "The FocusPilot data folder path is too long for its socket.\n")
        } catch {
            return json ? Outcome(status: 3, output: Self.json(["running": false]))
                : Outcome(status: 3, error: "FocusPilot is not running, so tasks can’t be read.\n")
        }
        if json {
            return Outcome(status: 0, output: Self.json([
                "running": true, "now": scope.now.map(Self.dictionary) ?? NSNull(),
                "project": scope.projectTitle ?? NSNull(), "tasks": scope.tasks.map(Self.dictionary),
            ]))
        }
        var lines: [String] = []
        if let now = scope.now {
            lines.append("Now: \(now.title)")
            if let action = now.nextAction { lines.append("  Next action: \(action)") }
            if let deadline = now.deadline { lines.append("  Due \(deadline)") }
        } else {
            lines.append("Now: nothing pinned")
        }
        lines.append("")
        if let project = scope.projectTitle {
            lines.append("\(project) (this workspace’s project)")
            if scope.tasks.isEmpty { lines.append("  No open tasks") }
            for task in scope.tasks {
                let details = [task.deadline.map { "due \($0)" }, task.isFromHerdr ? "from Herdr" : nil].compactMap(\.self)
                let status = task.status.rawValue.capitalized.padding(toLength: 6, withPad: " ", startingAt: 0)
                lines.append("  \(status) " + ([task.title] + details).joined(separator: " · "))
            }
        } else if caller == nil {
            lines.append("Not run from a Herdr pane, so only Now is shown.")
        } else {
            lines.append("This Herdr workspace has no linked project in FocusPilot, so only Now is shown.")
        }
        return Outcome(status: 0, output: lines.joined(separator: "\n") + "\n")
    }

    // MARK: Helpers

    /// The pane this command runs in, from the variables Herdr exports into
    /// its panes. The server is identified like `HerdrCLI` does, by its
    /// socket's creation time.
    private var caller: HerdrCaller? {
        guard let workspace = environment["HERDR_WORKSPACE_ID"], !workspace.isEmpty else { return nil }
        let home = environment["HOME"] ?? NSHomeDirectory()
        let socket = environment["HERDR_SOCKET_PATH"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.config/herdr/herdr.sock"
        guard let startedAt = socketCreationDate(URL(fileURLWithPath: socket)) else { return nil }
        let server = HerdrServer(sessionName: environment["HERDR_SESSION"] ?? "default", socketPath: socket, startedAt: startedAt)
        return HerdrCaller(server: server, workspaceID: workspace, paneID: environment["HERDR_PANE_ID"])
    }

    private static func dictionary(_ task: HerdrScopedTask) -> [String: Any] {
        ["title": task.title, "status": task.status.rawValue, "nextAction": task.nextAction ?? NSNull(),
         "deadline": task.deadline ?? NSNull(), "fromHerdr": task.isFromHerdr]
    }

    private static func json(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}

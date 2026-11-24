import Foundation

/// One status report from an agent, as it travels over the command socket
/// (decision 0005). Everything in it is untrusted: `sanitized()` is applied
/// by the CLI, for its notes, and again by the app, since any local process
/// can write to the socket.
public struct AgentReport: Codable, Equatable, Sendable {
    /// The four states a report can carry, named as on the command line.
    public enum Status: String, Codable, CaseIterable, Sendable {
        case working
        case needsInput = "needs-input"
        case done
        case failed

        public var state: ReportedAgentState {
            switch self {
            case .working: .working
            case .needsInput: .needsYou
            case .done: .ready
            case .failed: .failed
            }
        }
    }

    public var source: AgentSource
    public var status: Status
    public var label: String
    /// Identifies the agent across reports: Claude Code's session ID,
    /// `--session`, or a run's own ID; nil means the label and folder do.
    public var key: String?
    public var folder: String?
    public var summary: String?
    public var terminal: TerminalPlace
    /// The task named with `--task`; it wins over folder matching.
    public var taskID: Int64?
    /// The label was made up ("Claude Code · nlp") because the report
    /// carried none, so it never replaces one the agent gave before:
    /// Claude Code sends `session_title` only with some events.
    public var labelIsFallback: Bool
    /// When the CLI started, before it read the hook's stdin. Async hooks
    /// can arrive out of order, so the app orders reports by this, not by
    /// arrival. Nil means when it arrives.
    public var reportedAt: Date?
    /// The token of the Warp window FocusPilot opened for the agent, from
    /// `FOCUSPILOT_WINDOW` (`WarpLaunch`).
    public var warpWindow: String?

    public init(source: AgentSource, status: Status, label: String, key: String? = nil, folder: String? = nil,
                summary: String? = nil, terminal: TerminalPlace = TerminalPlace(), taskID: Int64? = nil,
                labelIsFallback: Bool = false, reportedAt: Date? = nil, warpWindow: String? = nil) {
        self.source = source
        self.status = status
        self.label = label
        self.key = key
        self.folder = folder
        self.summary = summary
        self.terminal = terminal
        self.taskID = taskID
        self.labelIsFallback = labelIsFallback
        self.reportedAt = reportedAt
        self.warpWindow = warpWindow
    }

    public static let labelLimit = 80
    public static let summaryLimit = 2000
    static let folderLimit = 1024
    static let keyLimit = 200

    public enum Invalid: Error, Equatable {
        /// Nothing printable was left of the label.
        case missingLabel
    }

    /// The report with text cleaned and capped and every optional field
    /// that does not look like what it claims dropped, plus a note for each
    /// one dropped. Only a missing label refuses the report.
    public func sanitized() throws(Invalid) -> (report: AgentReport, notes: [String]) {
        guard let label = AgentText.line(label, limit: Self.labelLimit) else { throw .missingLabel }
        var notes: [String] = []
        func keep(_ value: String?, _ name: String, _ check: (String) -> String?) -> String? {
            guard let value else { return nil }
            if let kept = check(value) { return kept }
            notes.append("Ignored \(name): it isn’t valid.")
            return nil
        }
        let folder = keep(folder, "--folder", AgentText.folder)
        let report = AgentReport(
            source: source, status: status, label: label,
            key: keep(key, "the session ID", { AgentText.identifier($0, limit: Self.keyLimit) }),
            folder: folder,
            summary: summary.flatMap { AgentText.paragraphs($0, limit: Self.summaryLimit) },
            terminal: TerminalPlace(app: keep(terminal.app, "--terminal", AgentText.terminalApp),
                                    tty: keep(terminal.tty, "--tty", AgentText.tty),
                                    sessionID: keep(terminal.sessionID, "--session",
                                                    { AgentText.identifier($0, limit: Self.keyLimit) })),
            taskID: taskID.flatMap { $0 > 0 ? $0 : nil }, labelIsFallback: labelIsFallback, reportedAt: reportedAt,
            warpWindow: keep(warpWindow, WarpLaunch.windowVariable, { WarpLaunch.isToken($0) ? $0 : nil }))
        if let taskID, taskID <= 0 { notes.append("Ignored --task: it isn’t valid.") }
        return (report, notes)
    }

    /// What tells this agent's reports apart from others from the same
    /// source: its key, else its label and folder. A terminal's session ID
    /// alone is not enough, since one tab can run several agents.
    var identity: String {
        key ?? "\(label)\u{1F}\(folder ?? "")"
    }
}

/// Cleaning for text that came from an agent. Nothing here is executed or
/// rendered as markup anyway; this keeps it short, on the lines it claims,
/// and free of characters that could disguise what it says.
enum AgentText {
    /// One line: control characters removed, whitespace runs collapsed,
    /// capped with an ellipsis. Nil when nothing is left.
    static func line(_ text: String, limit: Int) -> String? {
        let words = clean(text).split(whereSeparator: \.isWhitespace)
        return capped(words.joined(separator: " "), limit: limit)
    }

    /// Several lines are kept, each cleaned like `line`; runs of blank
    /// lines become one.
    static func paragraphs(_ text: String, limit: Int) -> String? {
        var lines: [String] = []
        for raw in clean(text, keepingNewlines: true).split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if line.isEmpty, lines.last?.isEmpty ?? true { continue }
            lines.append(line)
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return capped(lines.joined(separator: "\n"), limit: limit)
    }

    /// An absolute path with no control characters, standardized.
    static func folder(_ path: String) -> String? {
        guard path.hasPrefix("/"), path.utf8.count <= AgentReport.folderLimit, clean(path) == path,
              !path.contains("\n") else { return nil }
        let standard = (path as NSString).standardizingPath
        return standard.isEmpty ? nil : standard
    }

    /// `TERM_PROGRAM`: "WarpTerminal", "iTerm.app", "Apple_Terminal".
    static func terminalApp(_ name: String) -> String? {
        matches(name, maxLength: 64, extra: "._+-") ? name : nil
    }

    /// A terminal device: "/dev/ttys003", or "ttys003" as `tty` prints it without /dev.
    static func tty(_ device: String) -> String? {
        let path = device.hasPrefix("/dev/") ? device : "/dev/" + device
        let name = path.dropFirst("/dev/".count)
        guard name.hasPrefix("tty"), name.count > 3, matches(String(name), maxLength: 20, extra: "") else { return nil }
        return path
    }

    /// Session IDs and keys: UUIDs, iTerm2's "w0t0p0:UUID" and the like.
    static func identifier(_ value: String, limit: Int) -> String? {
        matches(value, maxLength: limit, extra: "._:/@+-") ? value : nil
    }

    private static func matches(_ value: String, maxLength: Int, extra: String) -> Bool {
        !value.isEmpty && value.count <= maxLength
            && value.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || extra.unicodeScalars.contains($0)) }
    }

    /// Removes control and format characters as `PlainText` does for
    /// Herdr output (bidi overrides could reorder what is shown, zero-width
    /// characters hide text); tabs become spaces, and line breaks spaces
    /// unless they are kept.
    static func clean(_ text: String, keepingNewlines: Bool = false) -> String {
        let lines = text.replacing("\r\n", with: "\n").replacing("\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { PlainText.removingInvisibles(String($0)).replacing("\t", with: " ") }
        return lines.joined(separator: keepingNewlines ? "\n" : " ")
    }

    private static func capped(_ text: String, limit: Int) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit - 1)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}

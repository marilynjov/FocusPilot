import Foundation

/// Which connection an agent's reports come through (decision 0005). Every
/// report keeps it, so the owner can see how FocusPilot knows.
public enum AgentSource: String, Codable, CaseIterable, Sendable {
    /// Claude Code's hooks, calling `focuspilot agent report --from-claude-hook`.
    case claudeCodeHook
    /// `focuspilot agent report` typed or scripted by hand.
    case command
    /// `focuspilot run -- <command>`, which reports by the child's exit status.
    case run

    /// "reported by Claude Code hook", shown next to the agent.
    public var provenance: String {
        switch self {
        case .claudeCodeHook: "reported by Claude Code hook"
        case .command: "reported with focuspilot agent report"
        case .run: "reported by focuspilot run"
        }
    }
}

/// A reported agent's state. Only the first four are ever stored; Unknown
/// is what a stored state turns into once it is too old to trust.
public enum ReportedAgentState: String, Codable, CaseIterable, Sendable {
    case working
    case needsYou
    /// Its turn or run finished. This says nothing about the task being done.
    case ready
    case failed
    /// No report for too long. Never shown as done.
    case unknown

    public var title: String {
        switch self {
        case .working: "Working"
        case .needsYou: "Needs you"
        case .ready: "Ready"
        case .failed: "Failed"
        case .unknown: "Unknown"
        }
    }
}

/// Where a reported agent runs, as its report said: the terminal app
/// (`TERM_PROGRAM`), the terminal device and the terminal's session ID.
/// Only used to bring that place forward when the owner clicks Go to agent.
public struct TerminalPlace: Codable, Equatable, Sendable {
    public var app: String?
    public var tty: String?
    public var sessionID: String?

    public init(app: String? = nil, tty: String? = nil, sessionID: String? = nil) {
        self.app = app
        self.tty = tty
        self.sessionID = sessionID
    }
}

/// An agent FocusPilot hears from directly (decision 0005, step 1), as
/// stored in the owner database: structured state, not a cache.
public struct ReportedAgent: Equatable, Sendable, Identifiable {
    public var id: Int64
    public var source: AgentSource
    /// What identifies it across reports: Claude Code's session ID, the
    /// `--session` given, or the label and folder.
    public var key: String
    public var label: String
    public var folder: String?
    public var taskID: Int64?
    /// The owner linked or unlinked it by hand, so folder matching leaves
    /// its task alone.
    public var isLinkedByOwner: Bool
    /// The last state reported; never `unknown`.
    public var reportedState: ReportedAgentState
    /// The last message or summary, as plain text.
    public var lastMessage: String?
    public var lastReportAt: Date
    /// When `reportedState` last changed.
    public var stateChangedAt: Date
    public var terminal: TerminalPlace

    public init(id: Int64, source: AgentSource, key: String, label: String, folder: String?, taskID: Int64?,
                isLinkedByOwner: Bool, reportedState: ReportedAgentState, lastMessage: String?, lastReportAt: Date,
                stateChangedAt: Date, terminal: TerminalPlace) {
        self.id = id
        self.source = source
        self.key = key
        self.label = label
        self.folder = folder
        self.taskID = taskID
        self.isLinkedByOwner = isLinkedByOwner
        self.reportedState = reportedState
        self.lastMessage = lastMessage
        self.lastReportAt = lastReportAt
        self.stateChangedAt = stateChangedAt
        self.terminal = terminal
    }

    /// A working agent that has not reported for this long may have been
    /// closed or crashed: it shows as Unknown.
    public static let workingStaleAfter: TimeInterval = 30 * 60
    /// An agent waiting for the owner is given longer, since the wait is
    /// the owner's, but not forever: its terminal may be gone.
    public static let needsYouStaleAfter: TimeInterval = 2 * 3600

    /// The state to show at `now`. Working and Needs you go Unknown without
    /// a report; Ready and Failed were the agent's last word and stay.
    public func state(at now: Date) -> ReportedAgentState {
        let age = now.timeIntervalSince(lastReportAt)
        switch reportedState {
        case .working: return age > Self.workingStaleAfter ? .unknown : .working
        case .needsYou: return age > Self.needsYouStaleAfter ? .unknown : .needsYou
        case .ready, .failed, .unknown: return reportedState
        }
    }

    /// When `state(at:)` next changes on its own, so a view can redraw then.
    public var goesUnknownAt: Date? {
        switch reportedState {
        case .working: lastReportAt.addingTimeInterval(Self.workingStaleAfter)
        case .needsYou: lastReportAt.addingTimeInterval(Self.needsYouStaleAfter)
        case .ready, .failed, .unknown: nil
        }
    }
}

/// What the app learns from a recorded report: the agent as it is now and
/// whether the owner has to hear about it at once.
public struct AgentReportReceipt: Codable, Equatable, Sendable {
    public var agentID: Int64
    public var label: String
    public var state: ReportedAgentState
    /// The report moved the agent into Needs you: the raccoon peeks at once.
    public var needsYouNow: Bool
    /// A finished or failed result went to the Review queue.
    public var queuedResult: Bool
    /// The task it is linked to, if any, for the CLI's answer.
    public var taskTitle: String?

    public init(agentID: Int64, label: String, state: ReportedAgentState, needsYouNow: Bool, queuedResult: Bool,
                taskTitle: String?) {
        self.agentID = agentID
        self.label = label
        self.state = state
        self.needsYouNow = needsYouNow
        self.queuedResult = queuedResult
        self.taskTitle = taskTitle
    }
}

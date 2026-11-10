import Foundation

/// A Herdr agent the owner linked to a task, as it was when linked, with
/// the last status FocusPilot was sure of.
public struct TaskAgentLink: Equatable, Sendable, Identifiable {
    public var id: Int64
    public var taskID: Int64
    public var server: HerdrServer
    public var paneID: String
    public var workspaceID: String
    public var tabID: String
    public var name: String?
    public var kind: String
    /// The agent's name, else its terminal title, else its kind.
    public var label: String
    public var workspaceLabel: String?
    /// Never `unknown`: an unknown reading keeps the previous status.
    public var lastStatus: HerdrAgentStatus?
    /// When FocusPilot last saw `lastStatus` change.
    public var statusChangedAt: Date

    public init(id: Int64, taskID: Int64, server: HerdrServer, paneID: String, workspaceID: String, tabID: String,
                name: String?, kind: String, label: String, workspaceLabel: String?, lastStatus: HerdrAgentStatus?,
                statusChangedAt: Date) {
        self.id = id
        self.taskID = taskID
        self.server = server
        self.paneID = paneID
        self.workspaceID = workspaceID
        self.tabID = tabID
        self.name = name
        self.kind = kind
        self.label = label
        self.workspaceLabel = workspaceLabel
        self.lastStatus = lastStatus
        self.statusChangedAt = statusChangedAt
    }

    /// Whether `agent` is still the agent that was linked: same server
    /// instance, same pane, same program and, if it had one, same name.
    func isSameAgent(as agent: HerdrAgent, on server: HerdrServer) -> Bool {
        server == self.server && agent.paneID == paneID && agent.kind == kind && (name == nil || agent.name == name)
    }
}

/// What can be said about a linked agent right now.
public enum AgentLinkState: Equatable, Sendable {
    case live(HerdrAgent)
    /// The same program in the pane under a new name. Probably the same
    /// agent renamed; the owner can relink it.
    case renamed(HerdrAgent)
    /// The pane now holds a different agent; the link no longer applies.
    case replaced
    /// The pane is gone, or Herdr restarted and its pane IDs were reissued.
    case notFound
    /// Herdr is not reachable, or has not been read yet.
    case unknown

    public init(_ link: TaskAgentLink, _ agents: HerdrAgents?) {
        guard case .connected(let server, let list)? = agents else {
            self = .unknown
            return
        }
        guard server == link.server, let current = list.first(where: { $0.paneID == link.paneID }) else {
            self = .notFound
            return
        }
        if link.isSameAgent(as: current, on: server) {
            self = .live(current)
        } else if current.kind == link.kind, link.name != nil, current.name != nil {
            self = .renamed(current)
        } else {
            self = .replaced
        }
    }
}

/// An agent result or approval request waiting for the owner.
public struct ReviewItem: Equatable, Sendable, Identifiable {
    public var id: Int64
    public var taskID: Int64
    public var taskTitle: String
    /// Nil once the agent was unlinked from the task.
    public var linkID: Int64?
    public var kind: AgentTransition.Review
    public var occurredAt: Date
    public var agentLabel: String
    public var workspaceLabel: String?
    /// The agent's terminal title when it happened.
    public var summary: String?
    /// The agent's visible screen, read once when the item was queued; for
    /// a reported agent, the summary it sent.
    public var output: AgentOutputPreview?
    /// Set for a reported agent's result (decision 0005), nil for Herdr's.
    /// The agent ID is nil once the agent was forgotten.
    public var reportedAgentID: Int64? = nil
    public var source: AgentSource? = nil
    /// A reported agent's result: Ready or Failed.
    public var agentState: ReportedAgentState? = nil
    /// When the owner first opened it in the Review queue; nil while it is
    /// unread (owner request, 2026-11-10).
    public var openedAt: Date? = nil
    /// An older result from an agent that has reported again since. Only an
    /// agent's newest result is unread (owner request, 2026-11-10).
    public var isSuperseded = false

    public var isUnread: Bool { openedAt == nil && !isSuperseded }

    /// Marks every result but each agent's newest as superseded. `items`
    /// are newest first, as the queue is. Approval requests are left alone:
    /// each still needs an answer.
    public static func markingSuperseded(_ items: [ReviewItem]) -> [ReviewItem] {
        var seen = Set<String>()
        return items.map { item in
            guard item.kind != .approval else { return item }
            var item = item
            item.isSuperseded = !seen.insert(item.agentKey).inserted
            return item
        }
    }

    /// The agent it came from: the reported agent or Herdr link, else its
    /// label once the agent was forgotten or unlinked.
    private var agentKey: String {
        if let reportedAgentID { return "reported:\(reportedAgentID)" }
        if let linkID { return "link:\(linkID)" }
        return "label:\(agentLabel)"
    }

    /// Unread or Read for a result; an approval request or a failure keeps
    /// its wording and adds Unread until opened (owner request, 2026-11-10).
    public var stateTitle: String {
        let state = kind == .approval ? "Needs your approval" : agentState == .failed ? "Failed" : nil
        guard let state else { return isUnread ? "Unread" : "Read" }
        return isUnread ? "\(state) · Unread" : state
    }
}

/// An item just queued, whose output is still to be read from `paneID`.
public struct NewReviewItem: Equatable, Sendable {
    public var id: Int64
    public var paneID: String
    public var server: HerdrServer
}

/// The agents offered when linking a task: those in the task's project's
/// workspace first and preselected, then the rest in Herdr's order. Agents
/// already linked to the task are left out. Nothing is linked until the
/// owner confirms.
public struct AgentLinkChoices: Equatable, Sendable {
    public var agents: [HerdrAgent]
    public var preselected: Set<String>

    public init(_ all: [HerdrAgent], on server: HerdrServer, projectLink: HerdrLink?, linked: [TaskAgentLink]) {
        let free = all.filter { agent in !linked.contains { $0.server == server && $0.paneID == agent.paneID } }
        let workspace = projectLink.flatMap { $0.server == server ? $0.workspaceID : nil }
        let inProject = free.filter { $0.workspaceID == workspace }
        agents = inProject + free.filter { $0.workspaceID != workspace }
        preselected = Set(inProject.map(\.paneID))
    }
}

import FocusPilotCore
import SwiftUI

/// The selected task's Agent section (design 01): its linked Herdr agents
/// and the agents that report themselves (decision 0005), their status,
/// and Open agent or Go to agent. Nothing here acts on its own; focusing a
/// pane or a terminal happens only when the owner clicks.
struct TaskAgentInspector: View {
    let model: AppModel
    let task: TodayItem
    var showReviewQueue: () -> Void
    @State private var isLinking = false

    private var links: [TaskAgentLink] { model.agentLinks.filter { $0.taskID == task.id } }
    private var reported: [ReportedAgent] { model.reportedAgents.filter { $0.taskID == task.id } }
    /// Reported agents with no task, offered for linking by hand.
    private var unlinked: [ReportedAgent] { model.reportedAgents.filter { $0.taskID == nil } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(task.title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                HStack {
                    Text("Agent")
                        .font(.caption.weight(.semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Link Agent…", systemImage: "plus") { isLinking = true }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
                if links.isEmpty && reported.isEmpty {
                    Text("No agent is linked to this task. Linked Herdr agents, and agents that report through Claude Code hooks or the focuspilot command, show here and their results go to Review queue.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(links) { link in
                        AgentLinkView(model: model, link: link,
                                      reviewCount: model.reviewItems.filter { $0.linkID == link.id }.count,
                                      showReviewQueue: showReviewQueue)
                    }
                    ForEach(reported) { agent in
                        ReportedAgentView(model: model, agent: agent,
                                          reviewCount: model.reviewItems.filter { $0.reportedAgentID == agent.id }.count,
                                          showReviewQueue: showReviewQueue)
                    }
                }
                if !unlinked.isEmpty {
                    UnlinkedAgentsView(model: model, agents: unlinked, taskID: task.id)
                }
                if let notice = model.agentNotice {
                    Label(notice, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $isLinking) {
            AgentLinkSheet(model: model, task: task)
        }
        .onChange(of: task.id) { model.agentNotice = nil }
    }
}

/// One linked agent: where it is, its state, and the owner's actions.
private struct AgentLinkView: View {
    let model: AppModel
    let link: TaskAgentLink
    let reviewCount: Int
    var showReviewQueue: () -> Void

    var body: some View {
        let state = AgentLinkState(link, model.herdrAgents)
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: "Herdr · \(link.workspaceLabel ?? link.workspaceID) › \(link.label)")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                AgentStateLabel(state: state)
                Text(verbatim: "· updated \(link.statusChangedAt.formatted(.relative(presentation: .named)))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if case .live(let agent) = state, let title = agent.title {
                // The agent's own terminal title: plain text, never markup.
                Text(verbatim: title)
                    .font(.callout)
                    .lineLimit(2)
            }
            Text("Results go to Review queue; nothing opens until you choose to.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Open agent") { Task { await model.openAgent(link.id) } }
                    .disabled(!state.canOpen)
                    .help("Shows this agent's pane in Herdr. Herdr then marks its result as seen.")
                if case .renamed = state {
                    Button("Relink") { Task { await model.relinkAgent(link.id) } }
                        .help("Keep following this agent under its new name.")
                }
                Spacer()
                Button("Unlink") { Task { await model.unlinkAgent(link.id) } }
                    .buttonStyle(.link)
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
        .contrastBorder(cornerRadius: 8)
    }
}

/// An agent that reports itself: its label and folder, how FocusPilot
/// knows (provenance), its state and last message, and the owner's actions.
/// The message is the agent's own text: plain, never markup.
private struct ReportedAgentView: View {
    let model: AppModel
    let agent: ReportedAgent
    let reviewCount: Int
    var showReviewQueue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Redrawn each minute, so Working turns Unknown without a report.
            TimelineView(.periodic(from: .now, by: 60)) { context in
                details(at: context.date)
            }
            buttons
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
        .contrastBorder(cornerRadius: 8)
    }

    /// One item for VoiceOver, like a Review queue row; the buttons stay apart.
    private func details(at now: Date) -> some View {
        let state = agent.state(at: now)
        let reported = agent.lastReportAt.formatted(.relative(presentation: .named, unitsStyle: .wide))
        return VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: [agent.label, agent.folder.map { ($0 as NSString).abbreviatingWithTildeInPath }]
                .compactMap(\.self).joined(separator: " · "))
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ReportedStateLabel(state: state)
                Text(verbatim: "· \(reported)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let message = agent.lastMessage {
                Text(verbatim: message)
                    .font(.callout)
                    .lineLimit(3)
            }
            Text(verbatim: "Last report \(agent.source.provenance). Results go to Review queue; nothing opens until you choose to.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([agent.label, agent.folder.map { "in \(($0 as NSString).lastPathComponent)" }, state.title,
                             "reported \(reported)", agent.lastMessage, agent.source.provenance]
            .compactMap(\.self).joined(separator: ", "))
    }

    /// Two short rows, so every button shows in the panel's width; results
    /// are reached from the sidebar's Review queue (owner feedback, 2026-11-10).
    private var buttons: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button("Go to agent") { Task { await model.goToAgent(agent.id, from: .panel) } }
                    .help("Brings the agent’s terminal forward: its exact tab in Terminal or iTerm2, or the app for Warp.")
                Spacer()
                Button("Unlink") { Task { await model.linkReportedAgent(agent.id, toTask: nil) } }
                    .buttonStyle(.link)
                    .accessibilityLabel("Unlink \(agent.label)")
            }
            if agent.terminal.app == "WarpTerminal", agent.folder != nil {
                Button("New Warp Tab Here") { model.openWarpTab(for: agent) }
                    .help("Opens a new Warp tab in the agent’s folder. It is a new tab, not the agent’s own.")
            }
        }
        .controlSize(.small)
    }
}

/// Reported agents no folder matched to a task, for the owner to link to
/// this one. Agents in the same folder later follow that choice.
private struct UnlinkedAgentsView: View {
    let model: AppModel
    let agents: [ReportedAgent]
    let taskID: Int64

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Not linked to a task")
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            ForEach(agents) { agent in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: agent.label)
                            .font(.callout.weight(.medium))
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            ReportedStateLabel(state: agent.state(at: context.date))
                                .foregroundStyle(.secondary)
                        }
                        if let folder = agent.folder {
                            Text(verbatim: (folder as NSString).abbreviatingWithTildeInPath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Spacer()
                    Button("Link Here") { Task { await model.linkReportedAgent(agent.id, toTask: taskID) } }
                        .help("Links this agent, and new agents in the same folder, to this task.")
                        .accessibilityLabel("Link \(agent.label) to this task")
                    Button("Remove", systemImage: "xmark") { Task { await model.forgetReportedAgent(agent.id) } }
                        .accessibilityLabel("Remove \(agent.label)")
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Forget this agent. It shows again if it reports.")
                }
                .controlSize(.small)
            }
        }
    }
}

/// "● Working", "● Needs you", "● Ready", "● Failed" or "○ Unknown".
struct ReportedStateLabel: View {
    let state: ReportedAgentState

    var body: some View {
        switch state {
        case .working: StatusDot(title: state.title, role: .accent, filled: true)
        case .needsYou: StatusDot(title: state.title, role: .blocked, filled: true)
        case .ready: StatusDot(title: state.title, role: .ready, filled: true)
        case .failed: StatusDot(title: state.title, role: .blocked, filled: false)
        // Unknown is never shown as done.
        case .unknown: StatusDot(title: state.title, role: .unknown, filled: false)
        }
    }
}

/// "● Working", "● Blocked", "● Ready" or "○ Unknown", or why the agent
/// cannot be seen.
struct AgentStateLabel: View {
    let state: AgentLinkState

    var body: some View {
        switch state {
        case .live(let agent): AgentActivityLabel(activity: agent.status.activity)
        case .renamed(let agent): dot("Renamed in Herdr to “\(agent.name ?? agent.kind)”", .blocked, filled: false)
        case .replaced: dot("Another agent in this pane", .blocked, filled: false)
        case .notFound: dot("Not found in Herdr", .blocked, filled: false)
        case .unknown: dot("Herdr unavailable", .unknown, filled: false)
        }
    }

    private func dot(_ title: String, _ role: PaletteRole, filled: Bool) -> some View {
        StatusDot(title: title, role: role, filled: filled)
    }
}

struct AgentActivityLabel: View {
    let activity: AgentActivity

    var body: some View {
        switch activity {
        case .working: StatusDot(title: "Working", role: .accent, filled: true)
        case .blocked: StatusDot(title: "Blocked", role: .blocked, filled: true)
        case .ready: StatusDot(title: "Ready", role: .ready, filled: true)
        // Unknown is never shown as done.
        case .unknown: StatusDot(title: "Unknown", role: .unknown, filled: false)
        }
    }
}

/// A status dot in the palette's status color; the label stays in the text
/// color, so it keeps text contrast whatever the dot's color.
struct StatusDot: View {
    let title: String
    let role: PaletteRole
    let filled: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: filled ? "circle.fill" : "circle")
                .font(.system(size: 8))
                .foregroundStyle(palette.color(role))
                .contrastOutline()
                .accessibilityHidden(true)
            Text(title)
                .font(.callout.weight(.medium))
        }
    }
}

extension AgentLinkState {
    var canOpen: Bool {
        if case .live = self { true } else { false }
    }
}

/// Chooses Herdr agents for a task. Agents in the task's project's
/// workspace come first, already ticked; nothing is linked until Link.
struct AgentLinkSheet: View {
    let model: AppModel
    let task: TodayItem
    @Environment(\.dismiss) private var dismiss
    @State private var agents: HerdrAgents?
    @State private var chosen: Set<String> = []

    private var choices: (server: HerdrServer, choices: AgentLinkChoices)? {
        guard case .connected(let server, let list)? = agents else { return nil }
        let projectLink = task.projectID.flatMap { id in model.projects.first { $0.id == id }?.herdrLink }
        return (server, AgentLinkChoices(list, on: server, projectLink: projectLink,
                                         linked: model.agentLinks.filter { $0.taskID == task.id }))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: "Link agents to “\(task.title)”")
                    .font(.headline)
                Text("FocusPilot reads their status every few seconds and queues their results for review. It never prompts an agent or answers its questions.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            Divider()
            content
                .frame(height: 280)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(chosen.count > 1 ? "Link \(chosen.count) Agents" : "Link Agent") { link() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen.isEmpty)
            }
            .padding(20)
        }
        .frame(width: 540)
        .task {
            agents = await model.availableAgents()
            chosen = choices?.choices.preselected ?? []
        }
    }

    @ViewBuilder private var content: some View {
        switch agents {
        case nil:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .disconnected(let reason):
            ContentUnavailableView(reason.title, systemImage: "bolt.horizontal.circle", description: Text(reason.explanation))
        case .connected:
            if let choices, !choices.choices.agents.isEmpty {
                List(choices.choices.agents) { agent in
                    Toggle(isOn: binding(for: agent.paneID)) {
                        AgentChoiceLabel(agent: agent, workspace: workspaceLabel(agent.workspaceID),
                                         inProject: choices.choices.preselected.contains(agent.paneID))
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.inset)
            } else {
                ContentUnavailableView("No agents to link", systemImage: "terminal",
                                       description: Text("Herdr has no other agents running right now."))
            }
        }
    }

    private func workspaceLabel(_ id: String) -> String {
        if case .connected(_, let workspaces)? = model.herdr, let match = workspaces.first(where: { $0.id == id }) {
            return match.label
        }
        return id
    }

    private func binding(for paneID: String) -> Binding<Bool> {
        Binding(get: { chosen.contains(paneID) },
                set: { if $0 { chosen.insert(paneID) } else { chosen.remove(paneID) } })
    }

    private func link() {
        guard let choices else { return }
        let picked = choices.choices.agents.filter { chosen.contains($0.paneID) }
        Task {
            await model.linkAgents(picked, on: choices.server, toTask: task.id)
            dismiss()
        }
    }
}

private struct AgentChoiceLabel: View {
    let agent: HerdrAgent
    let workspace: String
    let inProject: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(verbatim: agent.name ?? agent.kind)
                    .fontWeight(.medium)
                AgentActivityLabel(activity: agent.status.activity)
                    .foregroundStyle(.secondary)
            }
            Text(verbatim: "\(workspace) · \(agent.kind) · \(agent.paneID)" + (inProject ? " · this task’s project" : ""))
                .font(.callout)
                .foregroundStyle(.secondary)
            if let title = agent.title {
                Text(verbatim: title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

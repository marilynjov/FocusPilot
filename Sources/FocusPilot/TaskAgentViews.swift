import FocusPilotCore
import SwiftUI

/// The selected task's Agent section (design 01): its linked Herdr agents,
/// their status, and Open agent. Nothing here acts on its own; focusing a
/// pane happens only when the owner clicks Open agent.
struct TaskAgentInspector: View {
    let model: AppModel
    let task: TodayItem
    var showReviewQueue: () -> Void
    @State private var isLinking = false

    private var links: [TaskAgentLink] { model.agentLinks.filter { $0.taskID == task.id } }

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
                if links.isEmpty {
                    Text("No Herdr agent is linked to this task. Linked agents report here and their results go to Review queue.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(links) { link in
                        AgentLinkView(model: model, link: link,
                                      reviewCount: model.reviewItems.filter { $0.linkID == link.id }.count,
                                      showReviewQueue: showReviewQueue)
                    }
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
                if reviewCount > 0 {
                    Button("Review (\(reviewCount))", action: showReviewQueue)
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

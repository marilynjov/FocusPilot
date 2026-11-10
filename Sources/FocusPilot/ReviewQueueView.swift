import FocusPilotCore
import SwiftUI

/// Design 16: agent results and approval requests waiting for the owner.
/// Items arrive while FocusPilot polls Herdr, or when an agent reports
/// (decision 0005), without changing Now or the task. Output is plain text,
/// never executed or rendered as markup, and FocusPilot never answers an
/// approval. A reported result waits while a plan block runs (D8).
///
/// An item stays Unread until the owner selects it here; nothing is
/// selected for them, so only their own click marks it read (owner
/// request, 2026-11-10).
struct ReviewQueueView: View {
    let model: AppModel
    @State private var selection: ReviewItem.ID?

    var body: some View {
        if model.reviewItems.isEmpty {
            ContentUnavailableView("Nothing to review", systemImage: "tray",
                                   description: Text(model.heldReviewCount > 0 ? heldText
                                                     : "Agent results appear here when they finish. Nothing opens on its own."))
        } else {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    List(model.reviewItems, selection: $selection) { item in
                        AgentResultRow(item: item)
                    }
                    .listStyle(.inset)
                    Divider()
                    Text("Previews are plain text from the agent, never executed. Approval requests are shown; FocusPilot never answers them."
                         + (model.heldReviewCount > 0 ? " " + heldText : ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(12)
                }
                // Both columns give way: fixed widths left the page wider
                // than the window, and the sidebar could not open it
                // (owner report, 2026-11-10).
                .frame(minWidth: 260, idealWidth: 380)
                Divider()
                Group {
                    if let item = model.reviewItems.first(where: { $0.id == selection }) {
                        AgentResultDetail(model: model, item: item)
                    } else {
                        ContentUnavailableView("Select a result", systemImage: "tray")
                    }
                }
                .frame(minWidth: 260, idealWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
            }
            .onChange(of: selection) {
                if let selection { Task { await model.markOpened(selection) } }
            }
        }
    }

    private var heldText: String {
        let count = model.heldReviewCount
        return (count == 1 ? "1 more result waits" : "\(count) more results wait") + " for your next break."
    }
}

extension ReviewItem {
    /// Unread or Read for a result; an approval request or a failure keeps
    /// its wording and adds Unread until opened.
    var stateTitle: String {
        let state = kind == .approval ? "Needs your approval" : agentState == .failed ? "Failed" : nil
        guard let state else { return isUnread ? "Unread" : "Read" }
        return isUnread ? "\(state) · Unread" : state
    }

    var timeTitle: String {
        let time = occurredAt.formatted(date: .omitted, time: .shortened)
        return kind == .approval ? "Waiting since \(time)" : agentState == .failed ? "Failed \(time)" : "Finished \(time)"
    }

    var stateRole: PaletteRole { kind == .approval || agentState == .failed ? .blocked : .ready }

    var place: String { [agentLabel, workspaceLabel].compactMap { $0 }.joined(separator: " · ") }

    /// One line for the list: the agent's title, else its last output line.
    var headline: String? { summary ?? output?.lines.last }
}

/// "ablation · NLP report → Explain baseline results", the time, one line of
/// output, and Unread, Read or Needs your approval. An unread item has an
/// accent dot and a bold name.
struct AgentResultRow: View {
    let item: ReviewItem
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if item.isUnread {
                        Circle()
                            .fill(palette.color(.accent))
                            .frame(width: 8, height: 8)
                            .contrastOutline()
                    }
                    Text(verbatim: item.place)
                        .fontWeight(item.isUnread ? .bold : .medium)
                    Text(verbatim: "→ \(item.taskTitle)")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(item.timeTitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let headline = item.headline {
                    Text(verbatim: headline)
                        .font(.callout)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            StatusDot(title: item.stateTitle, role: item.stateRole, filled: item.isUnread || item.stateRole == .blocked)
        }
        .padding(.vertical, 4)
        // One item for VoiceOver, without the arrow and middle dots.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([item.place.replacing(" · ", with: ", "), "for \(item.taskTitle)", item.timeTitle,
                             item.headline, item.stateTitle].compactMap(\.self).joined(separator: ", "))
    }
}

/// The selected item: its task, its output as plain text, and the owner's
/// two choices.
struct AgentResultDetail: View {
    let model: AppModel
    let item: ReviewItem

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                StatusDot(title: item.stateTitle, role: item.stateRole, filled: item.isUnread || item.stateRole == .blocked)
                Text(verbatim: "\(item.place) · \(item.timeTitle.lowercased())")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let source = item.source {
                    Text(verbatim: "Result \(source.provenance)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            LabeledContent("Task") {
                Text(verbatim: item.taskTitle)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Output")
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                ScrollView {
                    // Verbatim: agent output is never interpreted as markup.
                    Text(verbatim: item.output?.lines.joined(separator: "\n") ?? "The agent’s screen could not be read.")
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
                .contrastBorder(cornerRadius: 6)
                Text(lineCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if item.kind == .approval {
                Text("The request is shown here as text. Respond in Herdr after Open agent; FocusPilot never approves or declines on your behalf.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let notice = model.agentNotice {
                Label(notice, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if let linkID = item.linkID {
                    Button("Open agent") { Task { await model.openAgent(linkID) } }
                        .help("Shows this agent's pane in Herdr. Herdr then marks its result as seen.")
                }
                if let agentID = item.reportedAgentID {
                    Button("Go to agent") { Task { await model.goToAgent(agentID, from: .panel) } }
                        .help("Brings the agent’s terminal forward.")
                }
                Spacer()
                Button("Mark reviewed") { Task { await model.markReviewed(item.id) } }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .onChange(of: item.id) { model.agentNotice = nil }
    }

    private var lineCaption: String {
        guard let output = item.output else { return "Plain text · not executed" }
        return output.lines.count < output.totalLineCount
            ? "Plain text · not executed · last \(output.lines.count) of \(output.totalLineCount) lines"
            : "Plain text · not executed · \(output.lines.count) lines"
    }
}

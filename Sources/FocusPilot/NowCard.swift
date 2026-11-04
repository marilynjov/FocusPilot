import FocusPilotCore
import SwiftUI

/// The pinned Now task and its next action, or an empty state when the
/// owner has not chosen one.
struct NowCard: View {
    let item: TodayItem?
    let caption: String?
    let showsProject: Bool
    let now: Date
    /// On Today the raccoon works inside this card, at its right (owner
    /// request, 2026-11-03).
    var showsRaccoon = false
    /// Selected on Today, which shows its Agent panel.
    var isSelected = false
    @Environment(AppModel.self) private var model: AppModel?
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            content
            if showsRaccoon, let model {
                RaccoonWindowView(model: model, margin: 0, isInNowCard: true,
                                  cardShowsSessionControls: showsSessionControls(model))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .foregroundStyle(palette.color(.ink))
        .background(palette.color(.surface), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(palette.color(isSelected ? .accent : .line), lineWidth: isSelected ? 2 : 1))
        .accessibilityElement(children: .contain)
    }

    /// Whether the card shows the session's controls: only for a session
    /// on this card's task (see `session(for:_:)`).
    private func showsSessionControls(_ model: AppModel) -> Bool {
        guard let item, let session = model.snapshot.activeSession else { return false }
        return session.taskID == item.id
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Label {
                    Text("Now").foregroundStyle(palette.color(.muted))
                } icon: {
                    Image(systemName: "pin.fill").foregroundStyle(palette.color(.accent))
                }
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                if let caption {
                    Text("· " + caption)
                        .font(.caption)
                        .foregroundStyle(palette.color(.muted))
                }
            }
            if let item {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(.title2.weight(.semibold))
                    TaskMeta(item: item, showsProject: showsProject, now: now)
                }
                if let nextAction = item.nextAction {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(nextAction == item.wrapUp?.returnCue ? "Next action · return cue from last session" : "Next action")
                            .font(.callout)
                            .foregroundStyle(palette.color(.muted))
                        Text(nextAction)
                            .textSelection(.enabled)
                        if let remaining = item.wrapUp?.remainingWork {
                            Text("\(Text("Remains: ").foregroundStyle(palette.color(.muted)))\(remaining)")
                                .font(.callout)
                                .padding(.top, 2)
                        }
                    }
                }
                if let model {
                    session(for: item, model)
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("No current task")
                        .font(.title3.weight(.semibold))
                    Text("Pick one from Next and press ⌘1, or capture a new one.")
                        .foregroundStyle(palette.color(.muted))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Changes whenever the card changes height: another task, its next
    /// action or remaining work appearing, a session starting or ending, its
    /// phase, and the confirmations and plan prompts `SessionControls` shows.
    static func layoutKey(_ model: AppModel, item: TodayItem?) -> String {
        var parts = [item.map { "\($0.id)" } ?? "empty", "\(item?.nextAction != nil)",
                     "\(item?.wrapUp?.remainingWork != nil)"]
        if let session = model.snapshot.activeSession {
            let phase = switch session.phase {
            case .running: "running"
            case .paused: "paused"
            case .onBreak: "break"
            case .ended: "ended"
            }
            let run = model.snapshot.activePlanRun
            parts += [session.id.uuidString, phase, "\(model.snapshot.earlyEndAvailableAt != nil)",
                      "\(model.isConfirmingEarlyEnd)", "\(model.task(session.taskID)?.wrapUp != nil)",
                      "\(run != nil)", "\(run?.moreTimeRequestedAt != nil)"]
        }
        return parts.joined(separator: "|")
    }

    /// Start focus, or the session already running.
    @ViewBuilder
    private func session(for item: TodayItem, _ model: AppModel) -> some View {
        if let session = model.snapshot.activeSession {
            if session.taskID == item.id {
                VStack(alignment: .leading, spacing: 10) {
                    SessionHeader(session: session, now: model.now, timeFont: .title3.weight(.semibold))
                    SessionControls(model: model, showsReturnCue: false)
                }
            } else {
                Text("A session is running on “\(session.action)”.")
                    .font(.callout)
                    .foregroundStyle(palette.color(.muted))
            }
        } else {
            Button { model.requestStartFocus() } label: {
                Label("Start focus", systemImage: "play.fill")
            }
            .accentProminentButton()
            .controlSize(.large)
            .help("Start focus (⌘⏎)")
            .accessibilityHint("Starts a session for \(item.title)")
        }
    }
}

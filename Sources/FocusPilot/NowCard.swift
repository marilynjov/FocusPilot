import FocusPilotCore
import SwiftUI

/// The pinned Now task and its next action, or an empty state when the
/// owner has not chosen one.
struct NowCard: View {
    let item: TodayItem?
    let caption: String?
    let showsProject: Bool
    let now: Date
    @Environment(AppModel.self) private var model: AppModel?
    @Environment(\.palette) private var palette

    var body: some View {
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
        .padding(16)
        .foregroundStyle(palette.color(.ink))
        .background(palette.color(.surface), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(palette.color(.line)))
        .accessibilityElement(children: .contain)
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
                .frame(maxWidth: 360)
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

import AppKit
import FocusPilotCore
import SwiftUI

/// The menu bar popover (design 03): the Now task and Start focus when idle;
/// during a session its phase, time left, task and Pause/Complete, and
/// protection status (#17): Browsers, Safari and Apps as separate facts,
/// since app hiding needs FocusPilot running. iPhone and agent lines arrive
/// with #22 and #19.
struct MenuBarContent: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if let session = model.snapshot.activeSession {
                    inSession(session)
                } else {
                    idle
                }
            }
            .padding(16)

            Divider()
            VStack(alignment: .leading, spacing: 0) {
                MenuRow("Open FocusPilot", shortcut: "⌘O") { openPlanning() }
                    .keyboardShortcut("o")
                MenuRow("Settings…", shortcut: "⌘,") {
                    model.requestedPage = .settings
                    openPlanning()
                }
                .keyboardShortcut(",")
                LoginItemToggle(settings: model.loginItem)
                MenuRow("Quit FocusPilot", shortcut: "⌘Q") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .padding(.vertical, 6)
        }
        .frame(width: 340)
        // The owner can change the login item in System Settings meanwhile.
        .onAppear { model.loginItem.refresh() }
    }

    private var idle: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.nowTask?.title ?? "No current task")
                    .font(.headline)
                Text(model.nowTask?.projectTitle ?? (model.nowTask == nil ? "Pin a task as Now to start a session." : "No project"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ProtectionStatusView(model: model, showsDetail: false)
            SiteExceptionLines(model: model)
            if let error = model.startupError ?? model.sessionError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            // A session that reached its planned end does not open a window
            // on its own; its wrap-up waits here.
            if let wrapUp = model.wrapUp {
                Button { openPlanning() } label: {
                    Label("Wrap up “\(wrapUp.prompt.session.action)”…", systemImage: "square.and.pencil")
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            }
            Button {
                model.requestStartFocus()
                openPlanning()
            } label: {
                Text("Start focus…").frame(maxWidth: .infinity)
            }
            .buttonStyle(AccentButtonStyle())
            .disabled(model.nowTask == nil)
            .accessibilityHint(model.nowTask.map { "Starts a session for \($0.title)" } ?? "")
        }
    }

    private func inSession(_ session: FocusSession) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SessionHeader(session: session, now: model.now)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.action)
                    .font(.headline)
                if let project = model.nowTask.flatMap({ $0.id == session.taskID ? $0.projectTitle : nil }) {
                    Text(project)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            ProtectionStatusView(model: model)
            SiteExceptionLines(model: model)
            if let error = model.sessionError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            SessionControls(model: model)
        }
    }

    private func openPlanning() {
        openWindow(id: PlanningView.windowID)
        // A menu-bar app is never frontmost on its own, so without this
        // the window would open behind the current app.
        NSApplication.shared.activate()
        dismiss()
    }
}

/// A full-width, menu-like row with its shortcut on the right.
private struct MenuRow: View {
    let title: String
    let shortcut: String?
    let action: () -> Void
    @State private var isHovered = false

    init(_ title: String, shortcut: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.shortcut = shortcut
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if let shortcut {
                    // Read as the button's shortcut, not as part of its name.
                    Text(shortcut).foregroundStyle(.tertiary).accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(isHovered ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .padding(.horizontal, 6)
    }
}

private struct LoginItemToggle: View {
    let settings: LoginItemSettings

    var body: some View {
        Toggle("Open at Login", isOn: Binding(
            get: { settings.isEnabled },
            set: { settings.setEnabled($0) }
        ))
        .toggleStyle(.checkbox)
        .padding(.horizontal, 16)
        .padding(.vertical, 4)

        if settings.needsApproval {
            MenuRow("Allow in System Settings…") {
                settings.openSystemSettings()
            }
        }
        if let errorMessage = settings.errorMessage {
            Text(errorMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
        }
    }
}

/// "Apps protected · Instagram" over "Only while FocusPilot is running" (design 03).
struct AppProtectionLine: View {
    let text: AppProtectionText

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Label(text.summary, systemImage: "app.dashed")
                .font(.callout)
            Text(text.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 22)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Running site and page exceptions with their time left (#14).
private struct SiteExceptionLines: View {
    let model: AppModel

    var body: some View {
        ForEach(SiteExceptionText.lines(model.snapshot.policy?.exceptions ?? [], at: model.now), id: \.self) { line in
            Label(line, systemImage: "timer")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

import AppKit
import FocusPilotCore
import SwiftUI

/// The blocked-app panel (design 10): a centered floating panel that says
/// why the app was hidden and offers Return to task and a timed exception.
///
/// It never activates FocusPilot: it is non-activating, and becomes key only
/// when the owner clicks the reason field, so keystrokes (Escape, Return)
/// reach it only after that. It closes on Return to task, on a granted
/// exception, on Close, and when the owner brings another app forward.
/// Activations within `settleTime` of showing are ignored: they are the
/// system bringing the next app forward after the hide.
@MainActor
final class BlockedAppPanelController {
    static let settleTime: TimeInterval = 1

    private unowned let model: AppModel
    private unowned let blocker: AppBlocker
    private var panel: NSPanel?
    private var shownAt = Date.distantPast
    let state = BlockedAppPanelState()

    init(model: AppModel, blocker: AppBlocker) {
        self.model = model
        self.blocker = blocker
    }

    func show(_ blocked: BlockedApp) {
        if state.blocked?.bundleID != blocked.bundleID {
            state.reset()
        }
        state.blocked = blocked
        shownAt = .now
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.center()
        panel.orderFrontRegardless()
    }

    func ownerActivated(_ app: NSRunningApplication) {
        guard panel != nil, Date.now.timeIntervalSince(shownAt) > Self.settleTime else { return }
        close()
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
        state.blocked = nil
        state.reset()
        if model.snapshot.pendingException != nil {
            Task { await model.cancelException() }
        }
    }

    private func makePanel() -> NSPanel {
        let panel = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 240),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.onCancel = { [weak self] in self?.close() }
        let host = NSHostingView(rootView: BlockedAppPanelView(model: model, state: state, actions: .init(
            returnToTask: { [weak blocker] in blocker?.returnToTask() },
            openFocusPilot: { [weak self, weak model] in
                self?.close()
                model?.planningWindowRequests += 1
            },
            excepted: { [weak blocker] app in blocker?.showExcepted(app) },
            close: { [weak self] in self?.close() })).paletteTheme(model.displayPreferences))
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
        return panel
    }
}

/// A borderless panel can only take typing (the reason field) if it says it can.
private final class KeyablePanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// What the panel shows: the hidden app and the exception form.
@MainActor
@Observable
final class BlockedAppPanelState {
    var blocked: BlockedApp?
    var isRequestingException = false
    var duration = TimedException.durations[1]
    var reason = ""
    /// A strict session asked the owner to confirm the wait.
    var isConfirming = false
    var error: String?

    func reset() {
        isRequestingException = false
        duration = TimedException.durations[1]
        reason = ""
        isConfirming = false
        error = nil
    }
}

struct BlockedAppPanelView: View {
    struct Actions {
        let returnToTask: () -> Void
        let openFocusPilot: () -> Void
        let excepted: (NSRunningApplication) -> Void
        let close: () -> Void
    }

    let model: AppModel
    @Bindable var state: BlockedAppPanelState
    let actions: Actions

    var body: some View {
        Group {
            if let blocked = state.blocked {
                content(blocked)
            }
        }
        .fixedSize()
    }

    private var session: FocusSession? { model.snapshot.activeSession }
    private var isStrict: Bool { session?.mode == .strict }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func content(_ blocked: BlockedApp) -> some View {
        let text = BlockedAppText(appName: blocked.name, reason: blocked.reason, session: session, at: model.now,
                                  reducesMotion: reduceMotion)
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(nsImage: blocked.app.icon ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)!)
                        .resizable()
                        .frame(width: 32, height: 32)
                        .accessibilityHidden(true)
                    Text(verbatim: blocked.name)
                        .font(.title3.weight(.semibold))
                    if isStrict {
                        Label("Strict", systemImage: "lock.fill")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(action: actions.close) {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .help("Close")
                    .accessibilityLabel("Close")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(text.headline)
                        .font(.headline)
                        .monospacedDigit()
                    Text(verbatim: text.detail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if state.isRequestingException {
                    exceptionForm(blocked)
                } else {
                    HStack {
                        if session != nil {
                            Button(action: actions.returnToTask) {
                                Label("Return to task", systemImage: "arrow.uturn.backward")
                            }
                            .accentProminentButton()
                            .keyboardShortcut(.defaultAction)
                        } else {
                            Button("Open FocusPilot", action: actions.openFocusPilot)
                                .accentProminentButton()
                        }
                        Button(BlockedAppText.exceptionButton(availableAt: pendingAvailableAt(blocked), now: model.now)) {
                            state.isRequestingException = true
                        }
                    }
                    .controlSize(.large)
                }
            }
            .padding(18)
            .background(Color(nsColor: .controlBackgroundColor))
            Divider()
            Text(verbatim: text.footer)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .barBackground()
        }
        .frame(width: 420)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator))
    }

    private func exceptionForm(_ blocked: BlockedApp) -> some View {
        let availableAt = pendingAvailableAt(blocked)
        let waiting = availableAt.map { model.now < $0 } ?? false
        return VStack(alignment: .leading, spacing: 10) {
            Text("Timed exception")
                .font(.headline)
            Text("Covers all of \(blocked.name). Ends at the time chosen, not at the session end.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("Duration", selection: $state.duration) {
                ForEach(TimedException.durations, id: \.self) { duration in
                    Text("\(Int(duration / 60)) min").tag(duration)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .disabled(availableAt != nil)
            if isStrict {
                TextField("Why this app is needed for the task", text: $state.reason)
                    .textFieldStyle(.roundedBorder)
                    .disabled(availableAt != nil)
            }
            if state.isConfirming {
                Text("A strict session waits \(StrictEarlyEnd.waitText) before allowing \(blocked.name).")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = state.error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    state.reset()
                    if availableAt != nil { Task { await model.cancelException() } }
                }
                Button(allowLabel(availableAt: availableAt)) { request(blocked) }
                    .accentProminentButton()
                    .keyboardShortcut(.defaultAction)
                    .disabled(waiting || (isStrict && state.reason.trimmingCharacters(in: .whitespaces).isEmpty))
            }
        }
    }

    private func allowLabel(availableAt: Date?) -> String {
        if state.isConfirming { return "Start the wait" }
        return BlockedAppText.allowButton(availableAt: availableAt, now: model.now)
    }

    /// When a confirmed strict request for this app may be granted.
    private func pendingAvailableAt(_ blocked: BlockedApp) -> Date? {
        guard let pending = model.snapshot.pendingException, pending.scope == .app(bundleID: blocked.bundleID) else { return nil }
        return pending.availableAt
    }

    private func request(_ blocked: BlockedApp) {
        Task {
            let outcome = await model.requestException(.app(bundleID: blocked.bundleID), duration: state.duration,
                                                       reason: state.reason, confirmed: state.isConfirming)
            switch outcome {
            case .granted?:
                actions.excepted(blocked.app)
            case .needsConfirmation?:
                state.isConfirming = true
            case .waitUntil?:
                state.isConfirming = false
            case nil:
                break
            }
            state.error = model.exceptionError
        }
    }
}

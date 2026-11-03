import AppKit
import FocusPilotCore
import SwiftUI

/// The optional floating focus panel (design 04), shown during a session.
///
/// It is a non-activating panel: clicking it never takes keyboard focus from
/// the app the owner is typing in. It opens small in the top-right corner,
/// can be dragged anywhere (the place is remembered) and collapses to a pill.
/// While the raccoon floats on screen it stands in for the panel, which then
/// opens only from a click on the raccoon (owner request, 2026-11-02).
@MainActor
final class FocusPanelController {
    private unowned let model: AppModel
    private var panel: NSPanel?
    /// Opened from a click on the floating raccoon; closed by another click,
    /// or when the raccoon leaves the screen.
    private var isOpenedFromRaccoon = false

    init(model: AppModel) {
        self.model = model
    }

    /// Shows the panel while a session is active and the owner wants it.
    func update() {
        if !model.raccoon.isOnScreen || model.snapshot.activeSession == nil { isOpenedFromRaccoon = false }
        let wanted = model.snapshot.activeSession != nil
            && (model.displayPreferences.raccoonMode == .staysOnScreen ? isOpenedFromRaccoon : model.menuBarPreferences.showsFocusPanel)
        if wanted, panel == nil {
            show()
        } else if !wanted, let panel {
            panel.orderOut(nil)
            self.panel = nil
        }
    }

    private func closeFromRaccoon() {
        isOpenedFromRaccoon = false
        update()
    }

    /// Opens the panel just above the raccoon at `raccoonFrame`, or closes it.
    func toggleFromRaccoon(above raccoonFrame: NSRect) {
        isOpenedFromRaccoon.toggle()
        update()
        guard isOpenedFromRaccoon, let panel else { return }
        var frame = panel.frame
        frame.origin = NSPoint(x: raccoonFrame.maxX - frame.width, y: raccoonFrame.maxY + 4)
        if let visible = (NSScreen.screens.first { $0.frame.intersects(raccoonFrame) } ?? NSScreen.main)?.visibleFrame {
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        }
        panel.setFrame(frame, display: true)
    }

    private func show() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Opened from the raccoon, the corner button closes the panel; the
        // raccoon already plays the pill's part.
        let close: (() -> Void)? = isOpenedFromRaccoon ? { [weak self] in self?.closeFromRaccoon() } : nil
        let host = NSHostingView(rootView: FocusPanelView(model: model, onClose: close).paletteTheme(model.displayPreferences))
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
        if !panel.setFrameUsingName("FocusPanel"), let screen = NSScreen.main?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: screen.maxX - 336, y: screen.maxY - 16))
        }
        panel.setFrameAutosaveName("FocusPanel")
        panel.orderFrontRegardless()
        self.panel = panel
    }
}

/// The panel's content: expanded with Pause and Complete, or a collapsed pill.
struct FocusPanelView: View {
    let model: AppModel
    /// When set, the corner button closes the panel instead of collapsing it.
    var onClose: (() -> Void)?
    @State private var isCollapsed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.palette) private var palette

    init(model: AppModel, isCollapsed: Bool = false, onClose: (() -> Void)? = nil) {
        self.model = model
        self.onClose = onClose
        _isCollapsed = State(initialValue: isCollapsed)
    }

    var body: some View {
        Group {
            if let session = model.snapshot.activeSession {
                if isCollapsed { pill(session) } else { expanded(session) }
            }
        }
        .fixedSize()
    }

    private func expanded(_ session: FocusSession) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    SessionHeader(session: session, now: model.now, timeFont: .title3.weight(.semibold))
                    Button { if let onClose { onClose() } else { isCollapsed = true } } label: {
                        Image(systemName: onClose == nil ? "chevron.down" : "xmark")
                    }
                    .buttonStyle(.borderless)
                    .help(onClose == nil ? "Collapse" : "Close")
                    .accessibilityLabel(onClose == nil ? "Collapse" : "Close")
                }
                Text(session.action)
                    .font(.headline)
                    .contrastEmphasis()
                    .lineLimit(2)
                ProtectionStatusView(model: model, showsDetail: false, showsSafari: false, showsWeek: false)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
            Divider()
            SessionControls(model: model)
                .controlSize(.regular)
                .padding(12)
                .barBackground()
        }
        .frame(width: 320)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator))
    }

    private func pill(_ session: FocusSession) -> some View {
        let text = SessionText(session)
        return Button { isCollapsed = false } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(session.phase == .running ? palette.color(.accent) : Color.secondary)
                    .frame(width: 7, height: 7)
                    .contrastOutline()
                Text(reduceMotion ? text.minutesLeft(at: model.now) : text.timeLeft(at: model.now))
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                Text(session.action)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 200, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
            .overlay(Capsule().stroke(.separator))
        }
        .buttonStyle(.plain)
        .help("Expand")
        .accessibilityLabel("\(text.phase), \(text.minutesLeft(at: model.now)), \(session.action)")
        .accessibilityHint("Expand")
    }
}

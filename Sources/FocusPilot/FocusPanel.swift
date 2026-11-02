import AppKit
import FocusPilotCore
import SwiftUI

/// The optional floating focus panel (design 04), shown during a session.
///
/// It is a non-activating panel: clicking it never takes keyboard focus from
/// the app the owner is typing in. It opens small in the top-right corner,
/// can be dragged anywhere (the place is remembered) and collapses to a pill.
@MainActor
final class FocusPanelController {
    private unowned let model: AppModel
    private var panel: NSPanel?

    init(model: AppModel) {
        self.model = model
    }

    /// Shows the panel while a session is active and the owner wants it.
    func update() {
        let wanted = model.snapshot.activeSession != nil && model.menuBarPreferences.showsFocusPanel
        if wanted, panel == nil {
            show()
        } else if !wanted, let panel {
            panel.orderOut(nil)
            self.panel = nil
        }
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
        var fit: () -> Void = {}
        let host = NSHostingView(rootView: FocusPanelView(model: model, onResize: { fit() }).paletteTheme(model.displayPreferences))
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
        if panel.setFrameUsingName("FocusPanel") {
            // Keep only the saved place: a saved size can be too small for
            // the time and task now shown, which cut the pill off.
            let top = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
            panel.setContentSize(host.fittingSize)
            panel.setFrameTopLeftPoint(top)
        } else if let screen = NSScreen.main?.visibleFrame {
            panel.setContentSize(host.fittingSize)
            panel.setFrameTopLeftPoint(NSPoint(x: screen.maxX - 336, y: screen.maxY - 16))
        }
        // Keep it whole on a connected screen, e.g. after a display was
        // removed or the small pill was left near an edge.
        let visible = (NSScreen.screens.first { $0.frame.intersects(panel.frame) } ?? NSScreen.main)?.visibleFrame
        if let visible {
            var frame = panel.frame
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
            panel.setFrame(frame, display: false)
        }
        panel.setFrameAutosaveName("FocusPanel")
        // Collapsing to the pill and expanding again size the panel to fit,
        // keeping its top-left corner where it is.
        fit = { [weak panel, weak host] in
            guard let panel, let host else { return }
            let top = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
            panel.setContentSize(host.fittingSize)
            panel.setFrameTopLeftPoint(top)
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }
}

/// The panel's content: expanded with Pause and Complete, or a collapsed pill.
struct FocusPanelView: View {
    let model: AppModel
    /// Asks the panel to fit the new size after collapsing or expanding.
    var onResize: () -> Void = {}
    @State private var isCollapsed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.palette) private var palette

    init(model: AppModel, isCollapsed: Bool = false, onResize: @escaping () -> Void = {}) {
        self.model = model
        self.onResize = onResize
        _isCollapsed = State(initialValue: isCollapsed)
    }

    var body: some View {
        Group {
            if let session = model.snapshot.activeSession {
                if isCollapsed { pill(session) } else { expanded(session) }
            }
        }
        .fixedSize()
        .onChange(of: isCollapsed) { DispatchQueue.main.async { onResize() } }
    }

    private func expanded(_ session: FocusSession) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    SessionHeader(session: session, now: model.now, timeFont: .title3.weight(.semibold))
                    Button { isCollapsed = true } label: {
                        Image(systemName: "chevron.down")
                    }
                    .buttonStyle(.borderless)
                    .help("Collapse")
                    .accessibilityLabel("Collapse")
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
                    .lineLimit(1)
                    .fixedSize()
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

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
    /// Whether the panel on screen was built to open from the raccoon, so a
    /// mode change rebuilds it with the right corner button.
    private var panelIsFromRaccoon = false

    init(model: AppModel) {
        self.model = model
    }

    /// Shows the panel while a session is active and the owner wants it.
    func update() {
        let standsIn = model.raccoon.standsInForFocusPanel
        if !standsIn || !model.raccoon.isOnScreen || model.snapshot.activeSession == nil { isOpenedFromRaccoon = false }
        let wanted = model.snapshot.activeSession != nil
            && (standsIn ? isOpenedFromRaccoon : model.menuBarPreferences.showsFocusPanel)
        if wanted, let panel, panelIsFromRaccoon != isOpenedFromRaccoon {
            panel.orderOut(nil)
            self.panel = nil
            show()
        } else if wanted, panel == nil {
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
        moveAboveRaccoon(raccoonFrame)
    }

    /// Keeps a panel opened from the raccoon just above it when the raccoon
    /// moves.
    func moveAboveRaccoon(_ raccoonFrame: NSRect) {
        guard isOpenedFromRaccoon, panelIsFromRaccoon, let panel else { return }
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
        var fit: () -> Void = {}
        // Opened from the raccoon, the corner button closes the panel; the
        // raccoon already plays the pill's part.
        let close: (() -> Void)? = isOpenedFromRaccoon ? { [weak self] in self?.closeFromRaccoon() } : nil
        let host = NSHostingView(rootView: FocusPanelView(model: model, onResize: { fit() }, onClose: close)
            .paletteTheme(model.displayPreferences))
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
        // Only the owner's own panel remembers its place; one opened from the
        // raccoon is placed above it and must not overwrite that place.
        if !isOpenedFromRaccoon {
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
            Self.keepOnScreen(panel)
            panel.setFrameAutosaveName("FocusPanel")
        } else {
            panel.setContentSize(host.fittingSize)
        }
        // Collapsing to the pill and expanding again size the panel to fit.
        // A panel in the right half of its screen keeps its top-right corner,
        // so the pill stays near the edge; otherwise the top-left corner.
        fit = { [weak panel, weak host] in
            guard let panel, let host else { return }
            let frame = panel.frame
            let anchorsRight = Self.screen(for: panel).map { frame.midX > $0.visibleFrame.midX } ?? false
            panel.setContentSize(host.fittingSize)
            let x = anchorsRight ? frame.maxX - panel.frame.width : frame.minX
            panel.setFrameTopLeftPoint(NSPoint(x: x, y: frame.maxY))
            Self.keepOnScreen(panel)
        }
        panel.orderFrontRegardless()
        self.panel = panel
        panelIsFromRaccoon = isOpenedFromRaccoon
    }

    /// The screen the panel is on, else the main screen.
    private static func screen(for panel: NSPanel) -> NSScreen? {
        NSScreen.screens.first { $0.frame.intersects(panel.frame) } ?? NSScreen.main
    }

    /// Keeps the panel whole on a connected screen, e.g. after a display was
    /// removed, or after the pill was left near an edge and then expanded.
    private static func keepOnScreen(_ panel: NSPanel) {
        guard let visible = screen(for: panel)?.visibleFrame else { return }
        var frame = panel.frame
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        panel.setFrame(frame, display: true)
    }
}

/// The panel's content: expanded with Pause and Complete, or a collapsed pill.
struct FocusPanelView: View {
    let model: AppModel
    /// Asks the panel to fit the new size after collapsing or expanding.
    var onResize: () -> Void = {}
    /// When set, the corner button closes the panel instead of collapsing it.
    var onClose: (() -> Void)?
    @State private var isCollapsed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.palette) private var palette

    init(model: AppModel, isCollapsed: Bool = false, onResize: @escaping () -> Void = {}, onClose: (() -> Void)? = nil) {
        self.model = model
        self.onResize = onResize
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
        .onChange(of: isCollapsed) { DispatchQueue.main.async { onResize() } }
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
            .background(palette.color(.surface))
            // Solid palette colors: the see-through bar material let the
            // desktop show between the two parts (owner feedback, 2026-11-04).
            Rectangle()
                .fill(palette.color(.line))
                .frame(height: 1)
            SessionControls(model: model)
                .controlSize(.regular)
                .padding(12)
                .background(palette.color(.bg))
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
            .background(palette.color(.surface), in: Capsule())
            .overlay(Capsule().stroke(.separator))
        }
        .buttonStyle(.plain)
        .help("Expand")
        .accessibilityLabel("\(text.phase), \(text.minutesLeft(at: model.now)), \(session.action)")
        .accessibilityHint("Expand")
    }
}

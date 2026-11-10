import AppKit
import FocusPilotCore
import QuartzCore
import SwiftUI

/// The raccoon companion (D11, decision 0004): a borderless, transparent
/// panel in the bottom-right corner of the chosen display showing one pose
/// with the motion from `raccoon.json`. While the planning window is open
/// and FocusPilot is in front, the raccoon shows there instead
/// (`RaccoonWindowView`).
///
/// The panel never takes focus or clicks: it cannot become key or main,
/// it is non-activating, and it ignores the mouse except over a speech
/// bubble while one is shown. It joins every Space, stays put in Mission
/// Control, is skipped by window cycling, and shows over full-screen apps
/// (owner can choose Off or Peeks in instead).
@MainActor
final class RaccoonCompanionController {
    /// One art pixel per device pixel on a Retina display, so the pixel art
    /// is never resampled there.
    static let pointsPerPixel: CGFloat = 0.5
    /// Room on each side, in art pixels, for the Walking pose's walk.
    static let sideRoom: CGFloat = 40
    static let margin: CGFloat = 12
    /// How long a peek stays when its caller gives no duration.
    static let defaultPeek: Duration = .seconds(8)

    private unowned let model: AppModel
    private var panel: RaccoonPanel?
    private var stage: RaccoonStageView?
    private var art: RaccoonArt?
    private var artError: String?
    private var shown: RaccoonPresence?
    /// What the pointer is over: the floating raccoon, its bubble, or neither.
    private var hovered: RaccoonPanel.Part?
    private var isHovered: Bool { hovered != nil }
    /// Whether the bubble shows the unread note, so a click on it opens the
    /// Review queue.
    private var isShowingNote = false
    /// Ticks the time in the hover bubble while the pointer is over the
    /// raccoon.
    private var hoverTimer: Timer?
    private var peekTask: Task<Void, Never>?
    private var observers: [Task<Void, Never>] = []

    init(model: AppModel) {
        self.model = model
        // Recreate the motion when Reduce Motion changes.
        observers.append(Task { [weak self] in
            let name = NSWorkspace.accessibilityDisplayOptionsDidChangeNotification
            for await _ in NSWorkspace.shared.notificationCenter.notifications(named: name) {
                guard let self else { break }
                redraw()
            }
        })
        // In the window while FocusPilot is in front and its window is not
        // minimized, on screen otherwise.
        let names = [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                     NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                     NSWindow.didBecomeKeyNotification]
        for name in names {
            observers.append(Task { [weak model] in
                for await _ in NotificationCenter.default.notifications(named: name) {
                    guard let model else { break }
                    model.refreshRaccoonWindowState()
                }
            })
        }
        // Move to the corner again when displays change or the planning
        // window moves to another display.
        for name in [NSApplication.didChangeScreenParametersNotification, NSWindow.didChangeScreenNotification] {
            observers.append(Task { [weak self] in
                for await _ in NotificationCenter.default.notifications(named: name) {
                    guard let self else { break }
                    placePanel()
                }
            })
        }
    }

    /// Whether the raccoon is floating on screen. While it is, it stands in
    /// for the focus panel, which opens only from a click on it.
    var isOnScreen: Bool { panel != nil }

    /// Why the art could not be loaded, if it could not.
    var problem: String? { artError }

    /// Whether the raccoon replaces the focus panel: in On screen mode, and
    /// only while its art loads, so the panel is never lost with it.
    var standsInForFocusPanel: Bool {
        model.displayPreferences.raccoonMode == .staysOnScreen && problem == nil
    }

    /// Shows, changes or hides the raccoon for the current mode and session.
    func update() {
        let presence = RaccoonPresence.resolve(mode: model.displayPreferences.raccoonMode, activity: model.raccoonActivity,
                                               isWindowOpen: model.raccoonIsInWindow, peek: model.raccoonPeek,
                                               note: model.raccoonUnreadNote)
        guard presence != shown || (presence != nil && panel == nil) else { return }
        // Only the note changed: the pose keeps its motion.
        if let presence, let old = shown, panel != nil, presence.poseID == old.poseID, presence.message == old.message {
            shown = presence
            return refreshBubble()
        }
        shown = presence
        if let presence { show(presence) } else { hide() }
    }

    /// The moment the raccoon is peeking in for (D12), if any.
    private(set) var moment: RaccoonMoment?

    /// How long the peek has left while the pointer holds it.
    private var peekLeft: Duration?
    private var peekEnds: ContinuousClock.Instant?

    /// Brings the raccoon in with `peek` for `duration` (D12 reminders),
    /// replacing any earlier peek. In Off mode nothing shows. The time
    /// stands still while the pointer is over the raccoon or its bubble.
    func peek(_ peek: RaccoonPeek, for duration: Duration = defaultPeek) {
        moment = nil
        model.raccoonPeek = peek
        peekLeft = duration
        if isHovered { peekTask?.cancel() } else { runPeekClock() }
        update()
    }

    private func runPeekClock() {
        peekTask?.cancel()
        guard let left = peekLeft else { return }
        peekEnds = .now + left
        peekTask = Task { [weak self] in
            try? await Task.sleep(for: left)
            guard !Task.isCancelled else { return }
            self?.endPeek()
        }
    }

    private func holdPeekClock() {
        peekTask?.cancel()
        peekTask = nil
        if let peekEnds, peekLeft != nil { peekLeft = max(peekEnds - .now, .seconds(1)) }
    }

    /// Peeks in for `moment` for as long as it asks.
    func show(_ moment: RaccoonMoment) {
        peek(moment.peek, for: .seconds(moment.duration))
        self.moment = moment
    }

    /// Ends the peek, then shows any moment that waited for it unless
    /// `reevaluating` is false.
    func endPeek(reevaluating: Bool = true) {
        peekTask?.cancel()
        peekTask = nil
        peekLeft = nil
        peekEnds = nil
        moment = nil
        model.raccoonPeek = nil
        update()
        if reevaluating { model.evaluateRaccoonMoments() }
    }

    /// The bundled art, loaded once and shared with the planning window.
    func loadArt() -> RaccoonArt? {
        if let art { return art }
        do {
            art = try RaccoonArt.bundled()
            artError = nil
        } catch {
            artError = String(describing: error)
        }
        return art
    }

    private func show(_ presence: RaccoonPresence) {
        guard let art = loadArt(), let pose = art.manifest.pose(presence.poseID),
              let layers = try? art.layers(of: pose.id)
        else {
            hide()
            return
        }
        let panel = panel ?? makePanel(frameSize: CGFloat(art.manifest.frameSize))
        self.panel = panel
        stage?.show(pose: pose, layers: layers, motions: art.manifest.motions,
                    reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        placePanel()
        panel.orderFrontRegardless()
        refreshBubble()
        model.focusPanel.update()
    }

    private func hide() {
        stage?.setBubble(nil)
        panel?.followMouse(nil)
        panel?.orderOut(nil)
        panel = nil
        stage = nil
        setHovered(nil)
        model.focusPanel.update()
    }

    /// A peek's message and buttons, else the time and task while the
    /// pointer is over the raccoon (owner request, 2026-11-02), else the
    /// unread note (owner request, 2026-11-10), else no bubble. Over the
    /// note itself the note stays, so it can be clicked.
    private func refreshBubble() {
        let showsTime = hovered == .raccoon || (hovered == .bubble && shown?.note == nil)
        let time = shown?.message == nil && showsTime ? hoverText : nil
        let message = shown?.message ?? time ?? shown?.note
        isShowingNote = shown?.message == nil && time == nil && message != nil
        let actions = shown?.message != nil ? model.raccoonPeek?.actions ?? [] : []
        if stage?.bubbleMessage != message || stage?.bubbleActions != actions {
            let toolTip = isShowingNote ? "Click to open the Review queue"
                : model.raccoonPeek == nil ? "Click to show the focus panel"
                : actions.isEmpty ? "Click to dismiss" : "Click the message to dismiss"
            stage?.setBubble(message, actions: actions, toolTip: toolTip)
        }
    }

    /// Follows the pointer onto and off the raccoon, ticking the hover
    /// bubble's time once a second only while it is there.
    private func setHovered(_ part: RaccoonPanel.Part?) {
        if (part != nil) != isHovered, model.raccoonPeek != nil {
            if part != nil { holdPeekClock() } else { runPeekClock() }
        }
        hovered = part
        hoverTimer?.invalidate()
        hoverTimer = nil
        if part != nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshBubble() }
            }
            timer.tolerance = 0.1
            RunLoop.main.add(timer, forMode: .common)
            hoverTimer = timer
        }
    }

    private var hoverText: String? {
        guard let session = model.snapshot.activeSession else { return nil }
        let text = SessionText(session)
        let time = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? text.minutesLeft(at: .now) : "\(text.timeLeft(at: .now)) left"
        return session.phase == .running ? "\(time) · \(session.action)" : "\(text.phase) · \(time) · \(session.action)"
    }

    /// Opens or closes the focus panel above the raccoon.
    private func toggleFocusPanel() {
        guard let panel else { return }
        model.focusPanel.toggleFromRaccoon(above: panel.frame)
    }

    private func redraw() {
        guard let shown else { return }
        show(shown)
    }

    private func makePanel(frameSize: CGFloat) -> RaccoonPanel {
        let stage = RaccoonStageView(frameSize: frameSize, sideRoom: Self.sideRoom, pointsPerPixel: Self.pointsPerPixel)
        stage.onBubbleClick = { [weak self] in
            guard let self else { return }
            if model.raccoonPeek != nil {
                endPeek()
            } else if isShowingNote {
                model.openReviewQueue()
            } else {
                toggleFocusPanel()
            }
        }
        stage.onRaccoonClick = { [weak self] in self?.toggleFocusPanel() }
        stage.onBubbleAction = { [weak self] action in self?.model.performRaccoonAction(action) }
        let panel = RaccoonPanel(contentRect: NSRect(origin: .zero, size: stage.frame.size),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        // Every Space, unmoved by Mission Control, skipped by ⌘` window
        // cycling, and allowed over full-screen apps.
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.isExcludedFromWindowsMenu = true
        panel.animationBehavior = .none
        panel.contentView = stage
        self.stage = stage
        panel.followMouse { [weak self] part in
            guard let self else { return }
            setHovered(part)
            refreshBubble()
        }
        return panel
    }

    /// Bottom-right corner, above the Dock, of the display the planning
    /// window is on while it is open (owner request, 2026-11-02), else of
    /// the display chosen in Settings.
    func placePanel() {
        guard let panel,
              let screen = model.planningWindow?.screen ?? NSScreen.raccoonScreen(model.displayPreferences.raccoonScreen)
        else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.maxX - size.width - Self.margin, y: visible.minY + Self.margin))
        model.focusPanel.moveAboveRaccoon(panel.frame)
    }
}

extension NSScreen {
    /// The display's UUID, which stays the same across restarts and
    /// reconnections, unlike its display ID.
    var displayUUID: String? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue()
        else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    /// The display with `uuid`, or the main display (the one with the menu
    /// bar) when `uuid` is nil or that display is not connected.
    static func raccoonScreen(_ uuid: String?) -> NSScreen? {
        screens.first { uuid != nil && $0.displayUUID == uuid } ?? screens.first
    }
}

/// A panel that never becomes key or main, and lets clicks through except
/// over the speech bubble.
final class RaccoonPanel: NSPanel {
    /// The parts of the panel that take the pointer.
    enum Part {
        case raccoon, bubble
    }

    /// Within this distance of the panel the pointer is polled quickly, so
    /// the raccoon takes the mouse in time; farther away, slowly, so App Nap
    /// can still save power.
    private static let nearDistance: CGFloat = 150
    private static let nearInterval: TimeInterval = 0.05
    private static let farInterval: TimeInterval = 0.25

    private var mouseTimer: Timer?
    private var onHover: (@MainActor (Part?) -> Void)?
    private var hovered: Part?

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Takes the mouse only while it is over the raccoon or its bubble, and
    /// reports which, or nil, when that changes. Polled, since an ignoring
    /// window gets no events; nil stops.
    func followMouse(_ hovered: (@MainActor (Part?) -> Void)?) {
        mouseTimer?.invalidate()
        mouseTimer = nil
        ignoresMouseEvents = true
        self.hovered = nil
        onHover = hovered
        guard hovered != nil else { return }
        poll(every: Self.farInterval)
    }

    private func poll(every interval: TimeInterval) {
        mouseTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkMouse() }
        }
        timer.tolerance = interval / 5
        RunLoop.main.add(timer, forMode: .common)
        mouseTimer = timer
    }

    private func checkMouse() {
        let over = partUnderMouse
        ignoresMouseEvents = over == nil
        if over != hovered {
            hovered = over
            onHover?(over)
        }
        let isNear = frame.insetBy(dx: -Self.nearDistance, dy: -Self.nearDistance).contains(NSEvent.mouseLocation)
        let interval = isNear ? Self.nearInterval : Self.farInterval
        if mouseTimer?.timeInterval != interval { poll(every: interval) }
    }

    /// The bubble first: it is drawn over the raccoon.
    private var partUnderMouse: Part? {
        guard let stage = contentView as? RaccoonStageView else { return nil }
        let mouse = NSEvent.mouseLocation
        let contains = { (frame: NSRect) in self.convertToScreen(stage.convert(frame, to: nil)).contains(mouse) }
        if let bubble = stage.bubbleFrame, contains(bubble) { return .bubble }
        return contains(stage.raccoonHitFrame) ? .raccoon : nil
    }
}

/// Draws one pose with a Core Animation layer per raccoon layer, and an
/// optional speech bubble above it.
@MainActor
final class RaccoonStageView: NSView {
    /// Room for a bubble of up to three lines with a row of buttons.
    static let bubbleHeight: CGFloat = 104

    let frameSize: CGFloat
    let sideRoom: CGFloat
    let pointsPerPixel: CGFloat
    var onBubbleClick: (() -> Void)?
    var onBubbleAction: ((RaccoonPeekAction) -> Void)?
    /// A click on the raccoon itself; nil leaves clicks passing through.
    var onRaccoonClick: (() -> Void)?
    private let poseLayer = CALayer()
    private var bubble: RaccoonBubbleView?

    /// `bubbleRoom` is the height kept above the raccoon for a speech
    /// bubble; the planning window shows none.
    init(frameSize: CGFloat, sideRoom: CGFloat, pointsPerPixel: CGFloat, bubbleRoom: CGFloat = bubbleHeight) {
        self.frameSize = frameSize
        self.sideRoom = sideRoom
        self.pointsPerPixel = pointsPerPixel
        let width = (frameSize + 2 * sideRoom) * pointsPerPixel
        super.init(frame: NSRect(x: 0, y: 0, width: bubbleRoom > 0 ? max(width, 240) : width,
                                 height: frameSize * pointsPerPixel + bubbleRoom))
        wantsLayer = true
        layer?.backgroundColor = .clear
        // The pose layer works in art pixels (y up), scaled to points.
        poseLayer.bounds = CGRect(x: 0, y: 0, width: frameSize, height: frameSize)
        poseLayer.anchorPoint = CGPoint(x: 1, y: 0)
        poseLayer.position = CGPoint(x: bounds.maxX - sideRoom * pointsPerPixel, y: 0)
        poseLayer.transform = CATransform3DMakeScale(pointsPerPixel, pointsPerPixel, 1)
        layer?.addSublayer(poseLayer)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if let bubble, bubble.frame.contains(local) { return bubble.hitTest(local) }
        if onRaccoonClick != nil, raccoonHitFrame.contains(local) { return self }
        return nil
    }

    var bubbleFrame: NSRect? { bubble?.frame }
    var bubbleMessage: String? { bubble?.message }
    var bubbleActions: [RaccoonPeekAction] { bubble?.actions ?? [] }
    /// Where the raccoon is drawn, in this view's coordinates.
    var poseFrame: NSRect { poseLayer.frame }
    /// The part of `poseFrame` that takes the pointer: inset 15% on each
    /// side, so clicks just around the raccoon pass through.
    var raccoonHitFrame: NSRect { poseFrame.insetBy(dx: poseFrame.width * 0.15, dy: poseFrame.height * 0.15) }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onRaccoonClick?()
    }

    override func accessibilityPerformPress() -> Bool {
        guard let onRaccoonClick else { return false }
        onRaccoonClick()
        return true
    }

    func show(pose: RaccoonPoseArt, layers: [RaccoonLayer: CGImage], motions: [String: RaccoonMotion], reduceMotion: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        poseLayer.sublayers = nil
        RaccoonRig(pose: pose, images: layers, motions: motions, frameSize: frameSize, animates: !reduceMotion)
            .build(into: poseLayer)
        CATransaction.commit()
        setAccessibilityLabel(onRaccoonClick != nil ? "Raccoon companion, \(pose.name). Shows the focus panel"
                                                    : "Raccoon companion, \(pose.name)")
        if onRaccoonClick != nil {
            setAccessibilityRole(.button)
            setAccessibilityHelp("Shows or hides the focus panel")
        }
    }

    /// Centered over the raccoon, kept inside the view.
    private func bubbleOrigin(width: CGFloat) -> NSPoint {
        let x = min(max(poseFrame.midX - width / 2, 0), bounds.maxX - width)
        return NSPoint(x: x, y: frameSize * pointsPerPixel - 4)
    }

    /// Shows `message` in the bubble, with a button per action. A bubble
    /// already shown with the same buttons changes its text in place, so the
    /// time ticking while hovered does not redraw it.
    func setBubble(_ message: String?, actions: [RaccoonPeekAction] = [], toolTip: String? = nil) {
        if let message, let bubble, bubble.actions == actions {
            bubble.setMessage(message)
            bubble.toolTip = toolTip
            bubble.setAccessibilityHelp(toolTip)
            bubble.setFrameOrigin(bubbleOrigin(width: bubble.frame.width))
            return
        }
        bubble?.removeFromSuperview()
        bubble = nil
        if let message {
            let view = RaccoonBubbleView(message: message, actions: actions, maxWidth: bounds.width)
            view.setFrameOrigin(bubbleOrigin(width: view.frame.width))
            view.toolTip = toolTip
            view.setAccessibilityHelp(toolTip)
            view.onClick = { [weak self] in self?.onBubbleClick?() }
            view.onAction = { [weak self] action in self?.onBubbleAction?(action) }
            addSubview(view)
            bubble = view
        }
    }
}

/// The speech bubble: a message and, for some reminders (D12), a row of
/// buttons under it. Clicking elsewhere on it ends the peek. It and its
/// buttons accept the first click, since its panel is never key.
final class RaccoonBubbleView: NSView {
    static let padding = NSSize(width: 12, height: 8)
    static let buttonSpacing: CGFloat = 6

    var onClick: (() -> Void)?
    var onAction: ((RaccoonPeekAction) -> Void)?
    private(set) var message: String
    let actions: [RaccoonPeekAction]
    private let label: NSTextField
    private let buttons: [RaccoonBubbleButton]
    private let maxWidth: CGFloat

    init(message: String, actions: [RaccoonPeekAction] = [], maxWidth: CGFloat) {
        self.message = message
        self.actions = actions
        self.maxWidth = maxWidth
        label = NSTextField(wrappingLabelWithString: message)
        label.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        label.textColor = .labelColor
        label.preferredMaxLayoutWidth = maxWidth - 2 * Self.padding.width
        label.isSelectable = false
        buttons = actions.map { RaccoonBubbleButton(action: $0) }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        addSubview(label)
        for button in buttons {
            button.target = self
            button.action = #selector(pressed(_:))
            addSubview(button)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(actions.isEmpty ? .button : .group)
        setMessage(message)
    }

    /// Changes the text and fits the bubble to it, buttons right-aligned
    /// below.
    func setMessage(_ message: String) {
        self.message = message
        label.stringValue = message
        let text = label.fittingSize
        let row = buttons.map(\.fittingSize)
        let rowWidth = row.map(\.width).reduce(0, +) + Self.buttonSpacing * CGFloat(max(row.count - 1, 0))
        let rowHeight = row.map(\.height).max().map { $0 + Self.buttonSpacing } ?? 0
        let pad = Self.padding
        let width = min(max(text.width, rowWidth) + 2 * pad.width, maxWidth)
        let height = min(text.height + rowHeight + 2 * pad.height, RaccoonStageView.bubbleHeight)
        setFrameSize(NSSize(width: width, height: height))
        label.frame = NSRect(x: pad.width, y: pad.height + rowHeight, width: width - 2 * pad.width,
                             height: height - rowHeight - 2 * pad.height)
        var x = width - pad.width
        for (button, size) in zip(buttons, row).reversed() {
            x -= size.width
            button.frame = NSRect(x: x, y: pad.height, width: size.width, height: size.height)
            x -= Self.buttonSpacing
        }
        setAccessibilityLabel(message)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    override var wantsUpdateLayer: Bool { true }

    /// A button takes its own clicks; anywhere else on the bubble is the bubble.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard frame.contains(point) else { return nil }
        if let hit = super.hitTest(point), hit is NSButton { return hit }
        return self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    @objc private func pressed(_ sender: RaccoonBubbleButton) {
        onAction?(sender.peekAction)
    }
}

/// A small button under the bubble's message.
final class RaccoonBubbleButton: NSButton {
    let peekAction: RaccoonPeekAction

    init(action: RaccoonPeekAction) {
        peekAction = action
        super.init(frame: .zero)
        title = action.title
        bezelStyle = .push
        controlSize = .small
        font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Builds a pose's layer tree. Coordinates in `raccoon.json` are art
/// pixels with y down; Core Animation's are y up, so y, vertical moves and
/// rotations are mirrored here.
@MainActor
private struct RaccoonRig {
    let pose: RaccoonPoseArt
    let images: [RaccoonLayer: CGImage]
    let motions: [String: RaccoonMotion]
    let frameSize: CGFloat
    let animates: Bool
    let start = CACurrentMediaTime()

    func build(into root: CALayer) {
        let m = pose.motion
        // Back to front: shadow, legs, body, head, closed eyes, still objects, effects.
        if let shadow = images[.shadow] {
            root.addSublayer(chain([m.shadow], around: nil, holding: image(shadow)))
        }

        var raccoon: [CALayer] = []
        for (index, leg) in RaccoonLayer.legs.enumerated() {
            guard let picture = images[leg] else { continue }
            let pivot = pose.legPivots?[safe: index]
            raccoon.append(chain([m.legs?[safe: index]], around: pivot, holding: image(picture)))
        }
        if let body = images[.body] { raccoon.append(image(body)) }
        // Blinking shows the closed-eyes picture over the head (or the body)
        // for a moment; it moves with whatever it covers.
        let closedEyes = images[.eyesClosed].map { picture -> CALayer in
            let layer = image(picture)
            layer.opacity = 0
            if let blink = m.blink { animateOpacity(layer, with: blink) }
            return layer
        }
        if let head = images[.head] {
            let headLayer = image(head)
            if let closedEyes { headLayer.addSublayer(closedEyes) }
            raccoon.append(chain([m.head], around: pose.headPivot, holding: headLayer))
        } else if let closedEyes {
            raccoon.append(closedEyes)
        }
        let breathing = frameLayer()
        raccoon.forEach(breathing.addSublayer)
        let raccoonGroup = chain([m.move, m.hop, m.body], around: nil, holding: breathing)
        if let clip = m.clipMaxX {
            let clipped = frameLayer()
            let mask = CALayer()
            mask.frame = CGRect(x: 0, y: 0, width: clip, height: frameSize)
            mask.backgroundColor = .black
            clipped.mask = mask
            clipped.addSublayer(raccoonGroup)
            root.addSublayer(clipped)
        } else {
            root.addSublayer(raccoonGroup)
        }

        if let still = images[.still] { root.addSublayer(image(still)) }
        if let effects = images[.effects] {
            root.addSublayer(chain([m.move, m.hop, m.effects], around: nil, holding: image(effects)))
        }
    }

    // MARK: Layers

    private func frameLayer() -> CALayer {
        let layer = CALayer()
        layer.frame = CGRect(x: 0, y: 0, width: frameSize, height: frameSize)
        return layer
    }

    private func image(_ picture: CGImage) -> CALayer {
        let layer = frameLayer()
        layer.contents = picture
        layer.magnificationFilter = .nearest
        return layer
    }

    /// Nests `content` in one transform layer per motion use, outermost
    /// first. `around` is the pivot for head and leg motions (art pixels).
    private func chain(_ uses: [RaccoonMotionUse?], around pivot: RaccoonPoint?, holding content: CALayer) -> CALayer {
        var inner = content
        for use in uses.reversed() {
            guard let use, let motion = motions[use.motion] else { continue }
            let origin = pivot.map { CGPoint(x: $0.x, y: $0.y) }
                ?? CGPoint(x: (motion.origin?.x ?? 0.5) * frameSize, y: (motion.origin?.y ?? 0.5) * frameSize)
            inner = transformed(inner, by: use, motion: motion, origin: origin)
        }
        return inner === content ? wrap(content) : inner
    }

    private func wrap(_ content: CALayer) -> CALayer {
        let layer = frameLayer()
        layer.addSublayer(content)
        return layer
    }

    /// Three nested layers sharing `origin` (art pixels, y down): translate
    /// outside rotate outside scale, as in a CSS `transform` list.
    private func transformed(_ content: CALayer, by use: RaccoonMotionUse, motion: RaccoonMotion, origin: CGPoint) -> CALayer {
        let anchored: () -> CALayer = {
            let layer = CALayer()
            layer.bounds = CGRect(x: 0, y: 0, width: frameSize, height: frameSize)
            layer.anchorPoint = CGPoint(x: origin.x / frameSize, y: 1 - origin.y / frameSize)
            layer.position = CGPoint(x: origin.x, y: frameSize - origin.y)
            return layer
        }
        let translate = anchored(), rotate = anchored(), scale = anchored()
        translate.addSublayer(rotate)
        rotate.addSublayer(scale)
        scale.addSublayer(content)
        guard animates else { return translate }
        for track in motion.tracks {
            switch track.property {
            case .translateX: add(track, "transform.translation.x", to: translate, use: use, motion: motion) { $0 }
            case .translateY: add(track, "transform.translation.y", to: translate, use: use, motion: motion) { -$0 }
            case .rotate: add(track, "transform.rotation.z", to: rotate, use: use, motion: motion) { -$0 * .pi / 180 }
            case .scaleX: add(track, "transform.scale.x", to: scale, use: use, motion: motion) { $0 }
            case .scaleY: add(track, "transform.scale.y", to: scale, use: use, motion: motion) { $0 }
            case .opacity: add(track, "opacity", to: translate, use: use, motion: motion) { $0 }
            }
        }
        return translate
    }

    private func animateOpacity(_ layer: CALayer, with use: RaccoonMotionUse) {
        guard animates, let motion = motions[use.motion] else { return }
        for track in motion.tracks where track.property == .opacity {
            add(track, "opacity", to: layer, use: use, motion: motion) { $0 }
        }
    }

    // MARK: Animation

    private func add(_ track: RaccoonMotionTrack, _ keyPath: String, to layer: CALayer, use: RaccoonMotionUse,
                     motion: RaccoonMotion, convert: (Double) -> Double) {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        var values = track.values.map(convert)
        animation.keyTimes = track.keyTimes.map { NSNumber(value: $0) }
        switch motion.timing {
        case .stepEnd:
            // Each value holds until the next key time; discrete mode
            // takes one fewer value than key times.
            animation.calculationMode = .discrete
            values.removeLast()
        case .linear:
            animation.calculationMode = .linear
        case .easeInOut:
            animation.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: values.count - 1)
        case .cubicBezier:
            let p = (motion.controlPoints ?? [0.42, 0, 0.58, 1]).map(Float.init)
            let function = CAMediaTimingFunction(controlPoints: p[0], p[1], p[2], p[3])
            animation.timingFunctions = Array(repeating: function, count: values.count - 1)
        }
        animation.values = values.map { NSNumber(value: $0) }
        animation.duration = use.duration
        animation.repeatCount = .infinity
        animation.beginTime = start
        animation.timeOffset = use.offset ?? 0
        animation.isRemovedOnCompletion = false
        layer.add(animation, forKey: keyPath)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// The raccoon in the planning window's bottom-right corner while a task
/// is under way (owner request, 2026-11-02). It shows the same pose and motion as
/// the floating panel and never takes clicks.
struct RaccoonWindowView: View {
    let model: AppModel
    var margin = RaccoonCompanionController.margin
    /// In the Now card the bubble is a small tag floating over the raccoon,
    /// taking no room, without the buttons the card already has (owner
    /// feedback, 2026-11-03). In the window's corner it sits above it.
    var isInNowCard = false
    /// Whether the Now card around it shows the session controls; when it
    /// does not, the tag carries all of the peek's buttons.
    var cardShowsSessionControls = true
    /// Whether the unread note shows; the Review queue page leaves it out,
    /// since the page already shows the same and the note would cover it.
    var showsNote = true

    var body: some View {
        if model.raccoonIsInWindow,
           let presence = RaccoonPresence.inWindow(mode: model.displayPreferences.raccoonMode, activity: model.raccoonActivity,
                                                   peek: model.raccoonPeek, note: showsNote ? model.raccoonUnreadNote : nil),
           let art = model.raccoon.loadArt() {
            let raccoon = RaccoonStage(art: art, poseID: presence.poseID)
                .frame(width: RaccoonStage.size(art).width, height: RaccoonStage.size(art).height)
                .allowsHitTesting(false)
            Group {
                if isInNowCard {
                    // Trailing-aligned, so a long tag grows to the left and
                    // stays inside the card.
                    raccoon.overlay(alignment: .topTrailing) {
                        if let message = presence.message ?? presence.note {
                            RaccoonWindowBubble(message: message, actions: presence.message != nil ? cardlessActions : [],
                                                model: model, isCompact: true, isNote: presence.message == nil)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: RaccoonWindowBubble.compactMaxWidth, alignment: .trailing)
                                .fixedSize(horizontal: true, vertical: false)
                                .alignmentGuide(.top) { $0[.bottom] - 18 }
                        }
                    }
                } else {
                    VStack(alignment: .trailing, spacing: 4) {
                        if let message = presence.message {
                            RaccoonWindowBubble(message: message, actions: model.raccoonPeek?.actions ?? [], model: model)
                        } else if let note = presence.note {
                            RaccoonWindowBubble(message: note, actions: [], model: model, isNote: true)
                        }
                        raccoon
                    }
                }
            }
            .padding(margin)
            .transition(.opacity)
        }
    }
}

extension RaccoonWindowView {
    /// The peek's buttons the Now card doesn't already offer. With the
    /// session controls in the card, those are left out (Got it and Done
    /// are a click on the tag); Keep going and Go to agent stay. Without
    /// them, all.
    var cardlessActions: [RaccoonPeekAction] {
        let actions = model.raccoonPeek?.actions ?? []
        guard cardShowsSessionControls else { return actions }
        return actions.filter { !$0.isSessionControl }
    }
}

/// A peek's speech bubble inside the planning window (owner request,
/// 2026-11-03): the message and the peek's buttons, which run the same
/// commands as the floating bubble's. Clicking the message dismisses it;
/// clicking the unread note opens the Review queue (2026-11-10).
private struct RaccoonWindowBubble: View {
    /// The Now card's tag never grows wider than this: its text stays on
    /// one line and truncates; any buttons sit in a row below the text.
    static let compactMaxWidth: CGFloat = 240

    let message: String
    let actions: [RaccoonPeekAction]
    let model: AppModel
    /// A one-line tag: smaller text and padding, no fixed width.
    var isCompact = false
    /// The unread note rather than a peek.
    var isNote = false
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Text(message)
                .font(isCompact ? .caption.weight(.medium) : .callout.weight(.medium))
                .lineLimit(isCompact ? 1 : nil)
                .monospacedDigit()
                .foregroundStyle(palette.color(.ink))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { if isNote { model.requestedPage = .review } else { model.raccoon.endPeek() } }
                .help(isNote ? "Click to open the Review queue"
                      : actions.isEmpty ? "Click to dismiss" : "Click the message to dismiss")
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(isNote ? "Opens the Review queue" : "Dismisses the raccoon’s reminder")
            if !actions.isEmpty {
                HStack(spacing: 6) {
                    ForEach(actions, id: \.self) { action in
                        Button(action.title) { model.performRaccoonAction(action) }
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, isCompact ? 8 : 12)
        .padding(.vertical, isCompact ? 4 : 8)
        .frame(width: isCompact ? nil : 220)
        .background(palette.color(isCompact ? .bg : .surface), in: RoundedRectangle(cornerRadius: isCompact ? 8 : 10))
        .overlay(RoundedRectangle(cornerRadius: isCompact ? 8 : 10).stroke(palette.color(.line)))
    }
}

/// `RaccoonStageView` for SwiftUI, without a bubble.
private struct RaccoonStage: NSViewRepresentable {
    let art: RaccoonArt
    let poseID: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func size(_ art: RaccoonArt) -> CGSize {
        let pixels = CGFloat(art.manifest.frameSize)
        let ppp = RaccoonCompanionController.pointsPerPixel
        return CGSize(width: (pixels + 2 * RaccoonCompanionController.sideRoom) * ppp, height: pixels * ppp)
    }

    func makeNSView(context: Context) -> RaccoonStageView {
        RaccoonStageView(frameSize: CGFloat(art.manifest.frameSize), sideRoom: RaccoonCompanionController.sideRoom,
                         pointsPerPixel: RaccoonCompanionController.pointsPerPixel, bubbleRoom: 0)
    }

    func updateNSView(_ stage: RaccoonStageView, context: Context) {
        guard context.coordinator.shown != poseID || context.coordinator.reduceMotion != reduceMotion,
              let pose = art.manifest.pose(poseID), let layers = try? art.layers(of: poseID)
        else { return }
        context.coordinator.shown = poseID
        context.coordinator.reduceMotion = reduceMotion
        stage.show(pose: pose, layers: layers, motions: art.manifest.motions, reduceMotion: reduceMotion)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var shown: String?
        var reduceMotion: Bool?
    }
}

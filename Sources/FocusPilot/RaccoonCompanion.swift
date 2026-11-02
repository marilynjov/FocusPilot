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
        // Move to the corner again when displays change.
        observers.append(Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didChangeScreenParametersNotification) {
                guard let self else { break }
                placePanel()
            }
        })
    }

    /// Why the art could not be loaded, if it could not.
    var problem: String? { artError }

    /// Shows, changes or hides the raccoon for the current mode and session.
    func update() {
        let presence = RaccoonPresence.resolve(mode: model.displayPreferences.raccoonMode, activity: model.raccoonActivity,
                                               isWindowOpen: model.raccoonIsInWindow, peek: model.raccoonPeek)
        guard presence != shown || (presence != nil && panel == nil) else { return }
        shown = presence
        if let presence { show(presence) } else { hide() }
    }

    /// Brings the raccoon in with `peek` for `duration` (D12 reminders),
    /// replacing any earlier peek. In Off mode nothing shows.
    func peek(_ peek: RaccoonPeek, for duration: Duration = defaultPeek) {
        model.raccoonPeek = peek
        peekTask?.cancel()
        peekTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.endPeek()
        }
        update()
    }

    func endPeek() {
        peekTask?.cancel()
        peekTask = nil
        model.raccoonPeek = nil
        update()
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
        stage?.setBubble(presence.message)
        placePanel()
        panel.orderFrontRegardless()
    }

    private func hide() {
        stage?.setBubble(nil)
        panel?.orderOut(nil)
        panel = nil
        stage = nil
    }

    private func redraw() {
        guard let shown else { return }
        show(shown)
    }

    private func makePanel(frameSize: CGFloat) -> RaccoonPanel {
        let stage = RaccoonStageView(frameSize: frameSize, sideRoom: Self.sideRoom, pointsPerPixel: Self.pointsPerPixel)
        stage.onBubbleClick = { [weak self] in self?.endPeek() }
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
        stage.onBubbleChange = { [weak panel] hasBubble in panel?.followsMouseForBubble(hasBubble) }
        self.stage = stage
        return panel
    }

    /// Bottom-right corner of the chosen display, above the Dock.
    func placePanel() {
        guard let panel, let screen = NSScreen.raccoonScreen(model.displayPreferences.raccoonScreen) else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.maxX - size.width - Self.margin, y: visible.minY + Self.margin))
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
    private var mouseTimer: Timer?

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// With a bubble shown, takes the mouse only while it is over the
    /// bubble; a polled check, since an ignoring window gets no events.
    func followsMouseForBubble(_ follows: Bool) {
        mouseTimer?.invalidate()
        mouseTimer = nil
        ignoresMouseEvents = true
        guard follows else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateMouse() }
        }
        RunLoop.main.add(timer, forMode: .common)
        mouseTimer = timer
    }

    private func updateMouse() {
        guard let stage = contentView as? RaccoonStageView, let bubble = stage.bubbleFrame else {
            ignoresMouseEvents = true
            return
        }
        let onScreen = convertToScreen(stage.convert(bubble, to: nil))
        ignoresMouseEvents = !onScreen.contains(NSEvent.mouseLocation)
    }
}

/// Draws one pose with a Core Animation layer per raccoon layer, and an
/// optional speech bubble above it.
@MainActor
final class RaccoonStageView: NSView {
    static let bubbleHeight: CGFloat = 64

    let frameSize: CGFloat
    let sideRoom: CGFloat
    let pointsPerPixel: CGFloat
    var onBubbleClick: (() -> Void)?
    var onBubbleChange: ((Bool) -> Void)?
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
        guard let bubble, bubble.frame.contains(convert(point, from: superview)) else { return nil }
        return bubble
    }

    var bubbleFrame: NSRect? { bubble?.frame }

    func show(pose: RaccoonPoseArt, layers: [RaccoonLayer: CGImage], motions: [String: RaccoonMotion], reduceMotion: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        poseLayer.sublayers = nil
        RaccoonRig(pose: pose, images: layers, motions: motions, frameSize: frameSize, animates: !reduceMotion)
            .build(into: poseLayer)
        CATransaction.commit()
        setAccessibilityLabel("Raccoon companion: \(pose.name)")
    }

    func setBubble(_ message: String?) {
        bubble?.removeFromSuperview()
        bubble = nil
        if let message {
            let view = RaccoonBubbleView(message: message, maxWidth: bounds.width)
            view.setFrameOrigin(NSPoint(x: bounds.maxX - view.frame.width, y: frameSize * pointsPerPixel - 4))
            view.onClick = { [weak self] in self?.onBubbleClick?() }
            addSubview(view)
            bubble = view
        }
        onBubbleChange?(bubble != nil)
    }
}

/// The speech bubble: a placeholder for D12's reminders. Clicking it ends
/// the peek. It accepts the first click, since its panel is never key.
final class RaccoonBubbleView: NSView {
    var onClick: (() -> Void)?

    init(message: String, maxWidth: CGFloat) {
        let label = NSTextField(wrappingLabelWithString: message)
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        label.textColor = .labelColor
        label.preferredMaxLayoutWidth = maxWidth - 24
        label.isSelectable = false
        let size = label.fittingSize
        super.init(frame: NSRect(x: 0, y: 0, width: min(size.width + 24, maxWidth),
                                 height: min(size.height + 16, RaccoonStageView.bubbleHeight)))
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        label.frame = bounds.insetBy(dx: 12, dy: 8)
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(message)
        toolTip = "Click to dismiss"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    override var wantsUpdateLayer: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
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

    var body: some View {
        if model.raccoonIsInWindow,
           let presence = RaccoonPresence.inWindow(mode: model.displayPreferences.raccoonMode, activity: model.raccoonActivity,
                                                   peek: model.raccoonPeek),
           let art = model.raccoon.loadArt() {
            RaccoonStage(art: art, poseID: presence.poseID)
                .frame(width: RaccoonStage.size(art).width, height: RaccoonStage.size(art).height)
                .padding(RaccoonCompanionController.margin)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
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

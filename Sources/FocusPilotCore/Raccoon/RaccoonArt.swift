import Foundation

/// The raccoon companion's art: one PNG strip per pose plus `raccoon.json`,
/// generated from the owner's pose sheet by `scripts/build-raccoon-art.sh`
/// (decision 0004, 2026-11-02). The app bundles them in
/// `Contents/Resources/Raccoon`.
///
/// Coordinates are frame pixels: each layer is a `frameSize` square, origin
/// at the top left, y pointing down. A strip holds the pose's layers side by
/// side in the order of `RaccoonPoseArt.layers`.
public struct RaccoonArtManifest: Codable, Equatable, Sendable {
    public static let fileName = "raccoon.json"

    public var frameSize: Int
    public var poses: [RaccoonPoseArt]
    /// Motions by name, referenced from each pose's `motion`.
    public var motions: [String: RaccoonMotion]

    public init(frameSize: Int, poses: [RaccoonPoseArt], motions: [String: RaccoonMotion]) {
        self.frameSize = frameSize
        self.poses = poses
        self.motions = motions
    }

    public func pose(_ id: String) -> RaccoonPoseArt? {
        poses.first { $0.id == id }
    }
}

/// One layer of a pose. Drawn back to front in `allCases` order, except that
/// `eyesClosed` replaces `head` (or `body`, in a pose without a head layer)
/// while the raccoon blinks.
public enum RaccoonLayer: String, Codable, CaseIterable, Sendable {
    /// The floor shadow. It never moves sideways except under the walking pose.
    case shadow
    /// Walking only: four legs, left to right, each swung about its pivot.
    case leg1, leg2, leg3, leg4
    case body
    /// Tilted about the pose's head pivot.
    case head
    case eyesClosed
    /// Objects that never move: the laptop, the sign, the wall, the ledge and paws.
    case still
    /// Floating effects that move on their own: hearts, zzz, steam, question marks.
    case effects

    /// Whether the raccoon's own motion (tilt, breathing, bouncing, legs) moves
    /// this layer. Still objects never move; the shadow follows only the
    /// walking pose's walk and the excited pose's squash.
    public var movesWithRaccoon: Bool {
        switch self {
        case .shadow, .still: false
        case .leg1, .leg2, .leg3, .leg4, .body, .head, .eyesClosed, .effects: true
        }
    }

    public static let legs: [RaccoonLayer] = [.leg1, .leg2, .leg3, .leg4]
}

public struct RaccoonPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct RaccoonPoseArt: Codable, Equatable, Sendable {
    /// Stable identifier, also the strip's base name (`sit` → `sit.png`).
    public var id: String
    /// User-facing name from the sheet, e.g. "Idle" or "Working".
    public var name: String
    /// Short user-facing line for when the pose is used.
    public var caption: String
    public var image: String
    public var layers: [RaccoonLayer]
    /// Where the head layer turns; nil when the pose has no separate head.
    public var headPivot: RaccoonPoint?
    /// Walking only: one pivot per leg layer, in `RaccoonLayer.legs` order.
    public var legPivots: [RaccoonPoint]?
    public var motion: RaccoonPoseMotion

    public init(id: String, name: String, caption: String, image: String, layers: [RaccoonLayer],
                headPivot: RaccoonPoint?, legPivots: [RaccoonPoint]?, motion: RaccoonPoseMotion) {
        self.id = id
        self.name = name
        self.caption = caption
        self.image = image
        self.layers = layers
        self.headPivot = headPivot
        self.legPivots = legPivots
        self.motion = motion
    }
}

/// How a pose moves in the owner-approved mockup (the "Raccoon moods" screen
/// of the design canvas). Every entry is optional: a missing entry means that
/// part stays still. The macOS setting Reduce motion turns all of it off.
public struct RaccoonPoseMotion: Codable, Equatable, Sendable {
    /// Head tilt, about `headPivot`.
    public var head: RaccoonMotionUse?
    /// Breathing; scales body, legs and head together.
    public var body: RaccoonMotionUse?
    /// Moves the whole raccoon (body, legs and head, not still objects).
    public var move: RaccoonMotionUse?
    /// A second, faster movement of the whole raccoon on top of `move`.
    public var hop: RaccoonMotionUse?
    public var shadow: RaccoonMotionUse?
    public var effects: RaccoonMotionUse?
    /// One entry per leg layer, about the matching `legPivots` entry.
    public var legs: [RaccoonMotionUse]?
    /// Opacity of the `eyesClosed` layer.
    public var blink: RaccoonMotionUse?
    /// Raccoon layers (everything but still objects, effects and the shadow)
    /// are clipped to x < `clipMaxX`, in frame pixels before any motion, so
    /// the Peek pose can duck behind its wall.
    public var clipMaxX: Double?

    public init(head: RaccoonMotionUse? = nil, body: RaccoonMotionUse? = nil, move: RaccoonMotionUse? = nil,
                hop: RaccoonMotionUse? = nil, shadow: RaccoonMotionUse? = nil, effects: RaccoonMotionUse? = nil,
                legs: [RaccoonMotionUse]? = nil, blink: RaccoonMotionUse? = nil, clipMaxX: Double? = nil) {
        self.head = head
        self.body = body
        self.move = move
        self.hop = hop
        self.shadow = shadow
        self.effects = effects
        self.legs = legs
        self.blink = blink
        self.clipMaxX = clipMaxX
    }
}

/// A motion played on repeat with a pose-specific duration.
public struct RaccoonMotionUse: Codable, Equatable, Sendable {
    /// A key of `RaccoonArtManifest.motions`.
    public var motion: String
    /// Seconds per cycle.
    public var duration: Double
    /// Seconds into the cycle at which playback starts.
    public var offset: Double?

    public init(motion: String, duration: Double, offset: Double? = nil) {
        self.motion = motion
        self.duration = duration
        self.offset = offset
    }
}

/// Keyframes for one repeating cycle, following CSS animation semantics: a
/// property missing from a keyframe is interpolated between the keyframes
/// that set it, and `timing` applies between consecutive keyframes.
public struct RaccoonMotion: Codable, Equatable, Sendable {
    public enum Timing: String, Codable, Sendable {
        case linear, easeInOut, cubicBezier
        /// Each keyframe's values hold until the next keyframe.
        case stepEnd
    }

    public var timing: Timing
    /// For `cubicBezier`: x1, y1, x2, y2.
    public var controlPoints: [Double]?
    /// Transform origin as a fraction of the frame (0.5, 1 is bottom center).
    /// Nil for head and leg motions, which turn about the pose's pivots.
    public var origin: RaccoonPoint?
    public var keyframes: [RaccoonKeyframe]

    public init(timing: Timing, controlPoints: [Double]? = nil, origin: RaccoonPoint? = nil, keyframes: [RaccoonKeyframe]) {
        self.timing = timing
        self.controlPoints = controlPoints
        self.origin = origin
        self.keyframes = keyframes
    }
}

public struct RaccoonKeyframe: Codable, Equatable, Sendable {
    /// Fractions of the cycle, 0 to 1, that share these values.
    public var at: [Double]
    /// Degrees, positive clockwise on screen.
    public var rotate: Double?
    /// Frame pixels.
    public var translateX: Double?
    public var translateY: Double?
    public var scaleX: Double?
    public var scaleY: Double?
    public var opacity: Double?

    public init(at: [Double], rotate: Double? = nil, translateX: Double? = nil, translateY: Double? = nil,
                scaleX: Double? = nil, scaleY: Double? = nil, opacity: Double? = nil) {
        self.at = at
        self.rotate = rotate
        self.translateX = translateX
        self.translateY = translateY
        self.scaleX = scaleX
        self.scaleY = scaleY
        self.opacity = opacity
    }
}

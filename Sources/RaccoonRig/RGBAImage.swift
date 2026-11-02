import Foundation

public struct Pixel: Equatable, Sendable {
    public var r, g, b, a: UInt8

    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    public static let clear = Pixel(0, 0, 0, 0)

    /// r + g + b. Comparing it with 3k is exact where the prototype compared
    /// the channel mean with k.
    var sum: Int { Int(r) + Int(g) + Int(b) }
}

/// An 8-bit RGBA image with straight (not premultiplied) alpha, rows top to
/// bottom. Fully transparent pixels are always stored as 0, 0, 0, 0.
public struct RGBAImage: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public private(set) var bytes: [UInt8]

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
        bytes = [UInt8](repeating: 0, count: width * height * 4)
    }

    public init(width: Int, height: Int, bytes: [UInt8]) {
        precondition(bytes.count == width * height * 4)
        self.width = width
        self.height = height
        self.bytes = bytes
        for i in stride(from: 0, to: bytes.count, by: 4) where bytes[i + 3] == 0 {
            self.bytes[i] = 0
            self.bytes[i + 1] = 0
            self.bytes[i + 2] = 0
        }
    }

    public func contains(_ x: Int, _ y: Int) -> Bool {
        x >= 0 && y >= 0 && x < width && y < height
    }

    public subscript(x: Int, y: Int) -> Pixel {
        get {
            let i = (y * width + x) * 4
            return Pixel(bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3])
        }
        set {
            let i = (y * width + x) * 4
            let p = newValue.a == 0 ? .clear : newValue
            bytes[i] = p.r
            bytes[i + 1] = p.g
            bytes[i + 2] = p.b
            bytes[i + 3] = p.a
        }
    }

    public func alpha(_ x: Int, _ y: Int) -> UInt8 {
        bytes[(y * width + x) * 4 + 3]
    }

    public var isEmpty: Bool {
        stride(from: 3, to: bytes.count, by: 4).allSatisfy { bytes[$0] == 0 }
    }

    /// Bounding box (x0, y0, x1, y1), end exclusive, of pixels with alpha
    /// above `threshold`; nil when there are none.
    public func boundingBox(alphaAbove threshold: UInt8 = 0) -> (x0: Int, y0: Int, x1: Int, y1: Int)? {
        var x0 = width, y0 = height, x1 = -1, y1 = -1
        for y in 0..<height {
            for x in 0..<width where alpha(x, y) > threshold {
                x0 = min(x0, x); x1 = max(x1, x)
                y0 = min(y0, y); y1 = max(y1, y)
            }
        }
        return x1 < 0 ? nil : (x0, y0, x1 + 1, y1 + 1)
    }

    /// The region (x0, y0) to (x1, y1), end exclusive; outside pixels are transparent.
    public func cropped(x0: Int, y0: Int, x1: Int, y1: Int) -> RGBAImage {
        var out = RGBAImage(width: x1 - x0, height: y1 - y0)
        let from = max(x0, 0), to = min(x1, width)
        let top = max(y0, 0), bottom = min(y1, height)
        guard from < to, top < bottom else { return out }
        for y in top..<bottom {
            let source = (y * width + from) * 4, target = ((y - y0) * out.width + (from - x0)) * 4
            out.bytes.replaceSubrange(target..<(target + (to - from) * 4), with: bytes[source..<(source + (to - from) * 4)])
        }
        return out
    }

    /// Copies `image` with its top left at (x, y), replacing what is there.
    public mutating func paste(_ image: RGBAImage, x: Int, y: Int) {
        let from = max(0, -x), to = min(image.width, width - x)
        let top = max(0, -y), bottom = min(image.height, height - y)
        guard from < to, top < bottom else { return }
        for sy in top..<bottom {
            let source = (sy * image.width + from) * 4, target = ((y + sy) * width + x + from) * 4
            bytes.replaceSubrange(target..<(target + (to - from) * 4), with: image.bytes[source..<(source + (to - from) * 4)])
        }
    }

    /// Source-over compositing of `image` (same size) on top of this one.
    public mutating func composite(_ image: RGBAImage) {
        precondition(image.width == width && image.height == height)
        for i in stride(from: 0, to: bytes.count, by: 4) {
            let sa = Int(image.bytes[i + 3])
            if sa == 0 { continue }
            if sa == 255 {
                for c in 0..<4 { bytes[i + c] = image.bytes[i + c] }
                continue
            }
            let da = Int(bytes[i + 3])
            let outA = sa * 255 + da * (255 - sa)  // scaled by 255
            for c in 0..<3 {
                let value = (Int(image.bytes[i + c]) * sa * 255 + Int(bytes[i + c]) * da * (255 - sa) + outA / 2) / outA
                bytes[i + c] = UInt8(value)
            }
            bytes[i + 3] = UInt8((outA + 127) / 255)
        }
    }

    /// Cuts the frames of a horizontal strip of `frameSize` squares.
    public func frames(of frameSize: Int) -> [RGBAImage] {
        (0..<(width / frameSize)).map { cropped(x0: $0 * frameSize, y0: 0, x1: ($0 + 1) * frameSize, y1: frameSize) }
    }

    /// The frames side by side, left to right.
    public static func strip(_ frames: [RGBAImage]) -> RGBAImage {
        let size = frames.first?.height ?? 0
        var out = RGBAImage(width: size * frames.count, height: size)
        for (i, frame) in frames.enumerated() {
            out.paste(frame, x: i * size, y: 0)
        }
        return out
    }
}

/// A set of pixel positions in a width × height image.
struct PixelMask {
    let width: Int
    let height: Int
    private(set) var bits: [Bool]

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        bits = [Bool](repeating: false, count: width * height)
    }

    subscript(x: Int, y: Int) -> Bool {
        get { bits[y * width + x] }
        set { bits[y * width + x] = newValue }
    }

    var points: [(x: Int, y: Int)] {
        bits.indices.filter { bits[$0] }.map { ($0 % width, $0 / width) }
    }

    var count: Int { bits.lazy.filter { $0 }.count }

    /// Bounding box, end inclusive.
    var bounds: (x0: Int, y0: Int, x1: Int, y1: Int)? {
        var x0 = width, y0 = height, x1 = -1, y1 = -1
        for (x, y) in points {
            x0 = min(x0, x); x1 = max(x1, x)
            y0 = min(y0, y); y1 = max(y1, y)
        }
        return x1 < 0 ? nil : (x0, y0, x1, y1)
    }

    mutating func formUnion(_ other: PixelMask) {
        for i in bits.indices where other.bits[i] { bits[i] = true }
    }
}

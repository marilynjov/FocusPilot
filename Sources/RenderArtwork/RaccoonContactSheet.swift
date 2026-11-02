import AppKit
import FocusPilotCore
import RaccoonRig

/// One image of every raccoon pose for the owner's review: each pose at rest,
/// and next to it with the head tilted, eyes closed and legs swung, which
/// shows any seam between layers. Still objects and the shadow stay put.
@MainActor
enum RaccoonContactSheet {
    private static let columns = 5
    private static let gap = 8
    private static let margin = 24
    private static let labelHeight = 28
    private static let tilt: CGFloat = -5  // degrees, negative tilts left on screen
    private static let legSwing: CGFloat = 13

    static func write(artDirectory: URL, to url: URL) throws {
        let manifest = try JSONDecoder().decode(
            RaccoonArtManifest.self, from: Data(contentsOf: artDirectory.appending(path: RaccoonArtManifest.fileName)))
        let size = manifest.frameSize
        let cellWidth = 2 * size + gap + margin, cellHeight = size + labelHeight + margin
        let rows = (manifest.poses.count + columns - 1) / columns
        let width = margin + columns * cellWidth, height = margin + rows * cellHeight

        var layersByPose: [String: [RaccoonLayer: CGImage]] = [:]
        for pose in manifest.poses {
            let strip = try PNGCoding.read(artDirectory.appending(path: pose.image))
            layersByPose[pose.id] = RaccoonComposer.layers(of: strip, pose: pose, frameSize: size).mapValues(cgImage)
        }

        try writePNG(to: url, pixelsWide: width, pixelsHigh: height, appearance: Appearance.light.nsAppearance) {
            let context = NSGraphicsContext.current!.cgContext
            context.interpolationQuality = .none
            NSColor(white: 0.93, alpha: 1).setFill()
            CGRect(x: 0, y: 0, width: width, height: height).fill()

            for (index, pose) in manifest.poses.enumerated() {
                let left = margin + (index % columns) * cellWidth
                let top = margin + (index / columns) * cellHeight
                // Bottom-left corner of the frames in the context's y-up coordinates.
                let bottom = CGFloat(height - top - size)
                let layers = layersByPose[pose.id]!
                draw(layers, pose: pose, size: size, origin: CGPoint(x: left, y: Int(bottom)), moved: false, in: context)
                draw(layers, pose: pose, size: size, origin: CGPoint(x: CGFloat(left + size + gap), y: bottom), moved: true, in: context)

                let label = NSAttributedString(string: "\(pose.name) (\(pose.id))", attributes: [
                    .font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: NSColor.black,
                ])
                label.draw(at: CGPoint(x: CGFloat(left), y: bottom - CGFloat(labelHeight) + 4))
            }
        }
    }

    private static func draw(_ layers: [RaccoonLayer: CGImage], pose: RaccoonPoseArt, size: Int, origin: CGPoint,
                             moved: Bool, in context: CGContext) {
        let frame = CGRect(origin: origin, size: CGSize(width: size, height: size))
        context.setFillColor(NSColor.white.cgColor)
        context.fill(frame)
        let hasHead = layers[.head] != nil
        for layer in RaccoonLayer.allCases {
            guard let image = layers[layer] else { continue }
            if layer == .eyesClosed && !moved { continue }
            if moved && layers[.eyesClosed] != nil && layer == (hasHead ? .head : .body) { continue }

            var degrees: CGFloat = 0
            var pivot: RaccoonPoint?
            if moved, layer == .head || (layer == .eyesClosed && hasHead), let headPivot = pose.headPivot {
                degrees = tilt
                pivot = headPivot
            }
            if moved, let index = RaccoonLayer.legs.firstIndex(of: layer), let pivots = pose.legPivots {
                degrees = index == 0 || index == 3 ? legSwing : -legSwing
                pivot = pivots[index]
            }

            context.saveGState()
            context.clip(to: frame)
            if let pivot {
                // Frame coordinates are y-down; the context is y-up.
                let point = CGPoint(x: origin.x + pivot.x, y: origin.y + CGFloat(size) - pivot.y)
                context.translateBy(x: point.x, y: point.y)
                context.rotate(by: -degrees * .pi / 180)
                context.translateBy(x: -point.x, y: -point.y)
            }
            context.draw(image, in: frame)
            context.restoreGState()
        }
    }

    private static func cgImage(_ image: RGBAImage) -> CGImage {
        CGImage(
            width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: CGDataProvider(data: Data(image.bytes) as CFData)!, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }
}

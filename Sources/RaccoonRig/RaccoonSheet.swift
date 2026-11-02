import Foundation

/// The owner's "Raccoon Pet: poses & emotions" sheet (1263 × 1234, transparent):
/// 20 poses in a 5 × 4 grid. Slicing cuts each pose to its visible pixels and
/// scales all of them by one shared factor, nearest neighbor, onto a 256 × 256
/// frame, centered horizontally and standing 4 px above the bottom edge.
public enum RaccoonSheet {
    public static let frameSize = 256

    /// Pose identifiers in sheet order: left to right, top to bottom.
    public static let poseIDs = [
        "sit", "walk", "sleep", "rest", "love",
        "excited", "laptop", "ledge", "sniff", "coffee",
        "roll", "grumpy", "backpack", "confused", "back",
        "peek", "playbow", "crown", "lying", "sign",
    ]

    /// Grid cells on the sheet, end exclusive; captions and titles fall outside them.
    static let rows = [(118, 309), (412, 619), (725, 911), (993, 1157)]
    static let columns = [(15, 270), (270, 520), (520, 765), (765, 1010), (1010, 1262)]

    /// Sheet pixels with alpha at or below this are treated as empty when cropping.
    static let alphaThreshold: UInt8 = 40

    /// Each pose as a 256 × 256 image, keyed by pose identifier.
    public static func slice(_ sheet: RGBAImage) -> [String: RGBAImage] {
        var crops: [RGBAImage] = []
        for (y0, y1) in rows {
            for (x0, x1) in columns {
                let cell = sheet.cropped(x0: x0, y0: y0, x1: x1, y1: y1)
                let box = cell.boundingBox(alphaAbove: alphaThreshold)!
                crops.append(cell.cropped(x0: box.x0, y0: box.y0, x1: box.x1, y1: box.y1))
            }
        }
        let largest = crops.map { max($0.width, $0.height) }.max()!
        let scale = Double(frameSize - 8) / Double(largest)

        var poses: [String: RGBAImage] = [:]
        for (id, crop) in zip(poseIDs, crops) {
            let scaled = resizeNearest(crop, width: Int((Double(crop.width) * scale).rounded(.toNearestOrEven)),
                                       height: Int((Double(crop.height) * scale).rounded(.toNearestOrEven)))
            var frame = RGBAImage(width: frameSize, height: frameSize)
            let left = (frameSize - scaled.width) / 2, top = frameSize - 4 - scaled.height
            for y in 0..<scaled.height {
                for x in 0..<scaled.width where scaled.alpha(x, y) > 0 {
                    frame[left + x, top + y] = scaled[x, y]
                }
            }
            poses[id] = frame
        }
        return poses
    }

    /// Nearest-neighbor resize that samples the source pixel under each
    /// output pixel's center, stepping the way Pillow's NEAREST filter does,
    /// so the frames match the prototype the owner reviewed.
    static func resizeNearest(_ image: RGBAImage, width: Int, height: Int) -> RGBAImage {
        let stepX = Double(image.width) / Double(width), stepY = Double(image.height) / Double(height)
        var sourceX: [Int] = []
        var position = stepX * 0.5
        for _ in 0..<width {
            sourceX.append(min(Int(position), image.width - 1))
            position += stepX
        }
        var out = RGBAImage(width: width, height: height)
        position = stepY * 0.5
        for y in 0..<height {
            let sy = min(Int(position), image.height - 1)
            for x in 0..<width {
                out[x, y] = image[sourceX[x], sy]
            }
            position += stepY
        }
        return out
    }
}

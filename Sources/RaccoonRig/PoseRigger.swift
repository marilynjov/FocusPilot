import Foundation
import FocusPilotCore

/// A pose split into layers. Layers that would be empty are left out.
public struct RiggedPose: Sendable {
    public var layers: [RaccoonLayer: RGBAImage]
    public var headPivot: RaccoonPoint?

    /// Present layers in drawing order.
    public var layerOrder: [RaccoonLayer] {
        RaccoonLayer.allCases.filter { layers[$0] != nil }
    }
}

/// Splits one 256 × 256 pose into layers: body, head, a closed-eyes head,
/// still objects, floating effects and the floor shadow, plus four legs for
/// walking.
///
/// The per-pose numbers (eye boxes, head cut-outs, still-object regions) were
/// tuned by eye with the owner on the prototype and are kept as they were.
public enum PoseRigger {
    typealias Box = (x0: Int, y0: Int, x1: Int, y1: Int)

    /// Eye boxes, end inclusive, painted over with fur and a closed-eye curve.
    static let eyes: [String: [Box]] = [
        "sit": [(126, 101, 141, 114), (161, 100, 177, 118)],
        "walk": [(211, 158, 225, 174)],
        "love": [(81, 99, 97, 113), (117, 95, 138, 110)],
        "excited": [(132, 92, 142, 106), (158, 78, 178, 93)],
        "laptop": [(110, 141, 127, 156), (145, 140, 163, 156)],
        "ledge": [(94, 200, 115, 218), (140, 200, 161, 217)],
        "sniff": [(135, 67, 146, 76)],
        "coffee": [(84, 119, 97, 131), (122, 119, 135, 132)],
        "grumpy": [(93, 134, 108, 144), (120, 136, 141, 148)],
        "backpack": [(145, 99, 159, 112), (174, 90, 189, 111)],
        "confused": [(97, 123, 111, 135), (122, 104, 138, 116)],
        "peek": [(128, 137, 145, 154)],
        "playbow": [(64, 191, 77, 208), (92, 195, 104, 208)],
        "crown": [(96, 131, 113, 147), (133, 130, 147, 144)],
        "sign": [(115, 115, 128, 128), (148, 115, 164, 128)],
    ]

    /// Poses whose head is not cut out from the body (curled up, lying, from
    /// behind). The ledge pose is all head: everything above the ledge tilts.
    static let withoutHead: Set<String> = ["ledge", "playbow", "sleep", "rest", "lying", "back", "roll"]

    /// The peek pose's wall starts at this column.
    static let peekWallX = 168
    /// The shadow is taken only from rows at or below this.
    static let shadowTop = 228
    /// Walking: leg rows start here, and the body keeps rows up to `legOverlapEnd`
    /// so a swung leg leaves no gap at the hip.
    static let legTop = 204
    static let legOverlapEnd = 214
    static let legSplitX = [82, 130, 172]

    static let size = RaccoonSheet.frameSize

    public static func rig(_ pose: RGBAImage, id: String) -> RiggedPose {
        let n = size
        var front: Box?  // still-object rectangle, end exclusive
        var frontMask: PixelMask?
        var ledgeLine = 0

        // Still objects.
        if id == "laptop" {
            let c0 = pose[160, 215]
            let core = regionMask(pose, seed: (160, 215)) { p in
                abs(Int(p.r) - Int(c0.r)) + abs(Int(p.g) - Int(c0.g)) + abs(Int(p.b) - Int(c0.b)) < 70
            }
            // The laptop is cut by its full row span, so the paws on its keys
            // stay with it, and nothing behind it is filled in.
            var rows: [Int: (Int, Int)] = [:]
            for (x, y) in core.points {
                let r = rows[y] ?? (x, x)
                rows[y] = (min(r.0, x), max(r.1, x))
            }
            let top = rows.keys.min()!, bottom = rows.keys.max()!
            var mask = PixelMask(width: n, height: n)
            for y in (top - 7)..<n {
                guard let r = rows[min(max(y, top + 3), bottom)] else { continue }
                for x in max(0, r.0 - 3)..<min(n, r.1 + 4) where pose.alpha(x, y) > 0 {
                    mask[x, y] = true
                }
            }
            frontMask = mask
        }
        if id == "sign" {
            frontMask = regionMask(pose, seed: (118, 175)) { $0.sum > 510 }
        }
        if var mask = frontMask {
            // Grow into the object's outline and shading (cool or dark pixels).
            func cool(_ x: Int, _ y: Int) -> Bool {
                let p = pose[x, y]
                return p.a > 40 && (Int(p.b) >= Int(p.r) - 3 || p.sum < 180 || (id == "sign" && p.sum > 570))
            }
            for _ in 0..<(id == "laptop" ? 0 : 8) {
                var add = PixelMask(width: n, height: n)
                for (x, y) in mask.points {
                    for (nx, ny) in [(x, y - 1), (x - 1, y), (x + 1, y)]
                    where pose.contains(nx, ny) && !mask[nx, ny] && cool(nx, ny) {
                        add[nx, ny] = true
                    }
                }
                mask.formUnion(add)
            }
            let b = mask.bounds!
            front = (b.x0, b.y0, b.x1 + 1, b.y1 + 1)
            frontMask = mask
        }
        if id == "peek" {
            front = (peekWallX, 0, n, n)
        }
        if id == "ledge" {
            // The ledge is the row with the most dark outline pixels.
            func darkCount(_ y: Int) -> Int {
                (0..<n).filter { pose.alpha($0, y) > 200 && pose[$0, y].sum < 180 }.count
            }
            var best = 150
            for y in 150..<n where darkCount(y) > darkCount(best) { best = y }
            front = (0, best - 16, n, n)
            ledgeLine = best
        }
        func inFrontRect(_ x: Int, _ y: Int) -> Bool {
            guard let f = front else { return false }
            return f.x0 <= x && x < f.x1 && f.y0 <= y && y < f.y1
        }

        // Floating effects: separate pieces that are neither the raccoon, nor
        // inside a still object, nor on the floor. Pieces under 8 px are specks
        // and are removed.
        var base = pose
        var effects = RGBAImage(width: n, height: n)
        let components = components(of: pose)
        let largest = components.map(\.count).max() ?? 0
        for component in components where component.count != largest {
            if front != nil && component.allSatisfy({ inFrontRect($0.x, $0.y) }) { continue }
            let top = component.map(\.y).min()!
            if component.count < 8 {
                for (x, y) in component { base[x, y] = .clear }
                continue
            }
            if top > 225 { continue }
            for (x, y) in component {
                effects[x, y] = pose[x, y]
                base[x, y] = .clear
            }
        }

        // Floor shadow: light bluish pixels near the bottom, never from a still object.
        var shadow = RGBAImage(width: n, height: n)
        for x in 0..<n {
            for y in shadowTop..<n {
                if let mask = frontMask { if mask[x, y] { continue } } else if inFrontRect(x, y) { continue }
                let p = base[x, y]
                if p.a > 30 && Int(p.b) >= Int(p.r) + 10 && Int(p.b) >= Int(p.g) + 6 && p.sum > 390 {
                    shadow[x, y] = p
                    base[x, y] = .clear
                }
            }
        }

        // Move still objects out of the base. Except under the laptop and the
        // wall, fill the hole 3 px deep with neighboring fur so moving parts
        // show no gap at the object's edge.
        var still = RGBAImage(width: n, height: n)
        if let f = front {
            var points: [(x: Int, y: Int)] = []
            if let mask = frontMask {
                points = mask.points
            } else {
                for y in f.y0..<f.y1 { for x in f.x0..<f.x1 { points.append((x, y)) } }
            }
            var hole: [(x: Int, y: Int)] = []
            for (x, y) in points {
                if base.alpha(x, y) > 40 { hole.append((x, y)) }
                still[x, y] = base[x, y]
                base[x, y] = .clear
            }
            for _ in 0..<(id == "laptop" || id == "peek" ? 0 : 3) {
                var updates: [(Int, Int, Pixel)] = []
                for (x, y) in hole where base.alpha(x, y) == 0 {
                    for (nx, ny) in [(x, y - 1), (x - 1, y), (x + 1, y), (x, y + 1)]
                    where base.contains(nx, ny) && base.alpha(nx, ny) > 200 {
                        updates.append((x, y, base[nx, ny]))
                        break
                    }
                }
                for (x, y, p) in updates { base[x, y] = p }
            }
        }

        // Head and body.
        let eyeBoxes = eyes[id] ?? []
        var body: RGBAImage
        var head: RGBAImage?
        var eyesClosed: RGBAImage?
        var pivot: RaccoonPoint?
        if withoutHead.contains(id) {
            if id == "ledge" {
                body = RGBAImage(width: n, height: n)
                head = base
                eyesClosed = closedEyes(base, eyeBoxes)
                pivot = RaccoonPoint(x: 128, y: Double(ledgeLine))
            } else {
                body = base
                eyesClosed = eyeBoxes.isEmpty ? nil : closedEyes(base, eyeBoxes)
            }
        } else {
            var cx = 0.0, cy = 0.0
            for e in eyeBoxes { cx += Double(e.x0 + e.x1) / 2 }
            for e in eyeBoxes { cy += Double(e.y0 + e.y1) / 2 }
            cx /= Double(eyeBoxes.count)
            cy /= Double(eyeBoxes.count)
            let spacing = eyeBoxes.count > 1
                ? abs(Double(eyeBoxes[1].x0 + eyeBoxes[1].x1) / 2 - Double(eyeBoxes[0].x0 + eyeBoxes[0].x1) / 2)
                : 34
            var x0: Int, x1: Int, neck: Int
            let top = 0
            switch id {
            case "walk": (x0, x1, neck) = (178, 256, Int(cy + 30)); cx = 210
            case "sniff": (x0, x1, neck) = (Int(cx - 75), Int(cx + 60), Int(cy + 48))
            case "grumpy": (x0, x1, neck) = (28, 222, Int(cy + 1.05 * spacing))
            case "peek": (x0, x1, neck) = (0, front!.x0, Int(cy + 40))
            case "laptop": (x0, x1, neck) = (44, 214, front!.y0 + 2)
            case "confused": (x0, x1, neck) = (20, 190, Int(cy + 1.25 * spacing))
            case "sign": (x0, x1, neck) = (40, 256, Int(cy + 1.05 * spacing))
            default:
                let halfWidth = max(2.1 * spacing, 88)
                (x0, x1, neck) = (Int(cx - halfWidth), Int(cx + halfWidth), Int(cy + 1.05 * spacing))
            }
            x0 = max(0, x0)
            x1 = min(n, x1)

            // The head reaches 8 px below the neck and the body up to 30 px
            // above it (14 for the laptop), so tilting opens no gap.
            var headImage = RGBAImage(width: n, height: n)
            headImage.paste(base.cropped(x0: x0, y0: top, x1: x1, y1: neck + 8), x: x0, y: top)
            body = base
            for x in x0..<x1 {
                for y in top..<max(top, neck - (id == "laptop" ? 14 : 30)) { body[x, y] = .clear }
            }
            if id == "laptop" {
                // The tail's tip beside the laptop belongs to the body.
                for x in x0..<min(x1, 64) {
                    for y in max(top, 152)..<min(n, neck + 9) {
                        if headImage.alpha(x, y) > 0 { body[x, y] = headImage[x, y] }
                        headImage[x, y] = .clear
                    }
                }
                // Keep only interior fur under the head as backing, so no ghost edges.
                for x in 64..<x1 {
                    for y in (neck - 14)..<neck where body.alpha(x, y) > 0 {
                        var nearEdge = false
                        for dx in -4...4 {
                            for dy in -4...0
                            where base.alpha(min(n - 1, max(0, x + dx)), min(n - 1, max(0, y + dy))) < 40 {
                                nearEdge = true
                            }
                        }
                        if nearEdge { body[x, y] = .clear }
                    }
                }
            }
            head = headImage
            eyesClosed = closedEyes(headImage, eyeBoxes)
            pivot = RaccoonPoint(x: Double(Int(cx)), y: Double(neck))
        }

        var layers: [RaccoonLayer: RGBAImage] = [:]
        if id == "walk" {
            var legs = RaccoonLayer.legs.map { _ in RGBAImage(width: n, height: n) }
            for x in 0..<n {
                for y in legTop..<n where body.alpha(x, y) > 0 {
                    let k = legSplitX.firstIndex { x < $0 } ?? 3
                    legs[k][x, y] = body[x, y]
                    if y > legOverlapEnd { body[x, y] = .clear }
                }
            }
            for (layer, image) in zip(RaccoonLayer.legs, legs) { layers[layer] = image }
        }
        layers[.body] = body
        layers[.head] = head
        layers[.eyesClosed] = eyesClosed
        layers[.still] = still
        layers[.effects] = effects
        layers[.shadow] = shadow
        return RiggedPose(layers: layers.filter { !$0.value.isEmpty }, headPivot: pivot)
    }

    // MARK: - Closed eyes

    static let closedEyeInk = Pixel(28, 20, 24, 255)

    /// Paints each eye box with the median of the surrounding mid-tone fur and
    /// draws a 3 px closed-eye curve across it.
    static func closedEyes(_ image: RGBAImage, _ boxes: [Box]) -> RGBAImage {
        var out = image
        for (x0, y0, x1, y1) in boxes {
            var ring: [Pixel] = []
            for x in (x0 - 4)...(x1 + 4) {
                for y in (y0 - 4)...(y1 + 4) {
                    if x0 - 1 <= x && x <= x1 + 1 && y0 - 1 <= y && y <= y1 + 1 { continue }
                    let p = out[x, y]
                    if p.a > 200 && p.sum > 120 && p.sum < 345 { ring.append(p) }
                }
            }
            let fur = ring.isEmpty
                ? Pixel(70, 56, 60, 255)
                : Pixel(median(ring.map(\.r)), median(ring.map(\.g)), median(ring.map(\.b)), 255)
            for x in (x0 - 1)...(x1 + 1) {
                for y in (y0 - 1)...(y1 + 1) where out.alpha(x, y) > 200 { out[x, y] = fur }
            }
            let cy = (y0 + y1) / 2 + 2, w = Double(x1 - x0)
            let points = [(x0, cy - 2), (Int(Double(x0) + w * 0.25), cy + 1), (Int(Double(x1) - w * 0.25), cy + 1), (x1, cy - 2)]
            for i in 0..<(points.count - 1) {
                drawWideLine(&out, from: points[i], to: points[i + 1], ink: closedEyeInk)
            }
        }
        return out
    }

    /// Median of the values, averaging the middle two and truncating.
    static func median(_ values: [UInt8]) -> UInt8 {
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : UInt8((Int(sorted[mid - 1]) + Int(sorted[mid])) / 2)
    }

    /// A 3 px wide line drawn as a filled quadrilateral, the way Pillow
    /// draws wide lines, so the closed eyes match the reviewed prototype.
    static func drawWideLine(_ image: inout RGBAImage, from a: (Int, Int), to b: (Int, Int), ink: Pixel) {
        let (x0, y0) = a, (x1, y1) = b
        let dx = x1 - x0, dy = y1 - y0
        if dx == 0 && dy == 0 {
            if image.contains(x0, y0) { image[x0, y0] = ink }
            return
        }
        func roundUp(_ f: Double) -> Int { Int(f >= 0 ? (f + 0.5).rounded(.down) : -(abs(f) + 0.5).rounded(.down)) }
        func roundDown(_ f: Double) -> Int { Int(f >= 0 ? (f - 0.5).rounded(.up) : -(abs(f) - 0.5).rounded(.up)) }
        let length = (Double(dx * dx + dy * dy)).squareRoot()
        let half = 1.0  // (width - 1) / 2 for width 3
        let ratioMax = Double(roundUp(half)) / length, ratioMin = Double(roundDown(half)) / length
        let dxMin = roundDown(ratioMin * Double(dy)), dxMax = roundDown(ratioMax * Double(dy))
        let dyMin = roundDown(ratioMin * Double(dx)), dyMax = roundDown(ratioMax * Double(dx))
        let vertices = [(x0 - dxMin, y0 + dyMax), (x1 - dxMin, y1 + dyMax), (x1 + dxMax, y1 - dyMin), (x0 + dxMax, y0 - dyMin)]
        fillPolygon(&image, vertices, ink: ink)
    }

    /// Scanline polygon fill with Pillow's edge rules.
    static func fillPolygon(_ image: inout RGBAImage, _ vertices: [(Int, Int)], ink: Pixel) {
        struct Edge { var x0, y0, yMin, yMax: Int; var dx: Double }
        var edges: [Edge] = []
        for i in vertices.indices {
            let (ax, ay) = vertices[i], (bx, by) = vertices[(i + 1) % vertices.count]
            if ay == by { continue }
            edges.append(Edge(x0: ax, y0: ay, yMin: min(ay, by), yMax: max(ay, by), dx: Double(bx - ax) / Double(by - ay)))
        }
        guard !edges.isEmpty else { return }
        let yStart = max(edges.map(\.yMin).min()!, 0), yEnd = min(edges.map(\.yMax).max()!, image.height - 1)
        guard yStart <= yEnd else { return }
        func roundUp(_ f: Double) -> Int { Int(f >= 0 ? (f + 0.5).rounded(.down) : -(abs(f) + 0.5).rounded(.down)) }
        func roundDown(_ f: Double) -> Int { Int(f >= 0 ? (f - 0.5).rounded(.up) : -(abs(f) - 0.5).rounded(.up)) }
        for y in yStart...yEnd {
            var xs: [Double] = []
            for e in edges {
                if y >= e.yMin && y <= e.yMax { xs.append(Double(y - e.y0) * e.dx + Double(e.x0)) }
                if y == e.yMax && y < yEnd, let last = xs.last { xs.append(last) }
            }
            xs.sort()
            var i = 1
            while i < xs.count {
                let from = max(roundUp(xs[i - 1]), 0), to = min(roundDown(xs[i]), image.width - 1)
                if from <= to { for x in from...to { image[x, y] = ink } }
                i += 2
            }
        }
    }

    // MARK: - Regions

    /// Pieces of 8-connected pixels with alpha above 40.
    public static func components(of image: RGBAImage) -> [[(x: Int, y: Int)]] {
        var seen = PixelMask(width: image.width, height: image.height)
        var result: [[(x: Int, y: Int)]] = []
        for y in 0..<image.height {
            for x in 0..<image.width where !seen[x, y] && image.alpha(x, y) > 40 {
                var stack = [(x, y)], points: [(x: Int, y: Int)] = []
                seen[x, y] = true
                while let (cx, cy) = stack.popLast() {
                    points.append((cx, cy))
                    for dx in -1...1 {
                        for dy in -1...1 {
                            let nx = cx + dx, ny = cy + dy
                            if image.contains(nx, ny) && !seen[nx, ny] && image.alpha(nx, ny) > 40 {
                                seen[nx, ny] = true
                                stack.append((nx, ny))
                            }
                        }
                    }
                }
                result.append(points)
            }
        }
        return result
    }

    /// A flat-colored region: flood fill from `seed` through opaque pixels
    /// that pass `matches`, then fill its interior, add its dark outline
    /// (3 px) and close small gaps inside its bounds (2 px).
    static func regionMask(_ image: RGBAImage, seed: (Int, Int), matches: (Pixel) -> Bool) -> PixelMask {
        let n = image.width
        var seen = PixelMask(width: n, height: image.height)
        seen[seed.0, seed.1] = true
        var stack = [seed]
        while let (x, y) = stack.popLast() {
            for (nx, ny) in [(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)]
            where image.contains(nx, ny) && !seen[nx, ny] && image.alpha(nx, ny) > 200 && matches(image[nx, ny]) {
                seen[nx, ny] = true
                stack.append((nx, ny))
            }
        }

        var rows: [Int: (Int, Int)] = [:], columns: [Int: (Int, Int)] = [:]
        for (x, y) in seen.points {
            let r = rows[y] ?? (x, x), c = columns[x] ?? (y, y)
            rows[y] = (min(r.0, x), max(r.1, x))
            columns[x] = (min(c.0, y), max(c.1, y))
        }
        var mask = seen
        for (y, r) in rows {
            for x in r.0...r.1 {
                if let c = columns[x], c.0 <= y, y <= c.1, image.alpha(x, y) > 0 { mask[x, y] = true }
            }
        }
        for _ in 0..<3 {
            var add = PixelMask(width: n, height: image.height)
            for (x, y) in mask.points {
                for (nx, ny) in [(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)]
                where image.contains(nx, ny) && !mask[nx, ny] && image.alpha(nx, ny) > 40 && image[nx, ny].sum < 285 {
                    add[nx, ny] = true
                }
            }
            mask.formUnion(add)
        }
        let b = mask.bounds!
        for _ in 0..<2 {
            var add = PixelMask(width: n, height: image.height)
            for (x, y) in mask.points {
                for (nx, ny) in [(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)]
                where b.x0 <= nx && nx <= b.x1 && b.y0 <= ny && ny <= b.y1 && !mask[nx, ny] && image.alpha(nx, ny) > 0 {
                    add[nx, ny] = true
                }
            }
            mask.formUnion(add)
        }
        return mask
    }
}

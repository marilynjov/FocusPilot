import Foundation
import Testing
import FocusPilotCore
import RaccoonRig

/// The committed raccoon art (Packaging/Raccoon) against its source sheet
/// (Artwork/Raccoon). Decision 0004, 2026-11-02.
@Suite("Raccoon art", .serialized)
struct RaccoonArtTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let artwork = root.appending(path: "Artwork/Raccoon")
    static let packaged = root.appending(path: "Packaging/Raccoon")

    static let manifest: RaccoonArtManifest = {
        let data = try! Data(contentsOf: packaged.appending(path: RaccoonArtManifest.fileName))
        return try! JSONDecoder().decode(RaccoonArtManifest.self, from: data)
    }()

    static let sourcePoses: [String: RGBAImage] = RaccoonSheet.slice(try! PNGCoding.read(artwork.appending(path: "raccoon-sheet.png")))

    static func layers(_ pose: RaccoonPoseArt) throws -> [RaccoonLayer: RGBAImage] {
        let strip = try PNGCoding.read(packaged.appending(path: pose.image))
        #expect(strip.width == manifest.frameSize * pose.layers.count && strip.height == manifest.frameSize)
        return RaccoonComposer.layers(of: strip, pose: pose, frameSize: manifest.frameSize)
    }

    @Test func everySheetPoseIsPackagedWithItsName() {
        let manifest = Self.manifest
        #expect(manifest.frameSize == 256)
        #expect(manifest.poses.map(\.id) == RaccoonSheet.poseIDs)
        #expect(manifest.pose("sit")?.name == "Idle")
        #expect(manifest.pose("laptop")?.name == "Working")
        #expect(manifest.pose("ledge")?.name == "Waiting")
        #expect(manifest.pose("sign")?.name == "Encouraging")
        #expect(Set(manifest.poses.map(\.name)).count == 20)
    }

    @Test func layersMatchWhatEachPoseNeeds() throws {
        for pose in Self.manifest.poses {
            let layers = try Self.layers(pose)
            #expect(pose.layers == RaccoonLayer.allCases.filter { pose.layers.contains($0) }, "\(pose.id) layers out of order")
            for (layer, image) in layers {
                #expect(!image.isEmpty, "\(pose.id) has an empty \(layer) layer")
            }
            #expect(pose.layers.contains(.body) || pose.layers.contains(.head), "\(pose.id) has no raccoon")
            #expect((pose.headPivot != nil) == pose.layers.contains(.head), "\(pose.id) head pivot")
            let legs = pose.layers.filter { RaccoonLayer.legs.contains($0) }
            #expect(legs == (pose.id == "walk" ? RaccoonLayer.legs : []), "\(pose.id) legs")
        }
        let withStill = Self.manifest.poses.filter { $0.layers.contains(.still) }.map(\.id)
        #expect(Set(withStill) == ["laptop", "sign", "peek", "ledge"])
    }

    @Test func motionsReferToKnownMotionsAndExistingLayers() {
        let manifest = Self.manifest
        for pose in manifest.poses {
            let m = pose.motion
            for use in [m.head, m.body, m.move, m.hop, m.shadow, m.effects, m.blink].compactMap({ $0 }) + (m.legs ?? []) {
                #expect(manifest.motions[use.motion] != nil, "\(pose.id) uses unknown \(use.motion)")
                #expect(use.duration > 0)
            }
            if m.blink != nil { #expect(pose.layers.contains(.eyesClosed), "\(pose.id) blinks without closed eyes") }
            if m.effects != nil { #expect(pose.layers.contains(.effects), "\(pose.id) moves missing effects") }
            // Only the walk moves the shadow sideways.
            if let shadow = m.shadow, manifest.motions[shadow.motion]!.keyframes.contains(where: { ($0.translateX ?? 0) != 0 }) {
                #expect(pose.id == "walk")
            }
        }
        for (name, motion) in manifest.motions {
            let times = motion.keyframes.flatMap(\.at)
            #expect(times.contains(0) && times.contains(1), "\(name) does not cover a full cycle")
            #expect(times.allSatisfy { (0...1).contains($0) })
        }
    }

    /// Composing every layer at rest gives back the source pose, except for
    /// specks (pieces under 8 px) the generator removes.
    @Test func layersAtRestRecomposeTheSourcePose() throws {
        for pose in Self.manifest.poses {
            let source = try #require(Self.sourcePoses[pose.id])
            let composed = RaccoonComposer.atRest(try Self.layers(pose), frameSize: Self.manifest.frameSize)
            let specks = specks(in: source)
            var removed = 0
            var wrong: [(Int, Int)] = []
            for y in 0..<source.height {
                for x in 0..<source.width where composed[x, y] != source[x, y] {
                    if composed.alpha(x, y) == 0 && specks.contains(y * source.width + x) {
                        removed += 1
                    } else {
                        wrong.append((x, y))
                    }
                }
            }
            #expect(wrong.isEmpty, "\(pose.id): \(wrong.count) pixels differ from the sheet, first at \(wrong.first.map { "\($0)" } ?? "")")
            #expect(removed <= 40, "\(pose.id): \(removed) speck pixels removed")
        }
    }

    /// Still objects and the floor shadow never end up in a layer that moves.
    /// The only overlap allowed is the fur that fills, at most 3 px deep, the
    /// hole a still object leaves behind it.
    @Test func stillObjectsAndShadowAreNotInMovingLayers() throws {
        for pose in Self.manifest.poses {
            let layers = try Self.layers(pose)
            let size = Self.manifest.frameSize
            let moving = layers.filter { $0.key.movesWithRaccoon }.map(\.value)
            func movingPixel(_ x: Int, _ y: Int) -> Bool { moving.contains { $0.alpha(x, y) > 0 } }

            if let shadow = layers[.shadow] {
                for y in 0..<size {
                    for x in 0..<size where shadow.alpha(x, y) > 0 {
                        #expect(!movingPixel(x, y), "\(pose.id): shadow pixel at \(x),\(y) is also in a moving layer")
                    }
                }
            }
            if let still = layers[.still] {
                let fillDepth = pose.id == "laptop" || pose.id == "peek" ? 0 : 3
                let depth = insideDepth(of: still, limit: fillDepth + 1)
                for y in 0..<size {
                    for x in 0..<size where still.alpha(x, y) > 0 && movingPixel(x, y) {
                        #expect(depth[y * size + x] <= fillDepth,
                                "\(pose.id): still object at \(x),\(y) is under a moving layer \(depth[y * size + x]) px from its edge")
                    }
                }
            }
        }
    }

    /// The generator, run on the committed sheet, reproduces the committed
    /// output, and running it twice gives byte-identical files.
    @Test func generatorReproducesTheCommittedArt() throws {
        let first = try RaccoonArtBuilder.build(artworkDirectory: Self.artwork)
        let second = try RaccoonArtBuilder.build(artworkDirectory: Self.artwork)
        #expect(first.strips == second.strips)
        #expect(first.manifestData == second.manifestData)
        #expect(first.manifestData == (try Data(contentsOf: Self.packaged.appending(path: RaccoonArtManifest.fileName))))

        #expect(first.manifest == Self.manifest, "raccoon.json is out of date; run scripts/build-raccoon-art.sh")
        for (name, data) in first.strips {
            let committed = try PNGCoding.read(Self.packaged.appending(path: name))
            #expect(try PNGCoding.decode(data) == committed, "\(name) is out of date; run scripts/build-raccoon-art.sh")
        }
    }

    @Test func pngRoundTripKeepsChannelsExactly() throws {
        var image = RGBAImage(width: 3, height: 1)
        image[0, 0] = Pixel(12, 200, 7, 255)
        image[1, 0] = Pixel(255, 1, 128, 90)
        #expect(try PNGCoding.decode(PNGCoding.encode(image)) == image)
    }

    // MARK: - Helpers

    /// Pixel indices of the source's 8-connected pieces under 8 pixels.
    private func specks(in image: RGBAImage) -> Set<Int> {
        Set(PoseRigger.components(of: image).filter { $0.count < 8 }.flatMap { $0.map { $0.y * image.width + $0.x } })
    }

    /// For each opaque pixel, its 4-connected step distance to the nearest
    /// transparent pixel or the frame edge, capped at `limit`.
    private func insideDepth(of image: RGBAImage, limit: Int) -> [Int] {
        let w = image.width, h = image.height
        var depth = [Int](repeating: 0, count: w * h)
        var frontier: [Int] = []
        for y in 0..<h {
            for x in 0..<w where image.alpha(x, y) > 0 {
                depth[y * w + x] = limit
                let edge = [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)].contains { !image.contains($0.0, $0.1) || image.alpha($0.0, $0.1) == 0 }
                if edge {
                    depth[y * w + x] = 1
                    frontier.append(y * w + x)
                }
            }
        }
        var step = 1
        while !frontier.isEmpty && step < limit {
            step += 1
            var next: [Int] = []
            for i in frontier {
                let x = i % w, y = i / w
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where image.contains(nx, ny) {
                    let j = ny * w + nx
                    if depth[j] > step { depth[j] = step; next.append(j) }
                }
            }
            frontier = next
        }
        return depth
    }
}

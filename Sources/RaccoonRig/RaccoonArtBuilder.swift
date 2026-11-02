import Foundation
import FocusPilotCore

/// Builds the bundled raccoon art from `Artwork/Raccoon`: the pose sheet
/// (`raccoon-sheet.png`) and the hand-written pose descriptions
/// (`poses.json`: names, captions, leg pivots and motion from the
/// owner-approved mockup). Output: one strip per pose plus `raccoon.json`.
///
/// The output depends only on the inputs: the same sheet gives byte-identical
/// strips.
public enum RaccoonArtBuilder {
    public static let sheetFileName = "raccoon-sheet.png"
    public static let posesFileName = "poses.json"

    /// `poses.json`: everything about a pose that is not cut from the sheet.
    public struct PoseDescriptions: Codable, Sendable {
        public struct Pose: Codable, Sendable {
            public var id: String
            public var name: String
            public var caption: String
            public var legPivots: [RaccoonPoint]?
            public var motion: RaccoonPoseMotion
        }

        public var poses: [Pose]
        public var motions: [String: RaccoonMotion]
    }

    public enum BuildError: Error, CustomStringConvertible {
        case invalidDescriptions(String)

        public var description: String {
            switch self {
            case .invalidDescriptions(let reason): "\(posesFileName): \(reason)"
            }
        }
    }

    public struct Output {
        public var manifest: RaccoonArtManifest
        /// PNG data by file name.
        public var strips: [String: Data]
        public var manifestData: Data
    }

    public static func build(artworkDirectory: URL) throws -> Output {
        let sheet = try PNGCoding.read(artworkDirectory.appending(path: sheetFileName))
        let descriptions = try JSONDecoder().decode(
            PoseDescriptions.self, from: Data(contentsOf: artworkDirectory.appending(path: posesFileName)))
        return try build(sheet: sheet, descriptions: descriptions)
    }

    public static func build(sheet: RGBAImage, descriptions: PoseDescriptions) throws -> Output {
        let ids = descriptions.poses.map(\.id)
        guard ids == RaccoonSheet.poseIDs else {
            throw BuildError.invalidDescriptions("poses must be \(RaccoonSheet.poseIDs) in sheet order, found \(ids)")
        }
        let poses = RaccoonSheet.slice(sheet)
        var strips: [String: Data] = [:]
        var art: [RaccoonPoseArt] = []
        for description in descriptions.poses {
            let rigged = PoseRigger.rig(poses[description.id]!, id: description.id)
            let order = rigged.layerOrder
            let image = "\(description.id).png"
            strips[image] = try PNGCoding.encode(.strip(order.map { rigged.layers[$0]! }))
            art.append(RaccoonPoseArt(
                id: description.id, name: description.name, caption: description.caption, image: image,
                layers: order, headPivot: rigged.headPivot, legPivots: description.legPivots, motion: description.motion))
            try validate(art.last!, motions: descriptions.motions)
        }
        let manifest = RaccoonArtManifest(frameSize: RaccoonSheet.frameSize, poses: art, motions: descriptions.motions)
        return Output(manifest: manifest, strips: strips, manifestData: try encode(manifest))
    }

    /// Writes the strips and `raccoon.json` into `directory`, replacing older files.
    public static func write(_ output: Output, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, data) in output.strips {
            try data.write(to: directory.appending(path: name))
        }
        try output.manifestData.write(to: directory.appending(path: RaccoonArtManifest.fileName))
    }

    public static func encode(_ manifest: RaccoonArtManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(manifest) + Data("\n".utf8)
    }

    static func validate(_ pose: RaccoonPoseArt, motions: [String: RaccoonMotion]) throws {
        let m = pose.motion
        let uses = [m.head, m.body, m.move, m.hop, m.shadow, m.effects, m.blink].compactMap { $0 } + (m.legs ?? [])
        for use in uses where motions[use.motion] == nil {
            throw BuildError.invalidDescriptions("\(pose.id) uses unknown motion \(use.motion)")
        }
        if m.head != nil && pose.headPivot == nil {
            throw BuildError.invalidDescriptions("\(pose.id) tilts its head but has no head layer")
        }
        if m.blink != nil && !pose.layers.contains(.eyesClosed) {
            throw BuildError.invalidDescriptions("\(pose.id) blinks but has no closed-eyes layer")
        }
        if m.effects != nil && !pose.layers.contains(.effects) {
            throw BuildError.invalidDescriptions("\(pose.id) moves effects it does not have")
        }
        let legCount = pose.layers.filter { RaccoonLayer.legs.contains($0) }.count
        if (m.legs?.count ?? 0) != legCount || (pose.legPivots?.count ?? 0) != legCount {
            throw BuildError.invalidDescriptions("\(pose.id) needs one leg motion and pivot per leg layer")
        }
    }
}

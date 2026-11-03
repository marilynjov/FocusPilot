import CoreGraphics
import Foundation
import Testing
import FocusPilotCore
import RaccoonRig

/// The run-time side of the raccoon art (D11): loading the bundled folder,
/// cutting strips into layers, motion tracks and which pose shows.
@Suite("Raccoon companion")
struct RaccoonCompanionTests {
    static let packaged = RaccoonArtTests.packaged

    /// Alpha of every pixel, which premultiplication leaves unchanged.
    static func alpha(of image: CGImage) -> [UInt8] {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return stride(from: 3, to: bytes.count, by: 4).map { bytes[$0] }
    }

    @Test func loadsTheCommittedArtAndCutsEveryPoseLikeTheGenerator() throws {
        let art = try RaccoonArt.load(from: Self.packaged)
        #expect(art.manifest == RaccoonArtTests.manifest)
        for pose in art.manifest.poses {
            let layers = try art.layers(of: pose.id)
            #expect(Set(layers.keys) == Set(pose.layers), "\(pose.id)")
            let strip = try PNGCoding.read(Self.packaged.appending(path: pose.image))
            let expected = RaccoonComposer.layers(of: strip, pose: pose, frameSize: art.manifest.frameSize)
            for (layer, image) in layers {
                #expect(image.width == 256 && image.height == 256)
                let reference = try #require(expected[layer])
                let referenceAlpha = stride(from: 3, to: reference.bytes.count, by: 4).map { reference.bytes[$0] }
                #expect(Self.alpha(of: image) == referenceAlpha, "\(pose.id) \(layer) differs from the generator's cut")
            }
        }
    }

    @Test func bundledArtComesFromResourcesRaccoon() throws {
        let app = FileManager.default.temporaryDirectory.appending(path: "RaccoonBundle-\(UUID().uuidString).app")
        let resources = app.appending(path: "Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: app) }
        try FileManager.default.copyItem(at: Self.packaged, to: resources.appending(path: RaccoonArt.bundleFolder))

        let bundle = try #require(Bundle(url: app))
        let art = try RaccoonArt.bundled(in: bundle)
        #expect(art.manifest.pose("laptop")?.name == "Working")
        #expect(try art.layers(of: "sit").count == 4)
    }

    @Test func missingOrBrokenArtIsReported() throws {
        let empty = FileManager.default.temporaryDirectory.appending(path: "RaccoonEmpty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        #expect(throws: RaccoonArtError.self) { try RaccoonArt.load(from: empty) }

        try Data("{}".utf8).write(to: empty.appending(path: RaccoonArtManifest.fileName))
        #expect(throws: RaccoonArtError.self) { try RaccoonArt.load(from: empty) }

        let art = try RaccoonArt.load(from: Self.packaged)
        #expect(throws: RaccoonArtError.unknownPose("dance")) { try art.layers(of: "dance") }
    }

    @Test func aStripOfTheWrongSizeIsRefused() throws {
        let context = CGContext(data: nil, width: 300, height: 256, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let strip = try #require(context.makeImage())
        #expect(throws: RaccoonArtError.wrongStripSize("strip")) {
            try RaccoonArt.slice(strip, layers: [.shadow, .body], frameSize: 256)
        }
    }

    // MARK: Motion tracks

    @Test func blinkHoldsClosedEyesBrieflyEachCycle() throws {
        let blink = try #require(RaccoonArtTests.manifest.motions["blink"])
        #expect(blink.tracks == [RaccoonMotionTrack(property: .opacity, keyTimes: [0, 0.93, 0.96, 1], values: [0, 1, 0, 0])])
    }

    @Test func propertiesInterpolateOnlyBetweenKeyframesThatSetThem() throws {
        // steam sets opacity at 0, 0.5 and 1 but translateY only at 0 and 1.
        let steam = try #require(RaccoonArtTests.manifest.motions["steam"])
        let tracks = Dictionary(uniqueKeysWithValues: steam.tracks.map { ($0.property, $0) })
        #expect(tracks[.translateY] == RaccoonMotionTrack(property: .translateY, keyTimes: [0, 1], values: [2.9, -8.7]))
        #expect(tracks[.opacity]?.keyTimes == [0, 0.5, 1])
        #expect(tracks.count == 2)
    }

    @Test func aPropertyMissingAtTheEndsRestsThere() {
        let motion = RaccoonMotion(timing: .linear, keyframes: [RaccoonKeyframe(at: [0.5], rotate: 10)])
        #expect(motion.tracks == [RaccoonMotionTrack(property: .rotate, keyTimes: [0, 0.5, 1], values: [0, 10, 0])])
    }

    @Test func everyCommittedMotionGivesWellFormedTracks() {
        for (name, motion) in RaccoonArtTests.manifest.motions {
            #expect(!motion.tracks.isEmpty, "\(name)")
            for track in motion.tracks {
                #expect(track.keyTimes.first == 0 && track.keyTimes.last == 1, "\(name)")
                #expect(zip(track.keyTimes, track.keyTimes.dropFirst()).allSatisfy { $0 < $1 }, "\(name)")
                #expect(track.keyTimes.count == track.values.count)
            }
        }
    }

    // MARK: Presence

    @Test func onScreenShowsTheTaskOnlyWhileOneIsUnderWayAndTheWindowIsClosed() {
        #expect(RaccoonPresence.resolve(mode: .staysOnScreen, activity: .working, isWindowOpen: false, peek: nil)
            == RaccoonPresence(poseID: "laptop"))
        #expect(RaccoonPresence.resolve(mode: .staysOnScreen, activity: nil, isWindowOpen: false, peek: nil) == nil)
        // With the window open the raccoon is in the window instead.
        #expect(RaccoonPresence.resolve(mode: .staysOnScreen, activity: .working, isWindowOpen: true, peek: nil) == nil)
        #expect(RaccoonArtTests.manifest.pose(RaccoonPresence.workingPose)?.name == "Working")
    }

    @Test func pausedSitsABreakHasCoffeeAndLunchIsANap() {
        #expect(RaccoonActivity(.running) == .working)
        #expect(RaccoonActivity(.paused(since: .now)) == .paused)
        #expect(RaccoonActivity(.onBreak(until: .now)) == .onBreak)
        #expect(RaccoonActivity(.onBreak(until: .now), isLunch: true) == .onLunch)
        #expect(RaccoonActivity(.running, isLunch: true) == .working)
        #expect(RaccoonActivity.onLunch.poseID == "sleep")
        #expect(RaccoonActivity(.ended(at: .now, reason: .completed)) == nil)
        #expect(RaccoonActivity(nil) == nil)
        for activity in [RaccoonActivity.working, .paused, .onBreak, .onLunch] {
            #expect(RaccoonArtTests.manifest.pose(activity.poseID) != nil, "\(activity)")
        }
        #expect(RaccoonPresence.inWindow(mode: .staysOnScreen, activity: .paused) == RaccoonPresence(poseID: "sit"))
    }

    @Test func theWindowShowsTheTaskOnlyInOnScreenModeAndNeverDuringAPeek() {
        #expect(RaccoonPresence.inWindow(mode: .staysOnScreen, activity: .working) == RaccoonPresence(poseID: "laptop"))
        #expect(RaccoonPresence.inWindow(mode: .peeksForReminders, activity: .working) == nil)
        // A peek shows in the floating window only, never in both.
        let peek = RaccoonPeek(poseID: "peek")
        #expect(RaccoonPresence.inWindow(mode: .staysOnScreen, activity: .working, peek: peek) == nil)
        #expect(RaccoonPresence.resolve(mode: .staysOnScreen, activity: .working, isWindowOpen: true, peek: peek)?.poseID == "peek")
        #expect(RaccoonPresence.inWindow(mode: .staysOnScreen, activity: nil) == nil)
        #expect(RaccoonPresence.inWindow(mode: .off, activity: .working) == nil)
    }

    @Test func peeksShowOnlyWhenAReminderAsks() {
        let peek = RaccoonPeek(poseID: "peek", message: "10 minutes left")
        #expect(RaccoonPresence.resolve(mode: .peeksForReminders, activity: .working, isWindowOpen: false, peek: nil) == nil)
        #expect(RaccoonPresence.resolve(mode: .peeksForReminders, activity: nil, isWindowOpen: false, peek: peek)
            == RaccoonPresence(poseID: "peek", message: "10 minutes left"))
        #expect(RaccoonPresence.resolve(mode: .staysOnScreen, activity: .working, isWindowOpen: true, peek: peek)?.poseID == "peek")
    }

    @Test func offShowsNothing() {
        #expect(RaccoonPresence.resolve(mode: .off, activity: .working, isWindowOpen: false, peek: RaccoonPeek(poseID: "peek")) == nil)
    }
}

@MainActor
@Suite("Raccoon companion mode")
struct RaccoonModePreferenceTests {
    private let defaults = UserDefaults(suiteName: "FocusPilotTests-\(UUID().uuidString)")!

    @Test func newInstallsStartOffAndTheChoiceIsRemembered() {
        let preferences = DisplayPreferences(defaults: defaults)
        #expect(preferences.raccoonMode == .off)
        var reported: [RaccoonCompanionMode] = []
        preferences.raccoonModeDidChange = { reported.append($0) }

        preferences.raccoonMode = .staysOnScreen

        #expect(reported == [.staysOnScreen])
        #expect(DisplayPreferences(defaults: defaults).raccoonMode == .staysOnScreen)
    }

    @Test func theScreenChoiceIsRememberedAndStartsOnTheMainDisplay() {
        let preferences = DisplayPreferences(defaults: defaults)
        #expect(preferences.raccoonScreen == nil)
        var changes = 0
        preferences.raccoonScreenDidChange = { changes += 1 }

        preferences.raccoonScreen = "37D8832A-2D66-02CA-B9F7-8F30A301B230"

        #expect(changes == 1)
        #expect(DisplayPreferences(defaults: defaults).raccoonScreen == "37D8832A-2D66-02CA-B9F7-8F30A301B230")
        preferences.raccoonScreen = nil
        #expect(DisplayPreferences(defaults: defaults).raccoonScreen == nil)
    }
}

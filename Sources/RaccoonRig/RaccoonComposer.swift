import Foundation
import FocusPilotCore

public enum RaccoonComposer {
    /// The pose's layers by name, cut from its strip.
    public static func layers(of strip: RGBAImage, pose: RaccoonPoseArt, frameSize: Int) -> [RaccoonLayer: RGBAImage] {
        Dictionary(uniqueKeysWithValues: zip(pose.layers, strip.frames(of: frameSize)))
    }

    /// The pose at rest: every layer in drawing order, eyes open.
    public static func atRest(_ layers: [RaccoonLayer: RGBAImage], frameSize: Int) -> RGBAImage {
        var out = RGBAImage(width: frameSize, height: frameSize)
        for layer in RaccoonLayer.allCases where layer != .eyesClosed {
            if let image = layers[layer] { out.composite(image) }
        }
        return out
    }
}

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum PNGCodingError: Error, CustomStringConvertible {
    case unreadable(String)
    case unwritable(String)

    public var description: String {
        switch self {
        case .unreadable(let what): "cannot read PNG: \(what)"
        case .unwritable(let what): "cannot write PNG: \(what)"
        }
    }
}

/// Reads and writes `RGBAImage` as PNG with ImageIO, keeping the stored
/// channel values exactly (no color matching, no premultiplication).
public enum PNGCoding {
    public static func read(_ url: URL) throws -> RGBAImage {
        guard let data = try? Data(contentsOf: url) else { throw PNGCodingError.unreadable(url.path) }
        return try decode(data, name: url.lastPathComponent)
    }

    public static func decode(_ data: Data, name: String = "data") throws -> RGBAImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw PNGCodingError.unreadable(name) }

        let alpha = image.alphaInfo
        let byteOrder = image.bitmapInfo.intersection(.byteOrderMask)
        guard image.bitsPerComponent == 8, image.bitsPerPixel == 32,
              alpha == .last || alpha == .noneSkipLast,
              byteOrder == [] || byteOrder == .byteOrder32Big,
              let pixelData = image.dataProvider?.data, let base = CFDataGetBytePtr(pixelData)
        else { throw PNGCodingError.unreadable("\(name) is not 8-bit RGBA") }

        let width = image.width, height = image.height, rowBytes = image.bytesPerRow
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let s = y * rowBytes + x * 4, d = (y * width + x) * 4
                bytes[d] = base[s]
                bytes[d + 1] = base[s + 1]
                bytes[d + 2] = base[s + 2]
                bytes[d + 3] = alpha == .last ? base[s + 3] : 255
            }
        }
        return RGBAImage(width: width, height: height, bytes: bytes)
    }

    public static func encode(_ image: RGBAImage) throws -> Data {
        let provider = CGDataProvider(data: Data(image.bytes) as CFData)!
        guard let cgImage = CGImage(
            width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ) else { throw PNGCodingError.unwritable("cannot make an image") }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil)
        else { throw PNGCodingError.unwritable("no PNG encoder") }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { throw PNGCodingError.unwritable("encoding failed") }
        return data as Data
    }

    public static func write(_ image: RGBAImage, to url: URL) throws {
        try encode(image).write(to: url)
    }
}

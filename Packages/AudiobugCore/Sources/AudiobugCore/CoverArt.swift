import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Where a book's cover picture comes from: the art embedded in the file (iTunes `covr` atom, ID3 APIC) or an
/// image file beside the book with the same name ("Emma.jpg" next to "Emma.m4b").
public enum CoverArt {
    public static let sidecarExtensions = ["jpg", "jpeg", "png", "heic", "webp"]

    /// The embedded cover, read without touching the chapter list (cheap enough for a library scan).
    public static func embedded(in url: URL) async -> Data? {
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.commonMetadata) else { return nil }
        for item in items where item.commonKey == .commonKeyArtwork {
            if let data = try? await item.load(.dataValue), !data.isEmpty { return data }
        }
        return nil
    }

    /// An image next to the book with the same name, if there is one.
    public static func sidecar(for url: URL) -> URL? {
        let base = url.deletingPathExtension()
        for ext in sidecarExtensions {
            let candidate = base.appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// Re-encodes a picture as a JPEG whose longer side is at most `maxPixels` (ImageIO, so it works on the Watch).
    /// Returns nil when the data isn't an image.
    public static func thumbnail(_ data: Data, maxPixels: Int, quality: Double = 0.85) -> Data? {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }

    /// Pixel size of an encoded image, without decoding it.
    public static func pixelSize(of data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return CGSize(width: w, height: h)
    }
}

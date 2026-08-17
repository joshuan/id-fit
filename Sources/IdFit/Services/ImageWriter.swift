import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Writes cropped images back to disk in the source's own format.
enum ImageWriter {
    enum WriteError: LocalizedError {
        case unsupportedFormat(String)
        case encodingFailed(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat(let name): "\(name) has a format that cannot be written."
            case .encodingFailed(let name): "\(name) could not be encoded."
            }
        }
    }

    /// High enough that a scan re-encoded once is not visibly worse, low enough
    /// that the file is a fraction of the raw pixels.
    private static let lossyQuality = 0.95

    static func contentType(forExtension ext: String) -> UTType? {
        guard let type = UTType(filenameExtension: ext.lowercased()) else { return nil }
        // Only formats CGImageDestination can actually produce.
        let supported: [UTType] = [.jpeg, .png, .tiff, .heic, .heif]
        return supported.first { type.conforms(to: $0) || type == $0 }
    }

    /// Keeps the source's resolution and colour metadata, and clears the EXIF
    /// orientation because the pixels being written are already upright.
    static func write(
        _ image: CGImage,
        to destination: URL,
        type: UTType,
        inheritingMetadataFrom source: URL?
    ) throws {
        guard let output = CGImageDestinationCreateWithURL(
            destination as CFURL, type.identifier as CFString, 1, nil
        ) else {
            throw WriteError.unsupportedFormat(destination.lastPathComponent)
        }

        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: lossyQuality]
        if let source,
           let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
           let existing = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] {
            for key in [kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight,
                        kCGImagePropertyProfileName, kCGImagePropertyExifDictionary,
                        kCGImagePropertyIPTCDictionary, kCGImagePropertyTIFFDictionary] {
                if let value = existing[key] { properties[key] = value }
            }
            properties[kCGImagePropertyOrientation] = 1
        }

        CGImageDestinationAddImage(output, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(output) else {
            throw WriteError.encodingFailed(destination.lastPathComponent)
        }
    }

    /// The same image with its pixels held as JPEG.
    ///
    /// Drawn into a PDF context, such an image is embedded as the JPEG itself
    /// rather than as the raw bitmap, and that is the difference between a scan
    /// that can be emailed and one that cannot: a single raster A4 page is some
    /// 15 MB of pixels and around a tenth of that as JPEG.
    ///
    /// Nil when the encode fails, leaving the caller its own pixels to fall
    /// back on — a large PDF beats no PDF.
    static func jpegBacked(_ image: CGImage) -> CGImage? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }

        CGImageDestinationAddImage(
            destination, image,
            [kCGImageDestinationLossyCompressionQuality: lossyQuality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination),
              let source = CGImageSourceCreateWithData(data as CFData, nil)
        else { return nil }

        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

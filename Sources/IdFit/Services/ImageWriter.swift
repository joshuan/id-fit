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

        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.95]
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
}

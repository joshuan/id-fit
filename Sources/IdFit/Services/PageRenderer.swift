import CoreGraphics
import Foundation
import ImageIO
import PDFKit

/// Produces the final, export-ready content of a page: the source with its
/// crop and rotation applied, at full resolution. Sources are only ever read.
enum PageRenderer {
    /// PDF sources stay vector — rasterizing a scanner's PDF would lose
    /// quality and bloat the file — so callers get the page itself plus the
    /// crop to apply while drawing.
    enum Content {
        case image(CGImage)
        case pdfPage(CGPDFPage, displayedSize: CGSize, crop: CropRect, rotation: Int)

        /// Size of the exported content in pixels (images) or points (PDF).
        var size: CGSize {
            switch self {
            case .image(let image):
                CGSize(width: image.width, height: image.height)
            case .pdfPage(_, let displayed, let crop, let rotation):
                Self.rotatedSize(
                    CGSize(width: crop.width * displayed.width, height: crop.height * displayed.height),
                    rotation: rotation
                )
            }
        }

        private static func rotatedSize(_ size: CGSize, rotation: Int) -> CGSize {
            let normalized = ((rotation % 360) + 360) % 360
            return normalized % 180 == 0 ? size : CGSize(width: size.height, height: size.width)
        }
    }

    static func content(for page: Page, in folder: URL) -> Content? {
        let url = folder.appendingPathComponent(page.source.file)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        if url.pathExtension.lowercased() == "pdf" {
            guard let document = CGPDFDocument(url as CFURL),
                  let pdfPage = document.page(at: (page.source.pdfPage ?? 0) + 1),
                  let displayed = SourceGeometry.shared.size(for: page.source, in: folder)
            else { return nil }
            return .pdfPage(
                pdfPage,
                displayedSize: displayed,
                crop: page.crop ?? CropRect(x: 0, y: 0, width: 1, height: 1),
                rotation: page.rotation
            )
        }

        guard let image = fullResolutionImage(at: url) else { return nil }
        let cropped = crop(image, to: page.crop)
        return .image(rotate(cropped, by: page.rotation))
    }

    /// Full-size pixels with the EXIF orientation baked in, so crop rects —
    /// which the user drew on an upright preview — line up.
    static func fullResolutionImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func crop(_ image: CGImage, to crop: CropRect?) -> CGImage {
        guard let crop else { return image }
        let size = CGSize(width: image.width, height: image.height)
        let rect = CropGeometry.pixelRect(crop, sourceSize: size).integral
        let clamped = rect.intersection(CGRect(origin: .zero, size: size))
        guard clamped.width >= 1, clamped.height >= 1,
              let cropped = image.cropping(to: clamped) else { return image }
        return cropped
    }

    static func rotate(_ image: CGImage, by degrees: Int) -> CGImage {
        let normalized = ((degrees % 360) + 360) % 360
        guard normalized != 0 else { return image }

        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let size = normalized % 180 == 0
            ? CGSize(width: width, height: height)
            : CGSize(width: height, height: width)

        guard let context = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return image }

        context.translateBy(x: size.width / 2, y: size.height / 2)
        context.rotate(by: -CGFloat(normalized) * .pi / 180)
        context.draw(image, in: CGRect(x: -width / 2, y: -height / 2, width: width, height: height))
        return context.makeImage() ?? image
    }
}

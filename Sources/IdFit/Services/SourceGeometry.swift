import CoreGraphics
import Foundation
import ImageIO
import PDFKit

/// Pixel (or, for PDF, point) dimensions of page sources, as displayed —
/// EXIF orientation and PDF page rotation are already applied, so these match
/// what thumbnails show and what normalized crop rects refer to.
final class SourceGeometry: @unchecked Sendable {
    static let shared = SourceGeometry()

    private let cache = NSCache<NSString, NSValue>()

    /// Call after source files change on disk.
    func invalidate() {
        cache.removeAllObjects()
    }

    /// Cheap: reads image headers only, never decodes pixels. Safe to call
    /// off the main thread.
    func size(for ref: SourceRef, in folder: URL) -> CGSize? {
        let key = "\(ref.file)#\(ref.pdfPage ?? -1)" as NSString
        if let cached = cache.object(forKey: key) { return cached.sizeValue }

        let url = folder.appendingPathComponent(ref.file)
        let size: CGSize?
        if url.pathExtension.lowercased() == "pdf" {
            size = Self.pdfPageSize(url: url, pageIndex: ref.pdfPage ?? 0)
        } else {
            size = Self.imageSize(url: url)
        }

        if let size, size.width > 0, size.height > 0 {
            cache.setObject(NSValue(size: size), forKey: key)
            return size
        }
        return nil
    }

    /// Resolution used to turn pixels into print size. Scans without
    /// resolution metadata are assumed to be 300 dpi, the usual scanner
    /// default; PDF content is already in points.
    func dpi(for ref: SourceRef, in folder: URL) -> Double {
        let url = folder.appendingPathComponent(ref.file)
        guard url.pathExtension.lowercased() != "pdf" else { return 72 }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let dpi = properties[kCGImagePropertyDPIWidth] as? Double,
              dpi > 0
        else { return 300 }
        return dpi
    }

    private static func imageSize(url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Double,
              let height = properties[kCGImagePropertyPixelHeight] as? Double
        else { return nil }

        // Orientations 5...8 mean the stored pixels are rotated by 90°.
        let orientation = properties[kCGImagePropertyOrientation] as? UInt32 ?? 1
        return (5...8).contains(orientation)
            ? CGSize(width: height, height: width)
            : CGSize(width: width, height: height)
    }

    private static func pdfPageSize(url: URL, pageIndex: Int) -> CGSize? {
        guard let document = PDFDocument(url: url),
              let page = document.page(at: pageIndex) else { return nil }
        // The crop box is what viewers show, and it is how a crop applied to
        // the original file is recorded — so it, not the media box, defines
        // the page as the user sees it.
        let bounds = page.bounds(for: .cropBox)
        return page.rotation % 180 == 0
            ? bounds.size
            : CGSize(width: bounds.height, height: bounds.width)
    }
}

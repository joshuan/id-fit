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
        let bounds = page.bounds(for: .mediaBox)
        return page.rotation % 180 == 0
            ? bounds.size
            : CGSize(width: bounds.height, height: bounds.width)
    }
}

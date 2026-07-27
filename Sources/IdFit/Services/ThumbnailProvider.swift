import CoreGraphics
import Foundation
import ImageIO
import PDFKit

/// Generates and caches page thumbnails off the main thread. CGImage values
/// are immutable, so sharing them across threads is safe.
final class ThumbnailProvider: @unchecked Sendable {
    static let shared = ThumbnailProvider()

    private let cache = NSCache<NSString, CGImage>()

    /// Call after source files change on disk.
    func invalidate() {
        cache.removeAllObjects()
    }

    func thumbnail(for ref: SourceRef, in folder: URL, maxPixel: CGFloat = 512) async -> CGImage? {
        await Task.detached(priority: .utility) { [self] in
            renderedImage(for: ref, in: folder, maxPixel: maxPixel)
        }.value
    }

    /// Blocking variant for callers that are already off the main thread, such
    /// as edge detection.
    func renderedImage(for ref: SourceRef, in folder: URL, maxPixel: CGFloat) -> CGImage? {
        let key = SourceCacheKey.make(for: ref, in: folder, variant: "\(Int(maxPixel))")
        if let cached = cache.object(forKey: key) { return cached }

        let url = folder.appendingPathComponent(ref.file)
        let image = url.pathExtension.lowercased() == "pdf"
            ? Self.pdfThumbnail(url: url, pageIndex: ref.pdfPage ?? 0, maxPixel: maxPixel)
            : Self.imageThumbnail(url: url, maxPixel: maxPixel)

        if let image { cache.setObject(image, forKey: key) }
        return image
    }

    private static func imageThumbnail(url: URL, maxPixel: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            // Bake EXIF orientation in, so scans photographed on a phone
            // show upright.
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func pdfThumbnail(url: URL, pageIndex: Int, maxPixel: CGFloat) -> CGImage? {
        guard let document = PDFDocument(url: url),
              let page = document.page(at: pageIndex) else { return nil }
        let bounds = page.bounds(for: .cropBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = maxPixel / max(bounds.width, bounds.height)
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let image = page.thumbnail(of: size, for: .cropBox)
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}

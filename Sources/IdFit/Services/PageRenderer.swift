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

    /// - Parameter outputRatio: the proportions the page must end up with,
    ///   needed only when straightening, which maps the document's corners
    ///   onto exactly that shape.
    static func content(for page: Page, in folder: URL, outputRatio: Double? = nil) -> Content? {
        let url = folder.appendingPathComponent(page.source.file)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        if let quad = page.quad, let outputRatio {
            return straightened(page: page, quad: quad, outputRatio: outputRatio, url: url, in: folder)
        }

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

    /// Always pixels, whatever the source was — needed when writing an image
    /// format, where a PDF page cannot stay vector.
    static func image(for page: Page, in folder: URL, outputRatio: Double?) -> CGImage? {
        guard let content = content(for: page, in: folder, outputRatio: outputRatio) else { return nil }
        switch content {
        case .image(let image):
            return image
        case .pdfPage:
            let url = folder.appendingPathComponent(page.source.file)
            guard FileManager.default.fileExists(atPath: url.path),
                  let rendered = ThumbnailProvider.shared.renderedImage(
                      for: page.source, in: folder, maxPixel: 4000
                  ) else { return nil }
            return rotate(crop(rendered, to: page.crop), by: page.rotation)
        }
    }

    /// Straightening replaces the crop: the quad already says which part of
    /// the photograph is the document. A PDF page has to be rasterized first,
    /// since a warp cannot be expressed in vector page content.
    private static func straightened(
        page: Page,
        quad: DocumentQuad,
        outputRatio: Double,
        url: URL,
        in folder: URL
    ) -> Content? {
        let source: CGImage?
        if url.pathExtension.lowercased() == "pdf" {
            source = ThumbnailProvider.shared.renderedImage(
                for: page.source, in: folder, maxPixel: 4000
            )
        } else {
            source = fullResolutionImage(at: url)
        }
        guard let source else { return nil }

        // The quad is drawn on the unrotated source, so it is straightened
        // there too; the page's own turn is applied afterwards.
        let aspect = CropGeometry.sourceAspect(outputRatio: outputRatio, rotation: page.rotation)
        guard let corrected = PerspectiveCorrector.straighten(
            source, quad: quad, targetAspect: aspect
        ) else { return nil }

        return .image(rotate(corrected, by: page.rotation))
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

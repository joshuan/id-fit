import CoreGraphics
import Foundation
import ImageIO

/// Composes the pages, in order and with their crops applied, into one PDF.
enum PDFExporter {
    enum Paper: String, CaseIterable, Identifiable, Sendable {
        case a4
        case usLetter
        case fitContent

        var id: String { rawValue }

        var title: String {
            switch self {
            case .a4: "A4"
            case .usLetter: "US Letter"
            case .fitContent: "Fit to content"
            }
        }

        var detail: String {
            switch self {
            case .a4, .usLetter:
                "Every page uses the same paper size; orientation follows the crop."
            case .fitContent:
                "Pages match the cropped scan exactly, with no margins."
            }
        }

        /// Portrait dimensions in points; nil means "follow the content".
        var portraitSize: CGSize? {
            switch self {
            case .a4: CGSize(width: 595.276, height: 841.89)
            case .usLetter: CGSize(width: 612, height: 792)
            case .fitContent: nil
            }
        }
    }

    struct Result: Sendable {
        var exportedPages: Int
        var skippedPages: [String]
    }

    enum ExportError: LocalizedError {
        case noPages
        case cannotCreateFile

        var errorDescription: String? {
            switch self {
            case .noPages: "There is nothing to export."
            case .cannotCreateFile: "The PDF file could not be created at that location."
            }
        }
    }

    /// Writes the PDF. Pages whose source file is missing are skipped and
    /// reported rather than aborting the whole export.
    static func export(
        pages: [Page],
        folder: URL,
        to destination: URL,
        paper: Paper
    ) throws -> Result {
        guard !pages.isEmpty else { throw ExportError.noPages }
        guard let context = CGContext(destination as CFURL, mediaBox: nil, nil) else {
            throw ExportError.cannotCreateFile
        }

        var exported = 0
        var skipped: [String] = []

        for page in pages {
            guard let content = PageRenderer.content(for: page, in: folder) else {
                skipped.append(page.source.displayName)
                continue
            }

            let contentSize = content.size
            guard contentSize.width > 0, contentSize.height > 0 else {
                skipped.append(page.source.displayName)
                continue
            }

            let pageSize = self.pageSize(for: content, page: page, folder: folder, paper: paper)
            var mediaBox = CGRect(origin: .zero, size: pageSize)
            context.beginPage(mediaBox: &mediaBox)
            draw(content, in: fittedRect(aspect: contentSize.width / contentSize.height, in: pageSize), context: context)
            context.endPage()
            exported += 1
        }

        context.closePDF()

        if exported == 0 {
            try? FileManager.default.removeItem(at: destination)
            throw ExportError.noPages
        }
        return Result(exportedPages: exported, skippedPages: skipped)
    }

    // MARK: - Layout

    private static func pageSize(
        for content: PageRenderer.Content,
        page: Page,
        folder: URL,
        paper: Paper
    ) -> CGSize {
        let contentSize = content.size

        guard let portrait = paper.portraitSize else {
            switch content {
            case .image:
                // Convert pixels to points using the scan's own resolution, so
                // the printed size matches the original document.
                let dpi = SourceGeometry.shared.dpi(for: page.source, in: folder)
                let scale = 72.0 / dpi
                return CGSize(width: contentSize.width * scale, height: contentSize.height * scale)
            case .pdfPage:
                return contentSize
            }
        }

        let isLandscape = contentSize.width > contentSize.height
        return isLandscape
            ? CGSize(width: portrait.height, height: portrait.width)
            : portrait
    }

    private static func fittedRect(aspect: CGFloat, in pageSize: CGSize) -> CGRect {
        var width = pageSize.width
        var height = width / aspect
        if height > pageSize.height {
            height = pageSize.height
            width = height * aspect
        }
        return CGRect(
            x: (pageSize.width - width) / 2,
            y: (pageSize.height - height) / 2,
            width: width,
            height: height
        )
    }

    // MARK: - Drawing

    private static func draw(_ content: PageRenderer.Content, in rect: CGRect, context: CGContext) {
        switch content {
        case .image(let image):
            context.draw(image, in: rect)

        case .pdfPage(let pdfPage, let displayed, let crop, let rotation):
            // Work in the rotated view of the page, so the crop, the page and
            // `rect` all share one coordinate system.
            let turned = CropGeometry.rotated(crop, by: rotation)
            let fullTurned = ((rotation % 360) + 360) % 360 % 180 == 0
                ? displayed
                : CGSize(width: displayed.height, height: displayed.width)
            guard turned.width > 0, turned.height > 0 else { return }

            // Scale the whole page up so that just the cropped window fills
            // `rect`, then clip everything outside it away.
            let scale = rect.width / (turned.width * fullTurned.width)
            let fullSize = CGSize(width: fullTurned.width * scale, height: fullTurned.height * scale)

            // PDF space has its origin at the bottom-left, crop rects at the
            // top-left, hence the flipped y.
            let target = CGRect(
                x: rect.minX - turned.x * fullSize.width,
                y: rect.minY - (1 - turned.y - turned.height) * fullSize.height,
                width: fullSize.width,
                height: fullSize.height
            )

            context.saveGState()
            context.clip(to: rect)
            context.concatenate(
                pdfPage.getDrawingTransform(.mediaBox, rect: target, rotate: Int32(rotation), preserveAspectRatio: true)
            )
            context.drawPDFPage(pdfPage)
            context.restoreGState()
        }
    }
}

extension SourceRef {
    /// Human-readable name for messages, e.g. "scans.pdf (page 3)".
    var displayName: String {
        pdfPage.map { "\(file) (page \($0 + 1))" } ?? file
    }
}

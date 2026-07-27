import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import IdFit

/// Export is verified by rendering the produced PDF back to pixels and
/// sampling colours — the only reliable way to catch flipped, mirrored or
/// misplaced crops.
@Suite struct PDFExportTests {
    // MARK: - Fixtures

    private let red = CGColor(red: 1, green: 0, blue: 0, alpha: 1)
    private let blue = CGColor(red: 0, green: 0, blue: 1, alpha: 1)
    private let green = CGColor(red: 0, green: 1, blue: 0, alpha: 1)

    private func makeFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("id-fit-export-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeContext(size: CGSize) -> CGContext {
        CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
    }

    /// Writes a PNG split into two halves. CoreGraphics draws bottom-up, so
    /// the "top" colour is filled at the high end of y.
    private func writePNG(
        size: CGSize,
        top: CGColor? = nil,
        bottom: CGColor? = nil,
        left: CGColor? = nil,
        right: CGColor? = nil,
        solid: CGColor? = nil,
        to url: URL
    ) {
        let context = makeContext(size: size)
        if let solid {
            context.setFillColor(solid)
            context.fill(CGRect(origin: .zero, size: size))
        }
        if let bottom {
            context.setFillColor(bottom)
            context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height / 2))
        }
        if let top {
            context.setFillColor(top)
            context.fill(CGRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2))
        }
        if let left {
            context.setFillColor(left)
            context.fill(CGRect(x: 0, y: 0, width: size.width / 2, height: size.height))
        }
        if let right {
            context.setFillColor(right)
            context.fill(CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height))
        }
        let image = context.makeImage()!
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    private func writeSourcePDF(size: CGSize, top: CGColor, bottom: CGColor, to url: URL) {
        var box = CGRect(origin: .zero, size: size)
        let context = CGContext(url as CFURL, mediaBox: &box, nil)!
        context.beginPage(mediaBox: &box)
        context.setFillColor(bottom)
        context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height / 2))
        context.setFillColor(top)
        context.fill(CGRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2))
        context.endPage()
        context.closePDF()
    }

    // MARK: - Reading the result back

    /// Rendered page pixels; row 0 of the buffer is the visual top of the page.
    private struct RenderedPage {
        let width: Int
        let height: Int
        let pixels: [UInt8]

        /// Samples with (0,0) at the top-left, like the crop coordinates.
        func color(x: Double, y: Double) -> (r: Int, g: Int, b: Int) {
            let px = min(max(Int(x * Double(width)), 0), width - 1)
            let py = min(max(Int(y * Double(height)), 0), height - 1)
            let offset = (py * width + px) * 4
            return (Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2]))
        }

        func isRed(x: Double, y: Double) -> Bool {
            let c = color(x: x, y: y)
            return c.r > 200 && c.g < 60 && c.b < 60
        }

        func isBlue(x: Double, y: Double) -> Bool {
            let c = color(x: x, y: y)
            return c.b > 200 && c.r < 60 && c.g < 60
        }

        func isGreen(x: Double, y: Double) -> Bool {
            let c = color(x: x, y: y)
            return c.g > 200 && c.r < 60 && c.b < 60
        }
    }

    private func render(_ url: URL, pageIndex: Int) throws -> RenderedPage {
        let document = try #require(CGPDFDocument(url as CFURL))
        let page = try #require(document.page(at: pageIndex + 1))
        let box = page.getBoxRect(.mediaBox)
        let width = Int(box.width)
        let height = Int(box.height)

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.translateBy(x: -box.minX, y: -box.minY)
            context.drawPDFPage(page)
        }
        return RenderedPage(width: width, height: height, pixels: pixels)
    }

    private func pageCount(_ url: URL) throws -> Int {
        try #require(CGPDFDocument(url as CFURL)).numberOfPages
    }

    // MARK: - Tests

    @Test func exportedImageIsNotFlippedUpsideDown() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        writePNG(size: CGSize(width: 400, height: 600), top: red, bottom: blue,
                 to: folder.appendingPathComponent("page.png"))

        let output = folder.appendingPathComponent("out.pdf")
        let result = try PDFExporter.export(
            pages: [Page(source: SourceRef(file: "page.png"))],
            folder: folder, to: output, paper: .fitContent
        )
        #expect(result.exportedPages == 1)

        let rendered = try render(output, pageIndex: 0)
        #expect(rendered.isRed(x: 0.5, y: 0.1))
        #expect(rendered.isBlue(x: 0.5, y: 0.9))
    }

    @Test func exportedImageIsNotMirrored() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        writePNG(size: CGSize(width: 600, height: 400), left: red, right: blue,
                 to: folder.appendingPathComponent("page.png"))

        let output = folder.appendingPathComponent("out.pdf")
        _ = try PDFExporter.export(
            pages: [Page(source: SourceRef(file: "page.png"))],
            folder: folder, to: output, paper: .fitContent
        )

        let rendered = try render(output, pageIndex: 0)
        #expect(rendered.isRed(x: 0.1, y: 0.5))
        #expect(rendered.isBlue(x: 0.9, y: 0.5))
    }

    @Test func cropSelectsTheTopHalf() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        writePNG(size: CGSize(width: 400, height: 600), top: red, bottom: blue,
                 to: folder.appendingPathComponent("page.png"))

        let output = folder.appendingPathComponent("out.pdf")
        _ = try PDFExporter.export(
            pages: [Page(
                source: SourceRef(file: "page.png"),
                crop: CropRect(x: 0, y: 0, width: 1, height: 0.5)
            )],
            folder: folder, to: output, paper: .fitContent
        )

        let rendered = try render(output, pageIndex: 0)
        for y in [0.05, 0.5, 0.95] {
            #expect(rendered.isRed(x: 0.5, y: y))
        }
    }

    @Test func cropSelectsTheLeftHalf() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        writePNG(size: CGSize(width: 600, height: 400), left: red, right: blue,
                 to: folder.appendingPathComponent("page.png"))

        let output = folder.appendingPathComponent("out.pdf")
        _ = try PDFExporter.export(
            pages: [Page(
                source: SourceRef(file: "page.png"),
                crop: CropRect(x: 0, y: 0, width: 0.5, height: 1)
            )],
            folder: folder, to: output, paper: .fitContent
        )

        let rendered = try render(output, pageIndex: 0)
        for x in [0.05, 0.5, 0.95] {
            #expect(rendered.isRed(x: x, y: 0.5))
        }
    }

    @Test func pagesAreWrittenInDocumentOrder() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        writePNG(size: CGSize(width: 200, height: 200), solid: red, to: folder.appendingPathComponent("r.png"))
        writePNG(size: CGSize(width: 200, height: 200), solid: green, to: folder.appendingPathComponent("g.png"))
        writePNG(size: CGSize(width: 200, height: 200), solid: blue, to: folder.appendingPathComponent("b.png"))

        let output = folder.appendingPathComponent("out.pdf")
        _ = try PDFExporter.export(
            pages: [
                Page(source: SourceRef(file: "b.png")),
                Page(source: SourceRef(file: "r.png")),
                Page(source: SourceRef(file: "g.png")),
            ],
            folder: folder, to: output, paper: .fitContent
        )

        #expect(try pageCount(output) == 3)
        #expect(try render(output, pageIndex: 0).isBlue(x: 0.5, y: 0.5))
        #expect(try render(output, pageIndex: 1).isRed(x: 0.5, y: 0.5))
        #expect(try render(output, pageIndex: 2).isGreen(x: 0.5, y: 0.5))
    }

    @Test func pdfSourcePageIsExportedUprightAndCropped() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        writeSourcePDF(size: CGSize(width: 400, height: 600), top: red, bottom: blue,
                       to: folder.appendingPathComponent("scan.pdf"))

        let output = folder.appendingPathComponent("out.pdf")
        _ = try PDFExporter.export(
            pages: [Page(source: SourceRef(file: "scan.pdf", pdfPage: 0))],
            folder: folder, to: output, paper: .fitContent
        )

        let whole = try render(output, pageIndex: 0)
        #expect(whole.isRed(x: 0.5, y: 0.1))
        #expect(whole.isBlue(x: 0.5, y: 0.9))

        let croppedOutput = folder.appendingPathComponent("cropped.pdf")
        _ = try PDFExporter.export(
            pages: [Page(
                source: SourceRef(file: "scan.pdf", pdfPage: 0),
                crop: CropRect(x: 0, y: 0, width: 1, height: 0.5)
            )],
            folder: folder, to: croppedOutput, paper: .fitContent
        )

        let cropped = try render(croppedOutput, pageIndex: 0)
        for y in [0.05, 0.5, 0.95] {
            #expect(cropped.isRed(x: 0.5, y: y))
        }
    }

    @Test func multiPagePDFSourceKeepsPageIdentity() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let source = folder.appendingPathComponent("multi.pdf")
        var box = CGRect(x: 0, y: 0, width: 300, height: 300)
        let context = CGContext(source as CFURL, mediaBox: &box, nil)!
        for color in [red, green, blue] {
            context.beginPage(mediaBox: &box)
            context.setFillColor(color)
            context.fill(box)
            context.endPage()
        }
        context.closePDF()

        let output = folder.appendingPathComponent("out.pdf")
        _ = try PDFExporter.export(
            pages: [
                Page(source: SourceRef(file: "multi.pdf", pdfPage: 2)),
                Page(source: SourceRef(file: "multi.pdf", pdfPage: 0)),
            ],
            folder: folder, to: output, paper: .fitContent
        )

        #expect(try pageCount(output) == 2)
        #expect(try render(output, pageIndex: 0).isBlue(x: 0.5, y: 0.5))
        #expect(try render(output, pageIndex: 1).isRed(x: 0.5, y: 0.5))
    }

    @Test func paperSizeIsAppliedWithMatchingOrientation() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        writePNG(size: CGSize(width: 400, height: 600), solid: red, to: folder.appendingPathComponent("portrait.png"))
        writePNG(size: CGSize(width: 600, height: 400), solid: blue, to: folder.appendingPathComponent("landscape.png"))

        let output = folder.appendingPathComponent("out.pdf")
        _ = try PDFExporter.export(
            pages: [
                Page(source: SourceRef(file: "portrait.png")),
                Page(source: SourceRef(file: "landscape.png")),
            ],
            folder: folder, to: output, paper: .a4
        )

        let document = try #require(CGPDFDocument(output as CFURL))
        let first = try #require(document.page(at: 1)).getBoxRect(.mediaBox)
        let second = try #require(document.page(at: 2)).getBoxRect(.mediaBox)

        #expect(abs(first.width - 595.276) < 1)
        #expect(abs(first.height - 841.89) < 1)
        #expect(abs(second.width - 841.89) < 1)
        #expect(abs(second.height - 595.276) < 1)
    }

    @Test func contentIsCenteredOnPaperWithoutDistortion() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        // A wide strip on portrait A4 must be letterboxed, not stretched.
        writePNG(size: CGSize(width: 900, height: 300), solid: red, to: folder.appendingPathComponent("strip.png"))

        let output = folder.appendingPathComponent("out.pdf")
        _ = try PDFExporter.export(
            pages: [Page(source: SourceRef(file: "strip.png"))],
            folder: folder, to: output, paper: .usLetter
        )

        let rendered = try render(output, pageIndex: 0)
        #expect(rendered.isRed(x: 0.5, y: 0.5))
        // Top and bottom stay white.
        let top = rendered.color(x: 0.5, y: 0.02)
        #expect(top.r > 240 && top.g > 240 && top.b > 240)
    }

    @Test func missingFilesAreSkippedAndReported() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        writePNG(size: CGSize(width: 200, height: 200), solid: red, to: folder.appendingPathComponent("there.png"))

        let output = folder.appendingPathComponent("out.pdf")
        let result = try PDFExporter.export(
            pages: [
                Page(source: SourceRef(file: "gone.png")),
                Page(source: SourceRef(file: "there.png")),
                Page(source: SourceRef(file: "gone.pdf", pdfPage: 3)),
            ],
            folder: folder, to: output, paper: .fitContent
        )

        #expect(result.exportedPages == 1)
        #expect(result.skippedPages == ["gone.png", "gone.pdf (page 4)"])
        #expect(try pageCount(output) == 1)
    }

    @Test func exportWithoutAnyUsablePageFails() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let output = folder.appendingPathComponent("out.pdf")
        #expect(throws: PDFExporter.ExportError.self) {
            try PDFExporter.export(
                pages: [Page(source: SourceRef(file: "gone.png"))],
                folder: folder, to: output, paper: .a4
            )
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test func rotatedPageIsTurnedClockwise() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        writePNG(size: CGSize(width: 400, height: 600), top: red, bottom: blue,
                 to: folder.appendingPathComponent("page.png"))

        let output = folder.appendingPathComponent("out.pdf")
        _ = try PDFExporter.export(
            pages: [Page(source: SourceRef(file: "page.png"), rotation: 90)],
            folder: folder, to: output, paper: .fitContent
        )

        let rendered = try render(output, pageIndex: 0)
        // Turning clockwise moves the top edge to the right.
        #expect(rendered.width > rendered.height)
        #expect(rendered.isRed(x: 0.9, y: 0.5))
        #expect(rendered.isBlue(x: 0.1, y: 0.5))
    }

    @Test func rotatedPDFPageIsTurnedClockwise() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        writeSourcePDF(size: CGSize(width: 400, height: 600), top: red, bottom: blue,
                       to: folder.appendingPathComponent("scan.pdf"))

        let output = folder.appendingPathComponent("out.pdf")
        _ = try PDFExporter.export(
            pages: [Page(source: SourceRef(file: "scan.pdf", pdfPage: 0), rotation: 90)],
            folder: folder, to: output, paper: .fitContent
        )

        let rendered = try render(output, pageIndex: 0)
        #expect(rendered.width > rendered.height)
        #expect(rendered.isRed(x: 0.9, y: 0.5))
        #expect(rendered.isBlue(x: 0.1, y: 0.5))
    }
}

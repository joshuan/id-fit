import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Testing
import UniformTypeIdentifiers
@testable import IdFit

/// Covers the two explicit, user-triggered operations that leave the app's
/// own state: writing separate files, and rewriting the originals.
@Suite struct ApplyAndFileExportTests {
    private let red = CGColor(red: 1, green: 0, blue: 0, alpha: 1)
    private let blue = CGColor(red: 0, green: 0, blue: 1, alpha: 1)

    // MARK: - Fixtures

    private func makeFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("id-fit-apply-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Top half red, bottom half blue.
    private func writeSplitPNG(size: CGSize, to url: URL) {
        let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(blue)
        context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height / 2))
        context.setFillColor(red)
        context.fill(CGRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2))
        let image = context.makeImage()!
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    private func writeSplitPDF(size: CGSize, pages: Int, to url: URL) {
        var box = CGRect(origin: .zero, size: size)
        let context = CGContext(url as CFURL, mediaBox: &box, nil)!
        for _ in 0..<pages {
            context.beginPage(mediaBox: &box)
            context.setFillColor(blue)
            context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height / 2))
            context.setFillColor(red)
            context.fill(CGRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2))
            context.endPage()
        }
        context.closePDF()
    }

    private func topColorOfPNG(at url: URL) throws -> (r: Int, g: Int, b: Int) {
        let image = try #require(PageRenderer.fullResolutionImage(at: url))
        return try sample(image, atRelativeY: 0.1)
    }

    private func sample(_ image: CGImage, atRelativeY y: Double) throws -> (r: Int, g: Int, b: Int) {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        // Buffer row 0 is the top of the image.
        let row = min(max(Int(y * Double(height)), 0), height - 1)
        let offset = (row * width + width / 2) * 4
        return (Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2]))
    }

    private func isRed(_ color: (r: Int, g: Int, b: Int)) -> Bool {
        color.r > 200 && color.g < 60 && color.b < 60
    }

    // MARK: - Export to a separate folder

    @Test func fileExportWritesOrderedCroppedCopies() throws {
        let folder = try makeFolder()
        let destination = try makeFolder()
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: destination)
        }
        writeSplitPNG(size: CGSize(width: 400, height: 600), to: folder.appendingPathComponent("scan.png"))
        writeSplitPDF(size: CGSize(width: 400, height: 600), pages: 2, to: folder.appendingPathComponent("doc.pdf"))

        let topHalf = CropRect(x: 0, y: 0, width: 1, height: 0.5)
        let result = try FileExporter.export(
            pages: [
                Page(source: SourceRef(file: "doc.pdf", pdfPage: 1), crop: topHalf),
                Page(source: SourceRef(file: "scan.png"), crop: topHalf),
            ],
            folder: folder,
            to: destination
        )

        #expect(result.skippedPages.isEmpty)
        #expect(result.writtenFiles == ["001.pdf", "002.png"])

        // The exported image really is only the red half.
        let exported = destination.appendingPathComponent("002.png")
        #expect(isRed(try topColorOfPNG(at: exported)))
        let size = try #require(SourceGeometry.shared.size(for: SourceRef(file: "002.png"), in: destination))
        #expect(size == CGSize(width: 400, height: 300))
    }

    @Test func filesCanKeepTheNamesOfTheScansTheyCameFrom() throws {
        let folder = try makeFolder()
        let destination = try makeFolder()
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: destination)
        }
        writeSplitPNG(size: CGSize(width: 400, height: 600), to: folder.appendingPathComponent("scan.png"))
        writeSplitPDF(size: CGSize(width: 400, height: 600), pages: 2, to: folder.appendingPathComponent("doc.pdf"))

        let result = try FileExporter.export(
            pages: [
                Page(source: SourceRef(file: "scan.png")),
                Page(source: SourceRef(file: "doc.pdf", pdfPage: 1)),
            ],
            folder: folder,
            to: destination,
            naming: .original
        )

        #expect(result.writtenFiles == ["scan.png", "doc-p2.pdf"])
    }

    @Test func aPageUsedTwiceDoesNotOverwriteItself() throws {
        let folder = try makeFolder()
        let destination = try makeFolder()
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: destination)
        }
        writeSplitPNG(size: CGSize(width: 400, height: 600), to: folder.appendingPathComponent("cover.png"))

        // A passport cover is both the front and the back of the document.
        let source = SourceRef(file: "cover.png")
        let result = try FileExporter.export(
            pages: [
                Page(source: source, crop: CropRect(x: 0, y: 0, width: 1, height: 0.5)),
                Page(source: source, crop: CropRect(x: 0, y: 0.5, width: 1, height: 0.5)),
            ],
            folder: folder,
            to: destination,
            naming: .original
        )

        #expect(result.writtenFiles == ["cover.png", "cover (2).png"])
        // Two files, and they really do hold different halves.
        #expect(isRed(try topColorOfPNG(at: destination.appendingPathComponent("cover.png"))))
        let second = try topColorOfPNG(at: destination.appendingPathComponent("cover (2).png"))
        #expect(second.b > 200 && second.r < 60)
    }

    @Test func exportingAsJPEGTurnsEveryPageIntoAnImage() throws {
        let folder = try makeFolder()
        let destination = try makeFolder()
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: destination)
        }
        writeSplitPNG(size: CGSize(width: 400, height: 600), to: folder.appendingPathComponent("scan.png"))
        writeSplitPDF(size: CGSize(width: 400, height: 600), pages: 1, to: folder.appendingPathComponent("doc.pdf"))

        let result = try FileExporter.export(
            pages: [
                Page(source: SourceRef(file: "scan.png"), crop: CropRect(x: 0, y: 0, width: 1, height: 0.5)),
                // Even a PDF page comes out as an image here.
                Page(source: SourceRef(file: "doc.pdf", pdfPage: 0)),
            ],
            folder: folder,
            to: destination,
            format: .jpeg
        )

        #expect(result.skippedPages.isEmpty)
        #expect(result.writtenFiles == ["001.jpg", "002.jpg"])
        for name in result.writtenFiles {
            let size = try #require(SourceGeometry.shared.size(for: SourceRef(file: name), in: destination))
            #expect(size.width > 0 && size.height > 0)
        }
        #expect(isRed(try topColorOfPNG(at: destination.appendingPathComponent("001.jpg"))))
    }

    @Test func fileExportLeavesSourcesUntouched() throws {
        let folder = try makeFolder()
        let destination = try makeFolder()
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: destination)
        }
        let source = folder.appendingPathComponent("scan.png")
        writeSplitPNG(size: CGSize(width: 400, height: 600), to: source)
        let before = try Data(contentsOf: source)

        _ = try FileExporter.export(
            pages: [Page(source: SourceRef(file: "scan.png"), crop: CropRect(x: 0, y: 0, width: 1, height: 0.5))],
            folder: folder,
            to: destination
        )

        #expect(try Data(contentsOf: source) == before)
    }

    @Test func fileExportRefusesToWriteIntoTheWorkingFolder() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        writeSplitPNG(size: CGSize(width: 200, height: 200), to: folder.appendingPathComponent("scan.png"))

        #expect(throws: FileExporter.ExportError.self) {
            _ = try FileExporter.export(
                pages: [Page(source: SourceRef(file: "scan.png"))],
                folder: folder,
                to: folder.appendingPathComponent("exported", isDirectory: true)
            )
        }
    }

    // MARK: - Applying to originals

    @Test func applyCropsRewritesImageAndKeepsBackup() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("scan.png")
        writeSplitPNG(size: CGSize(width: 400, height: 600), to: source)
        let original = try Data(contentsOf: source)

        let page = Page(source: SourceRef(file: "scan.png"), crop: CropRect(x: 0, y: 0, width: 1, height: 0.5))
        let result = try OriginalsWriter.apply(pages: [page], folder: folder, makeBackup: true)

        #expect(result.changedFiles == ["scan.png"])
        #expect(result.appliedPageIDs == [page.id])
        #expect(result.failures.isEmpty)

        SourceGeometry.shared.invalidate()
        let size = try #require(SourceGeometry.shared.size(for: page.source, in: folder))
        #expect(size == CGSize(width: 400, height: 300))
        #expect(isRed(try topColorOfPNG(at: source)))

        let backup = folder.appendingPathComponent(OriginalsWriter.backupFolderName)
            .appendingPathComponent("scan.png")
        #expect(try Data(contentsOf: backup) == original)
    }

    @Test func applyWithoutBackupLeavesNoBackupFolder() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        writeSplitPNG(size: CGSize(width: 400, height: 600), to: folder.appendingPathComponent("scan.png"))

        let result = try OriginalsWriter.apply(
            pages: [Page(source: SourceRef(file: "scan.png"), crop: CropRect(x: 0, y: 0, width: 1, height: 0.5))],
            folder: folder,
            makeBackup: false
        )

        #expect(result.backupFolder == nil)
        #expect(!FileManager.default.fileExists(
            atPath: folder.appendingPathComponent(OriginalsWriter.backupFolderName).path
        ))
    }

    @Test func backupKeepsTheEarliestCopyAcrossRepeatedApplies() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("scan.png")
        writeSplitPNG(size: CGSize(width: 400, height: 600), to: source)
        let trueOriginal = try Data(contentsOf: source)

        let crop = CropRect(x: 0, y: 0, width: 1, height: 0.5)
        _ = try OriginalsWriter.apply(
            pages: [Page(source: SourceRef(file: "scan.png"), crop: crop)],
            folder: folder, makeBackup: true
        )
        _ = try OriginalsWriter.apply(
            pages: [Page(source: SourceRef(file: "scan.png"), crop: crop)],
            folder: folder, makeBackup: true
        )

        let backup = folder.appendingPathComponent(OriginalsWriter.backupFolderName)
            .appendingPathComponent("scan.png")
        #expect(try Data(contentsOf: backup) == trueOriginal)
    }

    @Test func applyCropsNarrowsPDFCropBoxWithoutLosingPages() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("doc.pdf")
        writeSplitPDF(size: CGSize(width: 400, height: 600), pages: 3, to: source)

        let crop = CropRect(x: 0, y: 0, width: 1, height: 0.5)
        let result = try OriginalsWriter.apply(
            pages: [
                Page(source: SourceRef(file: "doc.pdf", pdfPage: 0), crop: crop),
                Page(source: SourceRef(file: "doc.pdf", pdfPage: 2), crop: crop),
            ],
            folder: folder,
            makeBackup: false
        )
        #expect(result.changedFiles == ["doc.pdf"])

        let document = try #require(PDFDocument(url: source))
        #expect(document.pageCount == 3)

        let cropped = try #require(document.page(at: 0)).bounds(for: .cropBox)
        #expect(cropped.size == CGSize(width: 400, height: 300))
        // Cropping the top half must keep the upper part of the page, which
        // in PDF coordinates is the high end of y.
        #expect(cropped.minY == 300)

        let untouched = try #require(document.page(at: 1)).bounds(for: .cropBox)
        #expect(untouched.size == CGSize(width: 400, height: 600))
    }

    @Test func croppedPDFRendersAsTheCroppedRegion() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("doc.pdf")
        writeSplitPDF(size: CGSize(width: 400, height: 600), pages: 1, to: source)

        _ = try OriginalsWriter.apply(
            pages: [Page(source: SourceRef(file: "doc.pdf", pdfPage: 0),
                         crop: CropRect(x: 0, y: 0, width: 1, height: 0.5))],
            folder: folder,
            makeBackup: false
        )

        ThumbnailProvider.shared.invalidate()
        SourceGeometry.shared.invalidate()

        // Re-exporting the now-cropped file must not crop a second time.
        let output = folder.appendingPathComponent("out.pdf")
        _ = try PDFExporter.export(
            pages: [Page(source: SourceRef(file: "doc.pdf", pdfPage: 0))],
            folder: folder, to: output, paper: .fitContent
        )

        let document = try #require(CGPDFDocument(output as CFURL))
        let page = try #require(document.page(at: 1))
        let box = page.getBoxRect(.mediaBox)
        #expect(abs(box.height - 300) < 1)

        var pixels = [UInt8](repeating: 0, count: 400 * 300 * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: 400, height: 300,
                bitsPerComponent: 8, bytesPerRow: 400 * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.translateBy(x: -box.minX, y: -box.minY)
            context.drawPDFPage(page)
        }
        // Every sampled row must be red — no blue half left over.
        for row in [10, 150, 290] {
            let offset = (row * 400 + 200) * 4
            #expect(Int(pixels[offset]) > 200)
            #expect(Int(pixels[offset + 2]) < 60)
        }
    }

    @Test func pagesWithoutEditsAreNotTouched() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let untouched = folder.appendingPathComponent("plain.png")
        writeSplitPNG(size: CGSize(width: 200, height: 200), to: untouched)
        let before = try Data(contentsOf: untouched)

        let result = try OriginalsWriter.apply(
            pages: [Page(source: SourceRef(file: "plain.png"))],
            folder: folder,
            makeBackup: true
        )

        #expect(result.changedFiles.isEmpty)
        #expect(try Data(contentsOf: untouched) == before)
    }

    @Test func missingSourceIsReportedAsFailure() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let result = try OriginalsWriter.apply(
            pages: [Page(source: SourceRef(file: "gone.png"), crop: CropRect(x: 0, y: 0, width: 1, height: 0.5))],
            folder: folder,
            makeBackup: false
        )

        #expect(result.failures == ["gone.png"])
        #expect(result.changedFiles.isEmpty)
        #expect(result.appliedPageIDs.isEmpty)
    }

    // MARK: - Store integration

    @MainActor
    @Test func storeClearsCropsAfterApplyingSoNothingIsCroppedTwice() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        writeSplitPNG(size: CGSize(width: 400, height: 600), to: folder.appendingPathComponent("scan.png"))

        let store = DocumentStore()
        await store.openFolder(folder)
        store.setCrop(CropRect(x: 0, y: 0, width: 1, height: 0.5), forPageID: store.state.pages[0].id)
        await store.applyToOriginals(makeBackup: false)

        #expect(store.lastError == nil)
        #expect(store.state.pages[0].crop == nil)
        #expect(store.state.pages[0].rotation == 0)
        // Sizes were refreshed from the rewritten file.
        #expect(store.sourceSizes[store.state.pages[0].source] == CGSize(width: 400, height: 300))

        // And the cleared crop is what gets persisted.
        let saved = try #require(try StateStore.load(from: folder))
        #expect(saved.pages[0].crop == nil)
    }

    @MainActor
    @Test func reopeningAfterApplyShowsTheCroppedFileOnce() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        writeSplitPNG(size: CGSize(width: 400, height: 600), to: folder.appendingPathComponent("scan.png"))

        let store = DocumentStore()
        await store.openFolder(folder)
        store.setCrop(CropRect(x: 0, y: 0, width: 1, height: 0.5), forPageID: store.state.pages[0].id)
        await store.applyToOriginals(makeBackup: false)

        let reopened = DocumentStore()
        await reopened.openFolder(folder)
        #expect(reopened.state.pages.count == 1)
        #expect(reopened.state.pages[0].crop == nil)
        #expect(reopened.sourceSizes[reopened.state.pages[0].source] == CGSize(width: 400, height: 300))
    }
}

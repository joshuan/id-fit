import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Testing
import UniformTypeIdentifiers
@testable import IdFit

/// One scan often holds two pages of the finished document, framed
/// differently. A single file cannot answer both framings, so applying to the
/// originals gives each page a file of its own — for a long time it refused
/// instead, and the second framing had nowhere to go.
@MainActor
@Suite struct SharedScanApplyTests {
    private let red = CGColor(red: 1, green: 0, blue: 0, alpha: 1)
    private let blue = CGColor(red: 0, green: 0, blue: 1, alpha: 1)

    private func makeFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("id-fit-shared-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Top half red, bottom half blue, as the picture is looked at.
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
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        )!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
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

    private func sample(_ image: CGImage, atRelativeY y: Double) -> (r: Int, g: Int, b: Int) {
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
        // Buffer row 0 is the top of the picture.
        let row = min(max(Int(y * Double(height)), 0), height - 1)
        let offset = (row * width + width / 2) * 4
        return (Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2]))
    }

    private func colour(of file: URL, atRelativeY y: Double) throws -> (r: Int, g: Int, b: Int) {
        sample(try #require(PageRenderer.fullResolutionImage(at: file)), atRelativeY: y)
    }

    private func isRed(_ colour: (r: Int, g: Int, b: Int)) -> Bool {
        colour.r > 200 && colour.g < 60 && colour.b < 60
    }

    private func isBlue(_ colour: (r: Int, g: Int, b: Int)) -> Bool {
        colour.b > 200 && colour.r < 60 && colour.g < 60
    }

    private let topHalf = CropRect(x: 0, y: 0, width: 1, height: 0.5)
    private let bottomHalf = CropRect(x: 0, y: 0.5, width: 1, height: 0.5)

    // MARK: - Images

    @Test func twoFramingsOfOneScanBecomeTwoFiles() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("scan.png")
        writeSplitPNG(size: CGSize(width: 400, height: 600), to: source)

        let first = Page(source: SourceRef(file: "scan.png"), crop: topHalf)
        let second = Page(source: SourceRef(file: "scan.png"), crop: bottomHalf)
        let result = try OriginalsWriter.apply(
            pages: [first, second], folder: folder, makeBackup: false
        )

        #expect(result.failures.isEmpty)
        #expect(result.changedFiles == ["scan.png"])
        #expect(result.createdFiles == ["scan-2.png"])
        #expect(result.appliedPageIDs == [first.id, second.id])
        // The page that was given a file follows it.
        #expect(result.newSources[second.id] == SourceRef(file: "scan-2.png"))
        #expect(result.newSources[first.id] == nil)

        SourceGeometry.shared.invalidate()
        let copy = folder.appendingPathComponent("scan-2.png")
        #expect(SourceGeometry.shared.size(for: SourceRef(file: "scan.png"), in: folder)
            == CGSize(width: 400, height: 300))
        #expect(SourceGeometry.shared.size(for: SourceRef(file: "scan-2.png"), in: folder)
            == CGSize(width: 400, height: 300))

        // The first page kept the file and the top of the scan; the second
        // page's own file holds the half nobody else claimed.
        #expect(isRed(try colour(of: source, atRelativeY: 0.5)))
        #expect(isBlue(try colour(of: copy, atRelativeY: 0.5)))
    }

    @Test func aThirdPageOnTheSameScanGetsAThirdFile() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        writeSplitPNG(size: CGSize(width: 400, height: 600),
                      to: folder.appendingPathComponent("scan.png"))

        let pages = [
            Page(source: SourceRef(file: "scan.png"), crop: topHalf),
            Page(source: SourceRef(file: "scan.png"), crop: bottomHalf),
            Page(source: SourceRef(file: "scan.png"),
                 crop: CropRect(x: 0, y: 0.25, width: 1, height: 0.5)),
        ]
        let result = try OriginalsWriter.apply(pages: pages, folder: folder, makeBackup: false)

        #expect(result.createdFiles == ["scan-2.png", "scan-3.png"])
        #expect(result.newSources[pages[1].id] == SourceRef(file: "scan-2.png"))
        #expect(result.newSources[pages[2].id] == SourceRef(file: "scan-3.png"))
    }

    /// The name beside the scan may be taken already — by another file in the
    /// folder, or by a page that is still waiting for its own copy.
    @Test func aNameAlreadyInTheFolderIsNotWrittenOver() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        writeSplitPNG(size: CGSize(width: 400, height: 600),
                      to: folder.appendingPathComponent("scan.png"))
        let occupied = folder.appendingPathComponent("scan-2.png")
        writeSplitPNG(size: CGSize(width: 100, height: 100), to: occupied)
        let untouched = try Data(contentsOf: occupied)

        let pages = [
            Page(source: SourceRef(file: "scan.png"), crop: topHalf),
            Page(source: SourceRef(file: "scan.png"), crop: bottomHalf),
        ]
        let result = try OriginalsWriter.apply(pages: pages, folder: folder, makeBackup: false)

        #expect(result.createdFiles == ["scan-3.png"])
        #expect(try Data(contentsOf: occupied) == untouched)
    }

    /// The other page of the pair was never framed — but the file under it is
    /// about to be, so it needs a copy just as much.
    @Test func anUnframedPageSharingAScanKeepsTheWholeScan() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("scan.png")
        writeSplitPNG(size: CGSize(width: 400, height: 600), to: source)

        let framed = Page(source: SourceRef(file: "scan.png"), crop: topHalf)
        let plain = Page(source: SourceRef(file: "scan.png"))
        let result = try OriginalsWriter.apply(
            pages: [framed, plain], folder: folder, makeBackup: false
        )

        #expect(result.createdFiles == ["scan-2.png"])
        #expect(result.newSources[plain.id] == SourceRef(file: "scan-2.png"))

        SourceGeometry.shared.invalidate()
        let copy = folder.appendingPathComponent("scan-2.png")
        #expect(SourceGeometry.shared.size(for: SourceRef(file: "scan-2.png"), in: folder)
            == CGSize(width: 400, height: 600))
        #expect(isRed(try colour(of: copy, atRelativeY: 0.25)))
        #expect(isBlue(try colour(of: copy, atRelativeY: 0.75)))
    }

    /// Nothing was framed at all, so nothing is copied: duplicating a page is
    /// not by itself a reason to duplicate a file.
    @Test func untouchedDuplicatesLeaveTheFolderAlone() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        writeSplitPNG(size: CGSize(width: 400, height: 600),
                      to: folder.appendingPathComponent("scan.png"))

        let result = try OriginalsWriter.apply(
            pages: [
                Page(source: SourceRef(file: "scan.png")),
                Page(source: SourceRef(file: "scan.png")),
            ],
            folder: folder, makeBackup: false
        )

        #expect(result.createdFiles.isEmpty)
        #expect(result.changedFiles.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["scan.png"])
    }

    // MARK: - PDFs

    @Test func applyingASelectionLeavesOtherFilesAndEditsUntouched() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["a.png", "b.png", "c.png"] {
            writeSplitPNG(size: CGSize(width: 400, height: 600), to: folder.appendingPathComponent(name))
        }
        let untouched = try Data(contentsOf: folder.appendingPathComponent("b.png"))
        let store = DocumentStore()
        await store.openFolder(folder)
        for page in store.state.pages { store.setCrop(topHalf, forPageID: page.id) }
        let pending = store.state.pages[1]
        let ids: Set<UUID> = [store.state.pages[0].id, store.state.pages[2].id]

        await store.applyToOriginals(pageIDs: ids, makeBackup: true)

        #expect(store.lastError == nil)
        #expect(try #require(store.lastApplyResult).appliedPageIDs == ids)
        #expect(store.state.pages[1] == pending)
        #expect(try Data(contentsOf: folder.appendingPathComponent("b.png")) == untouched)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(".id-fit-originals/b.png").path))
        for page in store.state.pages where ids.contains(page.id) {
            #expect(!OriginalsWriter.isEdited(page))
            #expect(store.sourceSizes[page.source] == CGSize(width: 400, height: 300))
            #expect(isRed(try colour(of: folder.appendingPathComponent(page.source.file), atRelativeY: 0.5)))
        }
        #expect(try StateStore.load(from: folder)?.pages[1] == pending)
    }

    @Test func aSelectedDuplicateGetsACopyAndLeavesTheUnselectedPageAlone() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("scan.png")
        writeSplitPNG(size: CGSize(width: 400, height: 600), to: file)
        let original = try Data(contentsOf: file)
        let store = DocumentStore()
        await store.openFolder(folder)
        let first = store.state.pages[0].id
        store.duplicatePage(id: first)
        let second = store.state.pages[1].id
        store.setCrop(topHalf, forPageID: first)
        store.setCrop(bottomHalf, forPageID: second)
        let unselected = store.state.pages[1]

        await store.applyToOriginals(pageIDs: [first], makeBackup: false)

        #expect(store.lastError == nil)
        #expect(store.state.pages[1] == unselected)
        #expect(try Data(contentsOf: file) == original)
        #expect(store.state.pages[0].source.file == "scan-2.png")
        #expect(isRed(try colour(of: folder.appendingPathComponent("scan-2.png"), atRelativeY: 0.5)))
        #expect(try #require(store.lastApplyResult).appliedPageIDs == [first])
        #expect(!OriginalsWriter.isEdited(store.state.pages[0]))
    }

    @Test func selectingOnePDFPageDoesNotApplyOtherPagesPendingEdits() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("doc.pdf")
        writeSplitPDF(size: CGSize(width: 400, height: 600), pages: 3, to: file)
        let store = DocumentStore()
        await store.openFolder(folder)
        for page in store.state.pages { store.setCrop(topHalf, forPageID: page.id) }
        let before = store.state.pages
        await store.applyToOriginals(pageIDs: [before[1].id], makeBackup: false)

        #expect(store.lastError == nil)
        #expect(store.state.pages[0] == before[0])
        #expect(store.state.pages[2] == before[2])
        let pdf = try #require(PDFDocument(url: file))
        #expect(pdf.pageCount == 3)
        for index in 0..<3 {
            let box = try #require(pdf.page(at: index)).bounds(for: .cropBox)
            #expect(box.size == CGSize(width: 400, height: index == 1 ? 300 : 600))
        }
    }

    @Test func anEmptySelectionWritesNothing() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("scan.png")
        writeSplitPNG(size: CGSize(width: 400, height: 600), to: file)
        let original = try Data(contentsOf: file)
        let store = DocumentStore()
        await store.openFolder(folder)
        store.setCrop(topHalf, forPageID: store.state.pages[0].id)
        let before = store.state
        await store.applyToOriginals(pageIDs: [], makeBackup: true)
        #expect(store.state == before)
        #expect(store.lastApplyResult == nil)
        #expect(try Data(contentsOf: file) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["scan.png"])
    }

    @Test func resetRemovesEveryEditAndSurvivesReopeningWithACommonFormat() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("scan.png")
        writeSplitPNG(size: CGSize(width: 400, height: 600), to: file)
        let original = try Data(contentsOf: file)
        let store = DocumentStore()
        await store.openFolder(folder)
        let id = store.state.pages[0].id
        store.setAspectRatio(AspectRatio(width: 1, height: 1))
        store.rotatePage(id: id, by: 90)
        store.setTilt(3, forPageID: id)
        store.toggleStraightening(forPageID: id)
        store.resetPage(forPageID: id)
        #expect(!OriginalsWriter.isEdited(store.state.pages[0]))
        #expect(store.state.outputRatio(for: store.state.pages[0]) == nil)
        store.saveDocument()

        let reopened = DocumentStore()
        await reopened.openFolder(folder)
        #expect(!OriginalsWriter.isEdited(reopened.state.pages[0]))
        #expect(reopened.state.cropAspectRatio == AspectRatio(width: 1, height: 1))
        await reopened.applyToOriginals(makeBackup: true)
        #expect(reopened.lastApplyResult == nil)
        #expect(try Data(contentsOf: file) == original)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(".id-fit-originals").path))
    }

    @Test func applyingAllKeepsAResetDuplicateOnItsUntouchedSource() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("scan.png")
        writeSplitPNG(size: CGSize(width: 400, height: 600), to: file)
        let original = try Data(contentsOf: file)
        let store = DocumentStore()
        await store.openFolder(folder)
        let id = store.state.pages[0].id
        store.duplicatePage(id: id)
        store.setCrop(topHalf, forPageID: id)
        store.resetPage(forPageID: store.state.pages[1].id)
        let reset = store.state.pages[1]
        await store.applyToOriginals(makeBackup: false)
        #expect(store.state.pages[1] == reset)
        #expect(try Data(contentsOf: file) == original)
        #expect(store.state.pages[0].source.file == "scan-2.png")
        #expect(isRed(try colour(of: folder.appendingPathComponent("scan-2.png"), atRelativeY: 0.5)))
    }

    /// One page of a PDF claimed twice: the file keeps the first framing in
    /// its crop box and stays whole, and the second gets a PDF of its own.
    @Test func aPDFPageFramedTwiceGetsAPDFOfItsOwn() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("doc.pdf")
        writeSplitPDF(size: CGSize(width: 400, height: 600), pages: 3, to: source)

        let first = Page(source: SourceRef(file: "doc.pdf", pdfPage: 1), crop: topHalf)
        let second = Page(source: SourceRef(file: "doc.pdf", pdfPage: 1), crop: bottomHalf)
        let result = try OriginalsWriter.apply(
            pages: [first, second], folder: folder, makeBackup: false
        )

        #expect(result.failures.isEmpty)
        #expect(result.changedFiles == ["doc.pdf"])
        #expect(result.createdFiles == ["doc-2.pdf"])
        #expect(result.newSources[second.id] == SourceRef(file: "doc-2.pdf", pdfPage: 0))

        // The original keeps all three pages, the middle one narrowed.
        let document = try #require(PDFDocument(url: source))
        #expect(document.pageCount == 3)
        let narrowed = try #require(document.page(at: 1)).bounds(for: .cropBox)
        #expect(narrowed.size == CGSize(width: 400, height: 300))
        #expect(narrowed.minY == 300)
        #expect(try #require(document.page(at: 0)).bounds(for: .cropBox).height == 600)

        // The copy is one page, still vector, holding the other half.
        let copy = try #require(PDFDocument(url: folder.appendingPathComponent("doc-2.pdf")))
        #expect(copy.pageCount == 1)
        let box = try #require(copy.page(at: 0)).bounds(for: .cropBox)
        #expect(box.size == CGSize(width: 400, height: 300))
        #expect(isBlue(try renderedColour(of: folder.appendingPathComponent("doc-2.pdf"))))
    }

    /// Renders the middle of a one-page PDF's crop box back to pixels — the
    /// only way to tell a page that says it is cropped from one that is.
    private func renderedColour(of url: URL) throws -> (r: Int, g: Int, b: Int) {
        let document = try #require(CGPDFDocument(url as CFURL))
        let page = try #require(document.page(at: 1))
        let box = page.getBoxRect(.cropBox)
        let width = Int(box.width)
        let height = Int(box.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.translateBy(x: -box.minX, y: -box.minY)
            context.drawPDFPage(page)
        }
        let offset = ((height / 2) * width + width / 2) * 4
        return (Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2]))
    }

    // MARK: - Through the document

    /// The whole of what the user does: duplicate a scan, frame each copy on
    /// its own half, apply — and find two pages, two files, and nothing lost.
    @Test func theDocumentFollowsItsPagesToTheirNewFiles() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        writeSplitPNG(size: CGSize(width: 400, height: 600),
                      to: folder.appendingPathComponent("scan.png"))

        let store = DocumentStore()
        await store.openFolder(folder)
        let original = try #require(store.state.pages.first)
        store.duplicatePage(id: original.id)
        store.setCrop(topHalf, forPageID: store.state.pages[0].id)
        store.setCrop(bottomHalf, forPageID: store.state.pages[1].id)

        await store.applyToOriginals(makeBackup: false)

        #expect(store.lastError == nil)
        #expect(store.state.pages.map(\.source.file) == ["scan.png", "scan-2.png"])
        // The crops are in the files now, so the state must not hold them too.
        #expect(store.state.pages.allSatisfy { $0.crop == nil })

        // Reopening finds two pages, not a third for the file that was made.
        store.saveDocument()
        let reopened = DocumentStore()
        await reopened.openFolder(folder)
        #expect(reopened.state.pages.map(\.source.file) == ["scan.png", "scan-2.png"])
    }
}

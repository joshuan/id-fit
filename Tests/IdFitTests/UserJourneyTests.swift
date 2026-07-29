import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import IdFit

/// The scenario from the README, start to finish: a folder of mismatched
/// scans plus a scanner-produced PDF, ordered, cropped, exported — then
/// reopened on "another computer".
@MainActor
@Suite struct UserJourneyTests {
    private let a4 = 210.0 / 297.0

    private func makeFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("id-fit-journey-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writePNG(size: CGSize, to url: URL) {
        let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        )!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    private func writePDF(size: CGSize, pages: Int, to url: URL) {
        var box = CGRect(origin: .zero, size: size)
        let context = CGContext(url as CFURL, mediaBox: &box, nil)!
        for _ in 0..<pages {
            context.beginPage(mediaBox: &box)
            context.setFillColor(CGColor(red: 0.8, green: 0.8, blue: 0.8, alpha: 1))
            context.fill(box)
            context.endPage()
        }
        context.closePDF()
    }

    /// A passport scanned as a mixture of everything a scanner might produce.
    private func makeMessyScanFolder() throws -> URL {
        let folder = try makeFolder()
        writePNG(size: CGSize(width: 2480, height: 3508), to: folder.appendingPathComponent("scan-1.png"))
        writePNG(size: CGSize(width: 1240, height: 1754), to: folder.appendingPathComponent("scan-2.png"))
        writePNG(size: CGSize(width: 3000, height: 2000), to: folder.appendingPathComponent("scan-10.png"))
        writePDF(size: CGSize(width: 595, height: 842), pages: 3, to: folder.appendingPathComponent("scanner.pdf"))
        try Data("notes".utf8).write(to: folder.appendingPathComponent("readme.txt"))
        return folder
    }

    @Test func fullJourneyFromMessyFolderToUniformPDF() async throws {
        let folder = try makeMessyScanFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        // 1. Open the folder. The PDF is split into pages, the text file is
        //    ignored, and numbering is natural rather than lexicographic.
        let store = DocumentStore()
        await store.openFolder(folder)
        #expect(store.state.pages.map(\.source) == [
            SourceRef(file: "scan-1.png"),
            SourceRef(file: "scan-2.png"),
            SourceRef(file: "scan-10.png"),
            SourceRef(file: "scanner.pdf", pdfPage: 0),
            SourceRef(file: "scanner.pdf", pdfPage: 1),
            SourceRef(file: "scanner.pdf", pdfPage: 2),
        ])

        // 2. Put the pages in the right order.
        store.movePage(id: store.state.pages[2].id, toIndex: 0)
        store.movePage(id: store.state.pages[5].id, toIndex: 1)
        let expectedOrder = store.state.pages.map(\.source)

        // 3. Choose one aspect ratio for the whole document, and rotate the
        //    landscape scan upright.
        store.setAspectRatio(AspectRatio(width: 210, height: 297))
        let landscape = try #require(store.state.pages.first { $0.source.file == "scan-10.png" })
        store.rotatePage(id: landscape.id, by: 90)

        // 4. Frame one page tighter and copy that framing everywhere. This
        //    page was turned a moment ago, so it holds the shape sideways.
        let first = store.state.pages[0]
        let tightened = CropGeometry.resized(
            try #require(first.crop),
            corner: .topLeft,
            toPixelPoint: CGPoint(x: 120, y: 120),
            outputRatio: try #require(store.state.outputRatio(for: first)),
            sourceSize: try #require(store.sourceSizes[first.source]),
            rotation: first.rotation
        )
        store.setCrop(tightened, forPageID: first.id)
        store.applyCropToAllPages(fromPageID: first.id)

        // Every page now exports at the document's shape, whatever its
        // source — upright, or laid sideways where the page was turned.
        for page in store.state.pages {
            let crop = try #require(page.crop)
            let size = try #require(store.sourceSizes[page.source])
            let target = try #require(store.state.outputRatio(for: page))
            #expect(abs(target - a4) < 0.001 || abs(target - 1 / a4) < 0.001)
            #expect(abs(CropGeometry.exportedRatio(crop, sourceSize: size, rotation: page.rotation) - target) < 0.001)
        }

        // 5. Export the PDF.
        let output = folder.deletingLastPathComponent()
            .appendingPathComponent("journey-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: output) }
        await store.exportPDF(to: output, paper: .a4)

        #expect(store.lastError == nil)
        let export = try #require(store.lastExport)
        #expect(export.result.exportedPages == 6)
        #expect(export.result.skippedPages.isEmpty)

        let document = try #require(CGPDFDocument(output as CFURL))
        #expect(document.numberOfPages == 6)
        for index in 1...document.numberOfPages {
            let box = try #require(document.page(at: index)).getBoxRect(.mediaBox)
            // A4, standing up or lying down — the sideways page prints on the
            // same sheet, just turned.
            let upright = abs(box.width - 595.276) < 1 && abs(box.height - 841.89) < 1
            let sideways = abs(box.width - 841.89) < 1 && abs(box.height - 595.276) < 1
            #expect(upright || sideways)
        }

        // 6. Close the app; everything is on disk.
        store.saveImmediately()
        #expect(!store.hasUnsavedChanges)

        // 7. The folder syncs to another computer and is opened there. The
        //    state file must be enough to restore the work exactly.
        let elsewhere = try makeFolder()
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) {
            try FileManager.default.copyItem(
                at: folder.appendingPathComponent(name),
                to: elsewhere.appendingPathComponent(name)
            )
        }

        let synced = DocumentStore()
        await synced.openFolder(elsewhere)
        #expect(synced.state.pages.map(\.source) == expectedOrder)
        #expect(synced.state.cropAspectRatio == AspectRatio(width: 210, height: 297))
        #expect(synced.state.pages.map(\.crop) == store.state.pages.map(\.crop))
        #expect(synced.state.pages.map(\.rotation) == store.state.pages.map(\.rotation))
        #expect(synced.missingSources.isEmpty)
    }

    @Test func stateFileContainsNoAbsolutePaths() async throws {
        let folder = try makeMessyScanFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = DocumentStore()
        await store.openFolder(folder)
        store.setAspectRatio(AspectRatio(width: 85.6, height: 54))
        store.saveImmediately()

        let contents = try String(contentsOf: StateStore.stateFileURL(for: folder), encoding: .utf8)
        #expect(!contents.contains("/"))
        #expect(!contents.contains(folder.lastPathComponent))
        #expect(contents.contains("scan-1.png"))
    }

    @Test func aScanAddedLaterJoinsTheDocumentWithoutDisturbingIt() async throws {
        let folder = try makeMessyScanFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = DocumentStore()
        await store.openFolder(folder)
        store.setAspectRatio(AspectRatio(width: 210, height: 297))
        store.movePage(id: store.state.pages[4].id, toIndex: 0)
        let order = store.state.pages.map(\.source)
        store.saveImmediately()

        // The user goes back to the scanner for one more page.
        writePNG(size: CGSize(width: 800, height: 1200), to: folder.appendingPathComponent("aaa-late.png"))

        let reopened = DocumentStore()
        await reopened.openFolder(folder)

        #expect(reopened.state.pages.map(\.source) == order + [SourceRef(file: "aaa-late.png")])

        // The new page is cropped to the document's ratio straight away —
        // otherwise it would be the one page breaking the uniform export.
        let crop = try #require(reopened.state.pages.last?.crop)
        let size = try #require(reopened.sourceSizes[SourceRef(file: "aaa-late.png")])
        #expect(abs(CropGeometry.exportedRatio(crop, sourceSize: size) - a4) < 0.001)

        // Which also means every page in the document matches.
        for page in reopened.state.pages {
            let pageCrop = try #require(page.crop)
            let pageSize = try #require(reopened.sourceSizes[page.source])
            #expect(abs(CropGeometry.exportedRatio(pageCrop, sourceSize: pageSize, rotation: page.rotation) - a4) < 0.001)
        }
    }
}

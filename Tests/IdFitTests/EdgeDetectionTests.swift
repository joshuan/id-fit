import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import IdFit

/// Runs the real Vision model over synthesized scans — a document sheet on a
/// background, the situation the feature exists for.
@Suite struct EdgeDetectionTests {
    /// Draws a scan: pale background, a darker sheet with text lines on it,
    /// placed at the given normalized position.
    static func scanImage(
        size: CGSize = CGSize(width: 1200, height: 1600),
        document: CGRect,
        tilt: CGFloat = 0
    ) -> CGImage {
        let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.93, green: 0.93, blue: 0.94, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))

        let rect = CGRect(
            x: document.minX * size.width,
            y: document.minY * size.height,
            width: document.width * size.width,
            height: document.height * size.height
        )
        context.saveGState()
        context.translateBy(x: rect.midX, y: rect.midY)
        context.rotate(by: tilt)
        context.translateBy(x: -rect.midX, y: -rect.midY)

        context.setFillColor(CGColor(red: 0.30, green: 0.55, blue: 0.36, alpha: 1))
        context.fill(rect)
        context.setFillColor(CGColor(red: 0.87, green: 0.87, blue: 0.87, alpha: 1))
        let lineHeight = rect.height * 0.03
        for index in 0..<7 {
            let y = rect.maxY - rect.height * 0.15 - CGFloat(index) * rect.height * 0.09
            context.fill(CGRect(x: rect.minX + rect.width * 0.1, y: y,
                                width: rect.width * 0.8, height: lineHeight))
        }
        context.restoreGState()
        return context.makeImage()!
    }

    private func writePNG(_ image: CGImage, to url: URL) {
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        )!
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    private func makeFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("id-fit-edges-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Detection itself

    @Test func findsADocumentOccupyingPartOfTheScan() throws {
        let placement = CGRect(x: 0.2, y: 0.15, width: 0.6, height: 0.7)
        let crop = try #require(DocumentEdgeDetector.detect(in: Self.scanImage(document: placement))).crop

        // Vision measures from the bottom, crops from the top.
        #expect(abs(crop.x - placement.minX) < 0.05)
        #expect(abs(crop.width - placement.width) < 0.05)
        #expect(abs(crop.height - placement.height) < 0.05)
        #expect(abs(crop.y - (1 - placement.maxY)) < 0.05)
    }

    @Test func theSuggestionSitsInsideTheScan() throws {
        for placement in [
            CGRect(x: 0.05, y: 0.05, width: 0.5, height: 0.5),
            CGRect(x: 0.4, y: 0.3, width: 0.55, height: 0.6),
            CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
        ] {
            let crop = try #require(DocumentEdgeDetector.detect(in: Self.scanImage(document: placement))).crop
            #expect(crop.x >= 0)
            #expect(crop.y >= 0)
            #expect(crop.x + crop.width <= 1.0001)
            #expect(crop.y + crop.height <= 1.0001)
        }
    }

    @Test func aTiltedDocumentIsEnclosedByTheSuggestion() throws {
        let placement = CGRect(x: 0.25, y: 0.2, width: 0.5, height: 0.6)
        let straight = try #require(DocumentEdgeDetector.detect(in: Self.scanImage(document: placement))).crop
        let tilted = try #require(
            DocumentEdgeDetector.detect(in: Self.scanImage(document: placement, tilt: 0.06))
        ).crop

        // The upright box around a tilted sheet has to be wider than the sheet.
        #expect(tilted.width > straight.width)
        #expect(tilted.width < 1)
    }

    @Test func aBlankScanYieldsNoSuggestion() throws {
        let context = CGContext(
            data: nil, width: 800, height: 1000, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.95, green: 0.95, blue: 0.95, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 800, height: 1000))

        // Nothing to find, or something covering the whole frame: either way
        // there is no useful suggestion to make.
        #expect(DocumentEdgeDetector.detect(in: context.makeImage()!) == nil)
    }

    // MARK: - How it reaches the document

    @MainActor
    @Test func openingAFolderProposesCropsAndASharedRatio() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        writePNG(Self.scanImage(document: CGRect(x: 0.2, y: 0.15, width: 0.6, height: 0.7)),
                 to: folder.appendingPathComponent("a.png"))
        writePNG(Self.scanImage(document: CGRect(x: 0.3, y: 0.2, width: 0.45, height: 0.55)),
                 to: folder.appendingPathComponent("b.png"))

        let store = DocumentStore()
        await store.openFolder(folder)
        // Detection runs in the background once the folder is open.
        await store.redetectEdgesOnAllPages()

        let ratio = try #require(store.state.cropAspectRatio)
        for page in store.state.pages {
            let crop = try #require(page.crop)
            let size = try #require(store.sourceSizes[page.source])
            // Suggested, and still honouring the one shared ratio.
            #expect(crop.width < 0.95 || crop.height < 0.95)
            #expect(abs(CropGeometry.exportedRatio(crop, sourceSize: size, rotation: page.rotation) - ratio.ratio) < 0.01)
            #expect(page.autoDetected)
        }
    }

    @MainActor
    @Test func detectionDoesNotOverruleACropTheUserMade() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        writePNG(Self.scanImage(document: CGRect(x: 0.2, y: 0.15, width: 0.6, height: 0.7)),
                 to: folder.appendingPathComponent("a.png"))

        let store = DocumentStore()
        await store.openFolder(folder)
        await store.redetectEdgesOnAllPages()
        store.setAspectRatio(AspectRatio(width: 1, height: 1))

        let page = store.state.pages[0]
        let mine = CropGeometry.moved(
            try #require(page.crop),
            byPixels: CGSize(width: 30, height: 30),
            sourceSize: try #require(store.sourceSizes[page.source])
        )
        store.setCrop(mine, forPageID: page.id)

        // Asking again replaces it — that is what the button is for.
        await store.redetectEdges(forPageIDs: [page.id])
        #expect(store.state.pages[0].crop != nil)

        // But the automatic pass on reopening leaves it alone.
        store.saveDocument()
        let reopened = DocumentStore()
        await reopened.openFolder(folder)
        let after = try #require(reopened.state.pages[0].crop)
        #expect(after == store.state.pages[0].crop)
    }

    @MainActor
    @Test func choosingNoCropIsNotUndoneOnReopen() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        writePNG(Self.scanImage(document: CGRect(x: 0.2, y: 0.15, width: 0.6, height: 0.7)),
                 to: folder.appendingPathComponent("a.png"))

        let store = DocumentStore()
        await store.openFolder(folder)
        await store.redetectEdgesOnAllPages()
        #expect(store.state.pages[0].crop != nil)

        // The user decides they want the whole scan after all.
        store.setAspectRatio(nil)
        store.saveDocument()

        let reopened = DocumentStore()
        await reopened.openFolder(folder)
        // Give any stray background pass a chance to misbehave.
        try await Task.sleep(for: .milliseconds(600))

        #expect(reopened.state.cropAspectRatio == nil)
        #expect(reopened.state.pages[0].crop == nil)
    }

    @MainActor
    @Test func aScanAddedLaterGetsItsOwnSuggestion() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        writePNG(Self.scanImage(document: CGRect(x: 0.2, y: 0.15, width: 0.6, height: 0.7)),
                 to: folder.appendingPathComponent("a.png"))

        let store = DocumentStore()
        await store.openFolder(folder)
        await store.redetectEdgesOnAllPages()
        store.saveDocument()

        writePNG(Self.scanImage(document: CGRect(x: 0.3, y: 0.25, width: 0.4, height: 0.5)),
                 to: folder.appendingPathComponent("b.png"))

        let reopened = DocumentStore()
        await reopened.openFolder(folder)
        let late = try #require(reopened.state.pages.first { $0.source.file == "b.png" })
        #expect(!late.autoDetected)

        await reopened.redetectEdges(forPageIDs: [late.id])
        let updated = try #require(reopened.state.pages.first { $0.source.file == "b.png" })
        #expect(updated.autoDetected)
        #expect(updated.crop != nil)
    }

    @Test func oldStateFilesWithoutTheFlagStillLoad() throws {
        let json = """
        {"pages": [{"source": {"file": "a.jpg"}}]}
        """
        let state = try JSONDecoder().decode(ProjectState.self, from: Data(json.utf8))
        #expect(state.pages[0].autoDetected == false)
    }
}

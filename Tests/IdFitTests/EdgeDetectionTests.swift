import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import IdFit

/// Runs the real Vision model over synthesized scans — a document sheet on a
/// background, the situation the feature exists for.
@Suite struct EdgeDetectionTests {
    /// How far a sheet is pushed off true in the fixtures that test for it,
    /// and how close Vision comes to saying so: on these synthesized scans it
    /// reads the lean to within a couple of steps of the tilt grid.
    private static let lean: Double = 3
    private static let tolerance: Double = 0.4

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

    /// Detection proposes a crop per page and nothing document-wide: the shape
    /// of the first scan analysed says nothing about the shape of the next.
    @MainActor
    @Test func explicitDetectionProposesACropShapedLikeEachPagesOwnDocument() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        // One tall document, one wide one.
        writePNG(Self.scanImage(document: CGRect(x: 0.2, y: 0.15, width: 0.6, height: 0.7)),
                 to: folder.appendingPathComponent("a.png"))
        writePNG(Self.scanImage(document: CGRect(x: 0.1, y: 0.32, width: 0.8, height: 0.35)),
                 to: folder.appendingPathComponent("b.png"))

        let store = DocumentStore()
        await store.openFolder(folder)
        #expect(!store.isDetectingEdges)
        #expect(store.state.pages.allSatisfy { !$0.autoDetected && !OriginalsWriter.isEdited($0) })
        // Suggestions start only when the user requests them.
        await store.redetectEdgesOnAllPages()

        #expect(store.state.cropAspectRatio == nil)
        // 720×1120 and 960×560 pixels of a 1200×1600 scan.
        var found: [Double] = []
        for (page, expected) in zip(store.state.pages, [720.0 / 1120, 960.0 / 560]) {
            let crop = try #require(page.crop)
            let size = try #require(store.sourceSizes[page.source])
            #expect(crop.width < 0.95 || crop.height < 0.95)
            #expect(page.autoDetected)
            // Each page framed as its own document is, not squeezed into a
            // shape borrowed from the other one.
            let ratio = CropGeometry.exportedRatio(crop, sourceSize: size, rotation: page.rotation)
            #expect(abs(ratio - expected) < 0.1)
            found.append(ratio)
        }
        #expect(found[1] - found[0] > 0.5)
        // Which way round a page lies only means something against a shared
        // format, so nothing has claimed one.
        #expect(store.state.pages.allSatisfy { !$0.transposedRatio })
    }

    /// A document that has been given a common format keeps it: suggestions
    /// arriving afterwards are refitted to it rather than breaking it.
    @MainActor
    @Test func detectionIntoADocumentWithAFormatRefitsToIt() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        writePNG(Self.scanImage(document: CGRect(x: 0.2, y: 0.15, width: 0.6, height: 0.7)),
                 to: folder.appendingPathComponent("a.png"))
        writePNG(Self.scanImage(document: CGRect(x: 0.1, y: 0.32, width: 0.8, height: 0.35)),
                 to: folder.appendingPathComponent("b.png"))

        let store = DocumentStore()
        await store.openFolder(folder)
        store.setAspectRatio(AspectRatio(width: 210, height: 297))
        await store.redetectEdgesOnAllPages()

        for page in store.state.pages {
            let crop = try #require(page.crop)
            let size = try #require(store.sourceSizes[page.source])
            let target = try #require(store.state.outputRatio(for: page))
            #expect(crop.width < 0.95 || crop.height < 0.95)
            #expect(abs(CropGeometry.exportedRatio(crop, sourceSize: size, rotation: page.rotation) - target) < 0.01)
        }
    }

    /// A sheet lying crooked on the glass is measured, not merely boxed: the
    /// page is turned back by the angle it lies at and framed by the document
    /// rather than by the slivers beside it.
    @MainActor
    @Test func aScanLyingAskewIsOfferedTheAngleThatUprightsIt() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let placement = CGRect(x: 0.2, y: 0.15, width: 0.6, height: 0.7)
        // Drawn in a context counting y upwards, where a clockwise lean is a
        // negative turn.
        let image = Self.scanImage(document: placement, tilt: -Self.lean * .pi / 180)
        writePNG(image, to: folder.appendingPathComponent("a.png"))

        let store = DocumentStore()
        await store.openFolder(folder)
        await store.redetectEdgesOnAllPages()

        let page = store.state.pages[0]
        // The sheet leans clockwise, so the page is turned back the other way.
        #expect(abs(page.tilt - -Self.lean) < Self.tolerance)
        // Nothing carries the angle twice.
        #expect(page.quad == nil)

        let crop = try #require(page.crop)
        #expect(abs(crop.x - placement.minX) < 0.02)
        #expect(abs(crop.y - (1 - placement.maxY)) < 0.02)
        #expect(abs(crop.width - placement.width) < 0.02)
        #expect(abs(crop.height - placement.height) < 0.02)

        // Tighter than the box holding the corners where they lie, which is
        // the whole reason for measuring the angle.
        let boxed = try #require(DocumentEdgeDetector.detect(in: image)).crop
        #expect(crop.width < boxed.width - 0.02)
        #expect(crop.height < boxed.height - 0.01)

        // And the turned rectangle it stands for is inside the scan.
        let size = try #require(store.sourceSizes[page.source])
        let quad = TiltGeometry.derivedQuad(crop: crop, tilt: page.tilt, sourceSize: size)
        #expect(quad.corners.allSatisfy {
            $0.x >= -1e-6 && $0.x <= 1 + 1e-6 && $0.y >= -1e-6 && $0.y <= 1 + 1e-6
        })
    }

    /// The angle is proposed on top of the document's format, not instead of
    /// it: a page still comes out the shape every other page is.
    @MainActor
    @Test func aProposedAngleStillLeavesThePageAtTheSharedFormat() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let placement = CGRect(x: 0.2, y: 0.15, width: 0.6, height: 0.7)
        let image = Self.scanImage(document: placement, tilt: -Self.lean * .pi / 180)
        writePNG(image, to: folder.appendingPathComponent("a.png"))

        let store = DocumentStore()
        await store.openFolder(folder)
        store.setAspectRatio(AspectRatio(width: 210, height: 297))
        await store.redetectEdgesOnAllPages()

        let page = store.state.pages[0]
        #expect(abs(page.tilt - -Self.lean) < Self.tolerance)

        let crop = try #require(page.crop)
        let size = try #require(store.sourceSizes[page.source])
        let target = try #require(store.state.outputRatio(for: page))
        #expect(abs(CropGeometry.exportedRatio(crop, sourceSize: size, rotation: page.rotation) - target) < 0.01)

        // Refitted from the document itself rather than from the box around
        // it, so the page keeps the margin the lean would have added.
        let boxed = try #require(DocumentEdgeDetector.detect(in: image)).crop
        #expect(crop.width * crop.height < boxed.width * boxed.height)
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

        // Reopening leaves it alone.
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
        store.resetCrop(forPageID: store.state.pages[0].id)
        #expect(store.state.pages[0].crop == nil)
        store.saveDocument()

        let reopened = DocumentStore()
        await reopened.openFolder(folder)
        // Give any stray background pass a chance to misbehave.
        try await Task.sleep(for: .milliseconds(600))

        #expect(reopened.state.cropAspectRatio == nil)
        #expect(reopened.state.pages[0].crop == nil)
    }

    @MainActor
    @Test func aScanAddedLaterWaitsForExplicitDetection() async throws {
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
        #expect(!reopened.isDetectingEdges)
        #expect(!OriginalsWriter.isEdited(late))

        await reopened.redetectEdges(forPageIDs: [late.id])
        let updated = try #require(reopened.state.pages.first { $0.source.file == "b.png" })
        #expect(updated.autoDetected)
        #expect(updated.crop != nil)
    }

    @MainActor
    @Test func openingAFolderDoesNotDetectOrWriteAnything() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("a.png")
        writePNG(Self.scanImage(document: CGRect(x: 0.2, y: 0.15, width: 0.6, height: 0.7)), to: file)
        let original = try Data(contentsOf: file)

        let store = DocumentStore()
        await store.openFolder(folder)
        let pages = store.state.pages
        // Allow a stray background task a chance to start.
        try await Task.sleep(for: .milliseconds(100))
        #expect(!store.isDetectingEdges)
        #expect(store.state.pages == pages)
        #expect(pages.allSatisfy { !$0.autoDetected && !OriginalsWriter.isEdited($0) })
        #expect(try Data(contentsOf: file) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["a.png"])
    }

    @MainActor
    @Test func detectionOnlyChangesTheSelectedPages() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = Self.scanImage(document: CGRect(x: 0.2, y: 0.15, width: 0.6, height: 0.7))
        for name in ["a.png", "b.png", "c.png"] { writePNG(image, to: folder.appendingPathComponent(name)) }
        let store = DocumentStore()
        await store.openFolder(folder)
        let pages = store.state.pages
        store.setTilt(2, forPageID: pages[1].id)
        let unselected = store.state.pages[1]

        await store.redetectEdges(forPageIDs: [pages[0].id, pages[2].id])

        #expect(store.state.pages[0].crop != nil)
        #expect(store.state.pages[2].crop != nil)
        #expect(store.state.pages[0].autoDetected)
        #expect(store.state.pages[2].autoDetected)
        #expect(store.state.pages[1] == unselected)
    }

    @MainActor
    @Test func resetRejectsAnInFlightDetectionForOnlyThatPage() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = Self.scanImage(document: CGRect(x: 0.2, y: 0.15, width: 0.6, height: 0.7))
        for name in ["a.png", "b.png"] { writePNG(image, to: folder.appendingPathComponent(name)) }
        let store = DocumentStore()
        await store.openFolder(folder)
        let id = store.state.pages[0].id
        let task = Task { await store.redetectEdgesOnAllPages() }
        await Task.yield()
        #expect(store.isDetectingEdges)
        store.resetPage(forPageID: id)
        await task.value

        #expect(!OriginalsWriter.isEdited(store.state.pages[0]))
        #expect(store.state.pages[1].crop != nil)
        // Cached corners must be gone too.
        store.setStraightenByDefault(true)
        #expect(store.state.pages[0].quad == nil)
        // A fresh explicit request is still allowed.
        await store.redetectEdges(forPageIDs: [id])
        #expect(store.state.pages[0].crop != nil)
    }

    @Test func oldStateFilesWithoutTheFlagStillLoad() throws {
        let json = """
        {"pages": [{"source": {"file": "a.jpg"}}]}
        """
        let state = try JSONDecoder().decode(ProjectState.self, from: Data(json.utf8))
        #expect(state.pages[0].autoDetected == false)
    }
}

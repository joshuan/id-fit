import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import IdFit

/// A fine turn is checked the way every other framing change is: a scan with a
/// known angle in it is exported, rendered back and sampled.
@Suite struct TiltTests {
    private let red = CGColor(red: 1, green: 0, blue: 0, alpha: 1)
    private let blue = CGColor(red: 0, green: 0, blue: 1, alpha: 1)

    /// The document as it lies in the fixtures below.
    private let scan = CGSize(width: 1200, height: 1200)
    private let document = CGSize(width: 600, height: 800)
    /// Nearly filling the scan, which is what edge detection needs before it
    /// will call something the document.
    private let filling = CGSize(width: 840, height: 1040)
    private let lean: Double = 5

    /// The upright crop that frames the document once the lean is taken out.
    private var framing: CropRect {
        CropRect(
            x: (scan.width - document.width) / 2 / scan.width,
            y: (scan.height - document.height) / 2 / scan.height,
            width: document.width / scan.width,
            height: document.height / scan.height
        )
    }

    // MARK: - Fixtures

    private func makeFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("id-fit-tilt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A document lying off true by `degrees` clockwise on a dark background:
    /// red top half, blue bottom.
    private func leaningScan(degrees: Double, size document: CGSize) -> CGImage {
        let context = CGContext(
            data: nil, width: Int(scan.width), height: Int(scan.height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: scan))

        context.translateBy(x: scan.width / 2, y: scan.height / 2)
        // This context counts y upwards, so a clockwise lean is a negative
        // turn and the top half is the one at the high end of y.
        context.rotate(by: -degrees * .pi / 180)
        context.setFillColor(blue)
        context.fill(CGRect(
            x: -document.width / 2, y: -document.height / 2,
            width: document.width, height: document.height / 2
        ))
        context.setFillColor(red)
        context.fill(CGRect(
            x: -document.width / 2, y: 0,
            width: document.width, height: document.height / 2
        ))
        return context.makeImage()!
    }

    private func writeLeaningScan(degrees: Double, size: CGSize? = nil, to url: URL) {
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        )!
        CGImageDestinationAddImage(destination, leaningScan(degrees: degrees, size: size ?? document), nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    // MARK: - Reading the result back

    private struct RenderedPage {
        let width: Int
        let height: Int
        let pixels: [UInt8]

        func color(x: Double, y: Double) -> (r: Int, g: Int, b: Int) {
            let px = min(max(Int(x * Double(width)), 0), width - 1)
            let py = min(max(Int(y * Double(height)), 0), height - 1)
            let offset = (py * width + px) * 4
            return (Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2]))
        }

        func isRed(x: Double, y: Double) -> Bool {
            let c = color(x: x, y: y)
            return c.r > 170 && c.b < 90
        }

        func isBlue(x: Double, y: Double) -> Bool {
            let c = color(x: x, y: y)
            return c.b > 170 && c.r < 90
        }
    }

    private func render(_ url: URL) throws -> RenderedPage {
        let pdf = try #require(CGPDFDocument(url as CFURL))
        let page = try #require(pdf.page(at: 1))
        let box = page.getBoxRect(.mediaBox)
        let width = 300
        let height = max(1, Int(Double(width) * box.height / box.width))

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: Double(width) / box.width, y: Double(height) / box.height)
            context.translateBy(x: -box.minX, y: -box.minY)
            context.drawPDFPage(page)
        }
        return RenderedPage(width: width, height: height, pixels: pixels)
    }

    /// Opens the folder with the background analysis already settled, so
    /// nothing arrives later and undoes the framing the test sets.
    @MainActor
    private func openSettled(_ folder: URL) async -> DocumentStore {
        let store = DocumentStore()
        await store.openFolder(folder)
        await store.redetectEdgesOnAllPages()
        return store
    }

    // MARK: - Export

    @MainActor
    @Test func aTiltedPageIsExportedUpright() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        writeLeaningScan(degrees: lean, to: folder.appendingPathComponent("a.png"))

        let store = await openSettled(folder)
        let id = store.state.pages[0].id
        store.setCrop(framing, forPageID: id)
        // The page leans clockwise, so it is turned back the other way.
        store.setTilt(-lean, forPageID: id)
        #expect(store.state.pages[0].crop == framing)

        let output = folder.deletingLastPathComponent()
            .appendingPathComponent("tilt-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: output) }
        await store.exportPDF(to: output, paper: .fitContent)
        #expect(store.lastError == nil)

        let rendered = try render(output)
        // The document's own shape, not the scan's.
        #expect(abs(Double(rendered.width) / Double(rendered.height) - 0.75) < 0.02)
        // And its halves sit level: were the lean still in it, one side of a
        // row would be document and the other the dark background.
        for x in [0.25, 0.5, 0.75] {
            #expect(rendered.isRed(x: x, y: 0.15))
            #expect(rendered.isRed(x: x, y: 0.35))
            #expect(rendered.isBlue(x: x, y: 0.65))
            #expect(rendered.isBlue(x: x, y: 0.85))
        }
    }

    @MainActor
    @Test func aQuarterTurnAndATiltComposeIntoOne() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        writeLeaningScan(degrees: lean, to: folder.appendingPathComponent("a.png"))

        let store = await openSettled(folder)
        let id = store.state.pages[0].id
        store.rotatePage(id: id, by: 90)
        // Crops are stored on the unrotated scan, and so is the tilt.
        store.setCrop(framing, forPageID: id)
        store.setTilt(-lean, forPageID: id)

        let output = folder.deletingLastPathComponent()
            .appendingPathComponent("tilt-turned-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: output) }
        await store.exportPDF(to: output, paper: .fitContent)
        #expect(store.lastError == nil)

        let rendered = try render(output)
        // Turning clockwise moves the document's top edge to the right.
        #expect(rendered.width > rendered.height)
        for y in [0.25, 0.5, 0.75] {
            #expect(rendered.isRed(x: 0.85, y: y))
            #expect(rendered.isBlue(x: 0.15, y: y))
        }
    }

    @Test func aTiltedPDFPageIsRasterizedWhileAnUntiltedOneStaysVector() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let url = folder.appendingPathComponent("scan.pdf")
        var box = CGRect(origin: .zero, size: CGSize(width: 400, height: 600))
        let context = CGContext(url as CFURL, mediaBox: &box, nil)!
        context.beginPage(mediaBox: &box)
        context.setFillColor(blue)
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        context.setFillColor(red)
        context.fill(CGRect(x: 0, y: 300, width: 400, height: 300))
        context.endPage()
        context.closePDF()

        let page = Page(source: SourceRef(file: "scan.pdf", pdfPage: 0))
        var tilted = page
        tilted.tilt = 3

        func isVector(_ content: PageRenderer.Content?) -> Bool {
            if case .pdfPage = content { return true }
            return false
        }
        #expect(isVector(PageRenderer.content(for: page, in: folder)))
        // A turn cannot be expressed in vector page content.
        #expect(!isVector(PageRenderer.content(for: tilted, in: folder)))
    }

    // MARK: - The document file

    @Test func anUntouchedDocumentGainsNoTiltField() throws {
        let state = ProjectState(pages: [Page(
            source: SourceRef(file: "a.jpg"),
            crop: CropRect(x: 0, y: 0, width: 0.5, height: 0.5)
        )])
        let json = try #require(
            JSONSerialization.jsonObject(with: try JSONEncoder().encode(state)) as? [String: Any]
        )
        let pages = try #require(json["pages"] as? [[String: Any]])

        #expect(pages[0]["tilt"] == nil)
        // Everything the document used to hold is still written.
        for key in ["id", "source", "rotation", "crop", "autoDetected", "transposedRatio"] {
            #expect(pages[0][key] != nil, "\(key) went missing")
        }
        // And an absent corner set is still absent rather than null.
        #expect(pages[0].keys.contains("quad") == false)
    }

    @Test func aTiltIsWrittenOutAndReadBack() throws {
        var page = Page(source: SourceRef(file: "a.jpg"))
        page.tilt = -1.4
        let data = try JSONEncoder().encode(ProjectState(pages: [page]))

        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let pages = try #require(json["pages"] as? [[String: Any]])
        #expect(pages[0]["tilt"] as? Double == -1.4)

        let back = try JSONDecoder().decode(ProjectState.self, from: data)
        #expect(back.pages[0].tilt == -1.4)
    }

    @Test func documentsWrittenBeforeTiltExistedStillOpen() throws {
        let json = """
        {"pages": [{"source": {"file": "a.jpg"}, "rotation": 90}]}
        """
        let state = try JSONDecoder().decode(ProjectState.self, from: Data(json.utf8))
        #expect(state.pages[0].tilt == 0)
        #expect(state.pages[0].rotation == 90)
    }

    @MainActor
    @Test func aTiltSurvivesSavingAndReopening() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        writeLeaningScan(degrees: lean, to: folder.appendingPathComponent("a.png"))

        let store = await openSettled(folder)
        store.setCrop(framing, forPageID: store.state.pages[0].id)
        store.setTilt(-3.4, forPageID: store.state.pages[0].id)
        store.saveDocument()

        let reopened = DocumentStore()
        await reopened.openFolder(folder)
        #expect(reopened.state.pages[0].tilt == store.state.pages[0].tilt)
        #expect(abs(reopened.state.pages[0].tilt - -3.4) < 1e-9)
        #expect(reopened.state.pages[0].crop == framing)
    }

    // MARK: - Through the store

    @MainActor
    @Test func aTiltIsClampedAndSnappedToTheStep() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        writeLeaningScan(degrees: lean, to: folder.appendingPathComponent("a.png"))

        let store = await openSettled(folder)
        let id = store.state.pages[0].id

        store.setTilt(1.37, forPageID: id)
        #expect(abs(store.state.pages[0].tilt - 1.4) < 1e-9)

        store.setTilt(-120, forPageID: id)
        #expect(abs(store.state.pages[0].tilt - -45) < 1e-9)
    }

    @MainActor
    @Test func tiltingAPageKeepsItsCropWithinTheScan() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        writeLeaningScan(degrees: lean, to: folder.appendingPathComponent("a.png"))

        let store = await openSettled(folder)
        let id = store.state.pages[0].id
        // A crop filling the whole scan cannot survive a turn unshrunk.
        store.setCrop(CropRect(x: 0, y: 0, width: 1, height: 1), forPageID: id)
        store.setTilt(30, forPageID: id)

        let page = store.state.pages[0]
        let crop = try #require(page.crop)
        #expect(crop.width < 0.75)
        let quad = TiltGeometry.derivedQuad(crop: crop, tilt: page.tilt, sourceSize: scan)
        #expect(quad.corners.allSatisfy { $0.x >= -1e-6 && $0.x <= 1 + 1e-6 })
        #expect(quad.corners.allSatisfy { $0.y >= -1e-6 && $0.y <= 1 + 1e-6 })
    }

    @MainActor
    @Test func straighteningAbsorbsTheTiltInsteadOfStackingOnIt() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        writeLeaningScan(degrees: lean, to: folder.appendingPathComponent("a.png"))

        let store = await openSettled(folder)
        let id = store.state.pages[0].id
        store.setCrop(framing, forPageID: id)
        store.setTilt(-lean, forPageID: id)

        store.toggleStraightening(forPageID: id)
        #expect(store.state.pages[0].tilt == 0)
        // The corners are the tilted crop, not the upright box around it.
        let quad = try #require(store.state.pages[0].quad)
        let expected = TiltGeometry.derivedQuad(crop: framing, tilt: -lean, sourceSize: scan)
        #expect(abs(quad.topLeft.x - expected.topLeft.x) < 1e-9)
        #expect(abs(quad.topLeft.y - expected.topLeft.y) < 1e-9)
        #expect(abs(quad.bottomRight.x - expected.bottomRight.x) < 1e-9)
        #expect(quad != DocumentQuad(framing))

        // Coming back out leaves the page framed and upright.
        store.toggleStraightening(forPageID: id)
        #expect(store.state.pages[0].tilt == 0)
        #expect(store.state.pages[0].quad == nil)
        #expect(store.state.pages[0].crop != nil)
    }

    @MainActor
    @Test func aStraightenedPageHasNoTiltToSet() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        writeLeaningScan(degrees: lean, to: folder.appendingPathComponent("a.png"))

        let store = await openSettled(folder)
        let id = store.state.pages[0].id
        store.toggleStraightening(forPageID: id)
        #expect(store.state.pages[0].quad != nil)

        store.setTilt(5, forPageID: id)
        #expect(store.state.pages[0].tilt == 0)
    }

    @MainActor
    @Test func aFreshDetectionReplacesTheTiltItWasNotMeasuredWith() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        // Big enough in the frame that detection will offer a crop at all.
        writeLeaningScan(degrees: lean, size: filling, to: folder.appendingPathComponent("a.png"))

        let store = await openSettled(folder)
        let id = store.state.pages[0].id
        #expect(store.state.pages[0].crop != nil)
        // A turn that has nothing to do with the way this scan lies.
        store.setTilt(20, forPageID: id)

        await store.redetectEdgesOnAllPages()
        // Detection measured the scan as it lies, so the angle that survives
        // it is the one it found and not the one that was there before.
        #expect(abs(store.state.pages[0].tilt - -lean) < 0.5)
    }

    @MainActor
    @Test func aDetectionThatFindsNoLeanClearsTheTiltUnderIt() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        writeLeaningScan(degrees: 0, size: filling, to: folder.appendingPathComponent("a.png"))

        let store = await openSettled(folder)
        #expect(store.state.pages[0].crop != nil)
        #expect(store.state.pages[0].tilt == 0)
        store.setTilt(-3.4, forPageID: store.state.pages[0].id)

        await store.redetectEdgesOnAllPages()
        // Nothing was proposed, so the older turn — which would have put the
        // new crop askew — goes.
        #expect(store.state.pages[0].tilt == 0)
    }
}

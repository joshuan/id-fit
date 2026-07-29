import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import IdFit

/// Straightening is checked by photographing a known pattern out of true and
/// asserting it comes back square.
@Suite struct StraighteningTests {
    private let red = CGColor(red: 1, green: 0, blue: 0, alpha: 1)
    private let blue = CGColor(red: 0, green: 0, blue: 1, alpha: 1)

    private func makeFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("id-fit-straighten-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A document lying askew on a dark background: red top half, blue bottom.
    private func skewedScan(size: CGSize, quad: DocumentQuad) -> CGImage {
        let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))

        func point(_ corner: CGPoint) -> CGPoint {
            CGPoint(x: corner.x * size.width, y: (1 - corner.y) * size.height)
        }
        let topLeft = point(quad.topLeft)
        let topRight = point(quad.topRight)
        let bottomRight = point(quad.bottomRight)
        let bottomLeft = point(quad.bottomLeft)
        func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
            CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        }
        let leftMiddle = midpoint(topLeft, bottomLeft)
        let rightMiddle = midpoint(topRight, bottomRight)

        context.setFillColor(red)
        context.beginPath()
        context.move(to: topLeft)
        context.addLine(to: topRight)
        context.addLine(to: rightMiddle)
        context.addLine(to: leftMiddle)
        context.closePath()
        context.fillPath()

        context.setFillColor(blue)
        context.beginPath()
        context.move(to: leftMiddle)
        context.addLine(to: rightMiddle)
        context.addLine(to: bottomRight)
        context.addLine(to: bottomLeft)
        context.closePath()
        context.fillPath()

        return context.makeImage()!
    }

    private func sample(_ image: CGImage, x: Double, y: Double) -> (r: Int, g: Int, b: Int) {
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
        let px = min(max(Int(x * Double(width)), 0), width - 1)
        let py = min(max(Int(y * Double(height)), 0), height - 1)
        let offset = (py * width + px) * 4
        return (Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2]))
    }

    /// A document photographed from one side: the far edge is shorter.
    private let tilted = DocumentQuad(
        topLeft: CGPoint(x: 0.30, y: 0.18),
        topRight: CGPoint(x: 0.74, y: 0.12),
        bottomRight: CGPoint(x: 0.82, y: 0.86),
        bottomLeft: CGPoint(x: 0.22, y: 0.80)
    )

    // MARK: - The correction itself

    @Test func aSkewedDocumentComesBackSquare() throws {
        let size = CGSize(width: 1000, height: 1200)
        let image = skewedScan(size: size, quad: tilted)

        let corrected = try #require(
            PerspectiveCorrector.straighten(image, quad: tilted, targetAspect: 210.0 / 297.0)
        )

        // The halves now meet on a level line: sampling left and right at the
        // same height must give the same colour, which is what "not skewed"
        // means.
        for y in [0.2, 0.35] {
            for x in [0.1, 0.5, 0.9] {
                let colour = sample(corrected, x: x, y: y)
                #expect(colour.r > 180 && colour.b < 80)
            }
        }
        for y in [0.65, 0.8] {
            for x in [0.1, 0.5, 0.9] {
                let colour = sample(corrected, x: x, y: y)
                #expect(colour.b > 180 && colour.r < 80)
            }
        }
    }

    @Test func theResultHasExactlyTheRequestedShape() throws {
        let image = skewedScan(size: CGSize(width: 1000, height: 1200), quad: tilted)
        for aspect in [210.0 / 297.0, 88.0 / 125.0, 85.6 / 54.0] {
            let corrected = try #require(
                PerspectiveCorrector.straighten(image, quad: tilted, targetAspect: aspect)
            )
            let produced = Double(corrected.width) / Double(corrected.height)
            #expect(abs(produced - aspect) < 0.01)
        }
    }

    @Test func straighteningKeepsTheDocumentAtFullSize() throws {
        let image = skewedScan(size: CGSize(width: 2000, height: 2400), quad: tilted)
        let corrected = try #require(
            PerspectiveCorrector.straighten(image, quad: tilted, targetAspect: 210.0 / 297.0)
        )
        // Roughly the document's own pixel count, not a downscaled preview.
        #expect(corrected.width > 900)
    }

    @Test func skewMeasuresHowFarFromSquareAQuadIs() {
        let square = DocumentQuad(CropRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8))
        #expect(square.skew < 0.0001)
        #expect(tilted.skew > PerspectiveCorrector.negligibleSkew)
    }

    @Test func aQuadKnowsTheBoxAroundIt() {
        let box = tilted.boundingCrop
        #expect(abs(box.x - 0.22) < 0.0001)
        #expect(abs(box.y - 0.12) < 0.0001)
        #expect(abs(box.x + box.width - 0.82) < 0.0001)
        #expect(abs(box.y + box.height - 0.86) < 0.0001)
    }

    @Test func turningAQuadMovesItsCornersRound() {
        let quad = DocumentQuad(
            topLeft: CGPoint(x: 0.1, y: 0.2),
            topRight: CGPoint(x: 0.8, y: 0.1),
            bottomRight: CGPoint(x: 0.9, y: 0.7),
            bottomLeft: CGPoint(x: 0.2, y: 0.8)
        )
        for angle in [90, 180, 270] {
            let there = DocumentQuadGeometry.rotated(quad, by: angle)
            let back = DocumentQuadGeometry.rotated(there, by: -angle)
            #expect(abs(back.topLeft.x - quad.topLeft.x) < 0.0001)
            #expect(abs(back.topLeft.y - quad.topLeft.y) < 0.0001)
            #expect(abs(back.bottomRight.x - quad.bottomRight.x) < 0.0001)
        }
        // A quarter turn clockwise sends the top-left corner to the top-right.
        let turned = DocumentQuadGeometry.rotated(quad, by: 90)
        #expect(abs(turned.topRight.x - (1 - quad.topLeft.y)) < 0.0001)
        #expect(abs(turned.topRight.y - quad.topLeft.x) < 0.0001)
    }

    // MARK: - Through the app

    @MainActor
    @Test func straighteningCanBeTurnedOffForTheWholeDocument() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = skewedScan(size: CGSize(width: 1000, height: 1200), quad: tilted)
        let destination = CGImageDestinationCreateWithURL(
            folder.appendingPathComponent("a.png") as CFURL, UTType.png.identifier as CFString, 1, nil
        )!
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))

        let store = DocumentStore()
        await store.openFolder(folder)
        await store.redetectEdgesOnAllPages()

        // Off unless asked for: a locked rectangle is the predictable default.
        #expect(store.state.pages[0].quad == nil)
        #expect(store.state.pages[0].crop != nil)

        // Switching it on uses the corners detection already found.
        store.setStraightenByDefault(true)
        #expect(store.state.pages[0].quad != nil)

        store.setStraightenByDefault(false)
        #expect(store.state.pages[0].quad == nil)
        // Turning it off still leaves the document framed.
        #expect(store.state.pages[0].crop != nil)
    }

    @MainActor
    @Test func straighteningCanBeTurnedOffForOnePage() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = skewedScan(size: CGSize(width: 1000, height: 1200), quad: tilted)
        let destination = CGImageDestinationCreateWithURL(
            folder.appendingPathComponent("a.png") as CFURL, UTType.png.identifier as CFString, 1, nil
        )!
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))

        let store = DocumentStore()
        await store.openFolder(folder)
        await store.redetectEdgesOnAllPages()
        let id = store.state.pages[0].id
        #expect(store.state.pages[0].quad == nil)

        store.toggleStraightening(forPageID: id)
        #expect(store.state.pages[0].quad != nil)

        store.toggleStraightening(forPageID: id)
        #expect(store.state.pages[0].quad == nil)

        store.toggleStraightening(forPageID: id)
        #expect(store.state.pages[0].quad != nil)

        // And it survives a reopen.
        store.saveImmediately()
        let reopened = DocumentStore()
        await reopened.openFolder(folder)
        #expect(reopened.state.pages[0].quad != nil)
    }

    @MainActor
    @Test func aStraightenedPageIsExportedSquare() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = skewedScan(size: CGSize(width: 1000, height: 1200), quad: tilted)
        let destination = CGImageDestinationCreateWithURL(
            folder.appendingPathComponent("a.png") as CFURL, UTType.png.identifier as CFString, 1, nil
        )!
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))

        let store = DocumentStore()
        await store.openFolder(folder)
        await store.redetectEdgesOnAllPages()
        store.setAspectRatio(AspectRatio(width: 210, height: 297))
        store.setQuad(tilted, forPageID: store.state.pages[0].id)

        let output = folder.deletingLastPathComponent()
            .appendingPathComponent("straight-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: output) }
        await store.exportPDF(to: output, paper: .fitContent)
        #expect(store.lastError == nil)

        let document = try #require(CGPDFDocument(output as CFURL))
        let page = try #require(document.page(at: 1))
        let box = page.getBoxRect(.mediaBox)
        #expect(abs(box.width / box.height - 210.0 / 297.0) < 0.02)

        // Render it back: the halves must sit level, as on the straightened
        // document rather than the tilted photograph.
        let width = 300
        let height = Int(Double(width) / (box.width / box.height))
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
        func colour(x: Double, y: Double) -> (r: Int, g: Int, b: Int) {
            let px = min(max(Int(x * Double(width)), 0), width - 1)
            let py = min(max(Int(y * Double(height)), 0), height - 1)
            let offset = (py * width + px) * 4
            return (Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2]))
        }
        for x in [0.15, 0.5, 0.85] {
            #expect(colour(x: x, y: 0.25).r > 170)
            #expect(colour(x: x, y: 0.75).b > 170)
        }
    }

    @Test func oldStateFilesWithoutCornersStillLoad() throws {
        let json = """
        {"pages": [{"source": {"file": "a.jpg"}}]}
        """
        let state = try JSONDecoder().decode(ProjectState.self, from: Data(json.utf8))
        #expect(state.pages[0].quad == nil)
        #expect(!state.straightenByDefault)
    }
}

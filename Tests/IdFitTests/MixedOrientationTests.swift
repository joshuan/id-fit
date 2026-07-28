import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import IdFit

/// A passport photographed partly upright and partly sideways: every page has
/// to come out the same shape, but not all of them the same way round.
@MainActor
@Suite struct MixedOrientationTests {
    private let a4 = 210.0 / 297.0

    private func makeFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("id-fit-mixed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A photo of a document lying on a table, in the given orientation.
    private func writeScan(
        name: String,
        canvas: CGSize,
        document: CGRect,
        in folder: URL
    ) {
        let context = CGContext(
            data: nil, width: Int(canvas.width), height: Int(canvas.height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.55, green: 0.38, blue: 0.20, alpha: 1))
        context.fill(CGRect(origin: .zero, size: canvas))

        let rect = CGRect(
            x: document.minX * canvas.width, y: document.minY * canvas.height,
            width: document.width * canvas.width, height: document.height * canvas.height
        )
        context.setFillColor(CGColor(red: 0.93, green: 0.92, blue: 0.88, alpha: 1))
        context.fill(rect)
        context.setFillColor(CGColor(red: 0.6, green: 0.6, blue: 0.62, alpha: 1))
        for index in 0..<6 {
            let y = rect.maxY - rect.height * 0.14 - CGFloat(index) * rect.height * 0.12
            context.fill(CGRect(x: rect.minX + rect.width * 0.12, y: y,
                                width: rect.width * 0.76, height: rect.height * 0.035))
        }

        let destination = CGImageDestinationCreateWithURL(
            folder.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil
        )!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    private func exported(_ page: Page, in store: DocumentStore) throws -> Double {
        let crop = try #require(page.crop)
        let size = try #require(store.sourceSizes[page.source])
        return CropGeometry.exportedRatio(crop, sourceSize: size, rotation: page.rotation)
    }

    @Test func everyPageKeepsTheSharedShapeUprightOrSideways() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        // A tall single page, then a wide open spread.
        writeScan(name: "1-upright.png", canvas: CGSize(width: 1200, height: 1600),
                  document: CGRect(x: 0.22, y: 0.15, width: 0.56, height: 0.7), in: folder)
        writeScan(name: "2-sideways.png", canvas: CGSize(width: 1600, height: 1200),
                  document: CGRect(x: 0.14, y: 0.2, width: 0.72, height: 0.55), in: folder)

        let store = DocumentStore()
        await store.openFolder(folder)
        await store.redetectEdgesOnAllPages()

        let ratio = try #require(store.state.cropAspectRatio?.ratio)
        for page in store.state.pages {
            let target = try #require(store.state.outputRatio(for: page))
            // One shape for the document, held whichever way the page needs.
            #expect(abs(target - ratio) < 0.001 || abs(target - 1 / ratio) < 0.001)
            #expect(abs(try exported(page, in: store) - target) < 0.01)
        }

        // The two pages really did end up the other way round from each other.
        let orientations = Set(store.state.pages.map(\.transposedRatio))
        #expect(orientations.count == 2)
    }

    @Test func aPageCanBeTurnedSidewaysByHand() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        writeScan(name: "a.png", canvas: CGSize(width: 1200, height: 1600),
                  document: CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6), in: folder)

        let store = DocumentStore()
        await store.openFolder(folder)
        store.setAspectRatio(AspectRatio(width: 210, height: 297))
        let id = store.state.pages[0].id
        #expect(abs(try exported(store.state.pages[0], in: store) - a4) < 0.001)

        store.toggleCropOrientation(forPageID: id)
        #expect(abs(try exported(store.state.pages[0], in: store) - 1 / a4) < 0.001)

        store.toggleCropOrientation(forPageID: id)
        #expect(abs(try exported(store.state.pages[0], in: store) - a4) < 0.001)
    }

    @Test func orientationSurvivesReopeningAndRatioChanges() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        writeScan(name: "a.png", canvas: CGSize(width: 1200, height: 1600),
                  document: CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6), in: folder)
        writeScan(name: "b.png", canvas: CGSize(width: 1600, height: 1200),
                  document: CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6), in: folder)

        let store = DocumentStore()
        await store.openFolder(folder)
        store.setAspectRatio(AspectRatio(width: 210, height: 297))
        store.toggleCropOrientation(forPageID: store.state.pages[1].id)
        store.saveImmediately()

        let reopened = DocumentStore()
        await reopened.openFolder(folder)
        #expect(reopened.state.pages[0].transposedRatio == false)
        #expect(reopened.state.pages[1].transposedRatio == true)

        // Picking a different shape keeps each page's own orientation.
        reopened.setAspectRatio(AspectRatio(width: 85.6, height: 54))
        let idCard = 85.6 / 54.0
        #expect(abs(try exported(reopened.state.pages[0], in: reopened) - idCard) < 0.001)
        #expect(abs(try exported(reopened.state.pages[1], in: reopened) - 1 / idCard) < 0.001)
    }

    @Test func sidewaysPagesExportOnTheSameSheetTurned() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        writeScan(name: "a.png", canvas: CGSize(width: 1200, height: 1600),
                  document: CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6), in: folder)
        writeScan(name: "b.png", canvas: CGSize(width: 1600, height: 1200),
                  document: CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6), in: folder)

        let store = DocumentStore()
        await store.openFolder(folder)
        store.setAspectRatio(AspectRatio(width: 210, height: 297))
        store.toggleCropOrientation(forPageID: store.state.pages[1].id)

        let output = folder.deletingLastPathComponent()
            .appendingPathComponent("mixed-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: output) }
        await store.exportPDF(to: output, paper: .a4)

        let document = try #require(CGPDFDocument(output as CFURL))
        #expect(document.numberOfPages == 2)
        let first = try #require(document.page(at: 1)).getBoxRect(.mediaBox)
        let second = try #require(document.page(at: 2)).getBoxRect(.mediaBox)

        #expect(first.height > first.width)   // upright
        #expect(second.width > second.height) // turned
        // Same sheet either way.
        #expect(abs(first.width - second.height) < 1)
        #expect(abs(first.height - second.width) < 1)
    }
}

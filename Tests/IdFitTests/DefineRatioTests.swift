import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import IdFit

/// Drawing a rectangle on one page is how a document that matches no preset
/// gets its ratio.
@MainActor
@Suite struct DefineRatioTests {
    private func makeFolder(sizes: [(name: String, size: CGSize)]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("id-fit-define-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for entry in sizes {
            let context = CGContext(
                data: nil, width: Int(entry.size.width), height: Int(entry.size.height),
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            let destination = CGImageDestinationCreateWithURL(
                folder.appendingPathComponent(entry.name) as CFURL,
                UTType.png.identifier as CFString, 1, nil
            )!
            CGImageDestinationAddImage(destination, context.makeImage()!, nil)
            #expect(CGImageDestinationFinalize(destination))
        }
        return folder
    }

    private let mixed: [(name: String, size: CGSize)] = [
        ("a.png", CGSize(width: 2000, height: 1000)),
        ("b.png", CGSize(width: 900, height: 1200)),
    ]

    @Test func drawnRectangleBecomesTheDocumentRatio() async throws {
        let folder = try makeFolder(sizes: mixed)
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = DocumentStore()
        await store.openFolder(folder)
        #expect(store.state.cropAspectRatio == nil)

        // Half the width, a quarter of the height of a 2000×1000 page →
        // 1000×250 pixels, i.e. 4:1.
        let drawn = CropRect(x: 0.25, y: 0.3, width: 0.5, height: 0.25)
        let first = store.state.pages[0]
        store.defineAspectRatio(fromDrawnCrop: drawn, onPageID: first.id)

        let ratio = try #require(store.state.cropAspectRatio)
        #expect(abs(ratio.ratio - 4) < 0.001)

        // The page it was drawn on keeps exactly that framing.
        #expect(store.state.pages[0].crop == drawn)

        // And every page — including the portrait one — now exports at 4:1.
        for page in store.state.pages {
            let crop = try #require(page.crop)
            let size = try #require(store.sourceSizes[page.source])
            #expect(abs(CropGeometry.exportedRatio(crop, sourceSize: size, rotation: page.rotation) - 4) < 0.001)
        }
    }

    @Test func drawingOnARotatedPageUsesWhatTheUserSees() async throws {
        let folder = try makeFolder(sizes: [("a.png", CGSize(width: 2000, height: 1000))])
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = DocumentStore()
        await store.openFolder(folder)
        let page = store.state.pages[0]
        store.rotatePage(id: page.id, by: 90)

        // Rotated, the page reads 1000×2000. A full-width, half-height
        // rectangle there is 1000×1000 — square.
        store.defineAspectRatio(
            fromDrawnCrop: CropRect(x: 0, y: 0, width: 1, height: 0.5),
            onPageID: page.id
        )

        let ratio = try #require(store.state.cropAspectRatio)
        #expect(abs(ratio.ratio - 1) < 0.001)

        let crop = try #require(store.state.pages[0].crop)
        let size = try #require(store.sourceSizes[page.source])
        #expect(abs(CropGeometry.exportedRatio(crop, sourceSize: size, rotation: 90) - 1) < 0.001)
    }

    @Test func definedRatioSurvivesReopening() async throws {
        let folder = try makeFolder(sizes: mixed)
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = DocumentStore()
        await store.openFolder(folder)
        let drawn = CropRect(x: 0.1, y: 0.1, width: 0.6, height: 0.3)
        store.defineAspectRatio(fromDrawnCrop: drawn, onPageID: store.state.pages[0].id)
        let expected = try #require(store.state.cropAspectRatio)
        store.saveDocument()

        let reopened = DocumentStore()
        await reopened.openFolder(folder)
        #expect(reopened.state.cropAspectRatio == expected)
        #expect(reopened.state.pages[0].crop == drawn)
    }

    @Test func aDegenerateRectangleIsIgnored() async throws {
        let folder = try makeFolder(sizes: mixed)
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = DocumentStore()
        await store.openFolder(folder)
        store.defineAspectRatio(
            fromDrawnCrop: CropRect(x: 0.5, y: 0.5, width: 0, height: 0),
            onPageID: store.state.pages[0].id
        )

        #expect(store.state.cropAspectRatio == nil)
        #expect(store.state.pages.allSatisfy { $0.crop == nil })
    }
}

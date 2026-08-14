import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import IdFit

/// A folder starts out mixed: drawing a rectangle frames the page it was drawn
/// on and nothing else. A format shared by the whole document is something the
/// user asks for — from the toolbar, or by promoting one page's framing.
@MainActor
@Suite struct CommonFormatTests {
    private func makeFolder(sizes: [(name: String, size: CGSize)]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("id-fit-format-tests-\(UUID().uuidString)", isDirectory: true)
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

    private func exportedRatio(_ page: Page, in store: DocumentStore) throws -> Double {
        let crop = try #require(page.crop)
        let size = try #require(store.sourceSizes[page.source])
        return CropGeometry.exportedRatio(crop, sourceSize: size, rotation: page.rotation)
    }

    // MARK: - Drawing

    @Test func drawingFramesOnlyThePageItWasDrawnOn() async throws {
        let folder = try makeFolder(sizes: mixed)
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = DocumentStore()
        await store.openFolder(folder)
        #expect(store.state.cropAspectRatio == nil)

        // Half the width, a quarter of the height of a 2000×1000 page →
        // 1000×250 pixels, i.e. 4:1.
        let drawn = CropRect(x: 0.25, y: 0.3, width: 0.5, height: 0.25)
        store.drawCrop(drawn, onPageID: store.state.pages[0].id)

        #expect(store.state.pages[0].crop == drawn)
        #expect(abs(try exportedRatio(store.state.pages[0], in: store) - 4) < 0.001)
        // The document is still mixed, and the other page is untouched.
        #expect(store.state.cropAspectRatio == nil)
        #expect(store.state.pages[1].crop == nil)
    }

    @Test func eachPageCanBeFramedItsOwnWay() async throws {
        let folder = try makeFolder(sizes: mixed)
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = DocumentStore()
        await store.openFolder(folder)
        store.drawCrop(CropRect(x: 0.25, y: 0.3, width: 0.5, height: 0.25), onPageID: store.state.pages[0].id)
        store.drawCrop(CropRect(x: 0.1, y: 0.1, width: 0.4, height: 0.8), onPageID: store.state.pages[1].id)

        // 1000×250 against 360×960: two shapes, and nothing objects.
        #expect(abs(try exportedRatio(store.state.pages[0], in: store) - 4) < 0.001)
        #expect(abs(try exportedRatio(store.state.pages[1], in: store) - 0.375) < 0.001)
        #expect(store.state.cropAspectRatio == nil)
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
        store.drawCrop(CropRect(x: 0, y: 0, width: 1, height: 0.5), onPageID: page.id)

        #expect(abs(try exportedRatio(store.state.pages[0], in: store) - 1) < 0.001)
    }

    @Test func aDegenerateRectangleIsIgnored() async throws {
        let folder = try makeFolder(sizes: mixed)
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = DocumentStore()
        await store.openFolder(folder)
        store.drawCrop(
            CropRect(x: 0.5, y: 0.5, width: 0, height: 0),
            onPageID: store.state.pages[0].id
        )

        #expect(store.state.pages.allSatisfy { $0.crop == nil })
    }

    // MARK: - Promoting one framing to the whole document

    @Test func oneFramingCanBecomeTheFormatForEveryPage() async throws {
        let folder = try makeFolder(sizes: mixed)
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = DocumentStore()
        await store.openFolder(folder)
        let drawn = CropRect(x: 0.25, y: 0.3, width: 0.5, height: 0.25)
        store.drawCrop(drawn, onPageID: store.state.pages[0].id)
        store.useFramingAsCommonFormat(fromPageID: store.state.pages[0].id)

        let ratio = try #require(store.state.cropAspectRatio)
        #expect(abs(ratio.ratio - 4) < 0.001)

        // The page it came from keeps exactly that framing…
        #expect(store.state.pages[0].crop == drawn)
        // …and every other page — including the portrait one — now exports
        // at the same shape.
        for page in store.state.pages {
            #expect(abs(try exportedRatio(page, in: store) - 4) < 0.001)
        }
    }

    @Test func promotingAFramingRefitsTheCropsTheOtherPagesAlreadyHad() async throws {
        let folder = try makeFolder(sizes: mixed)
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = DocumentStore()
        await store.openFolder(folder)
        store.drawCrop(CropRect(x: 0.25, y: 0.3, width: 0.5, height: 0.25), onPageID: store.state.pages[0].id)
        // The other page is framed on its own first — near the top of the
        // scan — so promoting has to reshape that framing rather than replace
        // it with a crop centered on the page.
        let theirs = CropRect(x: 0.1, y: 0.05, width: 0.4, height: 0.3)
        store.drawCrop(theirs, onPageID: store.state.pages[1].id)

        store.useFramingAsCommonFormat(fromPageID: store.state.pages[0].id)

        let second = try #require(store.state.pages[1].crop)
        #expect(abs(try exportedRatio(store.state.pages[1], in: store) - 4) < 0.001)
        // Still up at the top, where it was put. Only the height is worth
        // asserting: a 4:1 crop of a portrait page is as wide as the page,
        // which leaves it nowhere to sit horizontally but the middle.
        #expect(abs((second.y + second.height / 2) - (theirs.y + theirs.height / 2)) < 0.02)
    }

    @Test func promotingARotatedPageUsesWhatTheUserSees() async throws {
        let folder = try makeFolder(sizes: [("a.png", CGSize(width: 2000, height: 1000))])
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = DocumentStore()
        await store.openFolder(folder)
        let page = store.state.pages[0]
        store.rotatePage(id: page.id, by: 90)
        store.drawCrop(CropRect(x: 0, y: 0, width: 1, height: 0.5), onPageID: page.id)
        store.useFramingAsCommonFormat(fromPageID: page.id)

        let ratio = try #require(store.state.cropAspectRatio)
        #expect(abs(ratio.ratio - 1) < 0.001)
        #expect(abs(try exportedRatio(store.state.pages[0], in: store) - 1) < 0.001)
    }

    @Test func aPageWithNoCropDefinesNothing() async throws {
        let folder = try makeFolder(sizes: mixed)
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = DocumentStore()
        await store.openFolder(folder)
        store.useFramingAsCommonFormat(fromPageID: store.state.pages[0].id)

        #expect(store.state.cropAspectRatio == nil)
        #expect(store.state.pages.allSatisfy { $0.crop == nil })
    }

    @Test func thePromotedFormatSurvivesReopening() async throws {
        let folder = try makeFolder(sizes: mixed)
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = DocumentStore()
        await store.openFolder(folder)
        let drawn = CropRect(x: 0.1, y: 0.1, width: 0.6, height: 0.3)
        store.drawCrop(drawn, onPageID: store.state.pages[0].id)
        store.useFramingAsCommonFormat(fromPageID: store.state.pages[0].id)
        let expected = try #require(store.state.cropAspectRatio)
        store.saveDocument()

        let reopened = DocumentStore()
        await reopened.openFolder(folder)
        #expect(reopened.state.cropAspectRatio == expected)
        #expect(reopened.state.pages[0].crop == drawn)
    }

    // MARK: - Resetting

    @Test func resettingWithoutACommonFormatClearsTheCrop() async throws {
        let folder = try makeFolder(sizes: mixed)
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = DocumentStore()
        await store.openFolder(folder)
        let id = store.state.pages[0].id
        store.drawCrop(CropRect(x: 0.25, y: 0.3, width: 0.5, height: 0.25), onPageID: id)

        // Nothing to recentre onto, so the page goes back to having no crop —
        // and to offering the draw gesture again.
        store.resetCrop(forPageID: id)
        #expect(store.state.pages[0].crop == nil)
    }

    @Test func resettingWithACommonFormatStillRecentres() async throws {
        let folder = try makeFolder(sizes: mixed)
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = DocumentStore()
        await store.openFolder(folder)
        store.setAspectRatio(AspectRatio(width: 1, height: 1))
        let id = store.state.pages[0].id
        store.setCrop(CropRect(x: 0, y: 0, width: 0.2, height: 0.4), forPageID: id)

        store.resetCrop(forPageID: id)
        let crop = try #require(store.state.pages[0].crop)
        #expect(abs((crop.x + crop.width / 2) - 0.5) < 0.0001)
        #expect(abs((crop.y + crop.height / 2) - 0.5) < 0.0001)
        #expect(abs(try exportedRatio(store.state.pages[0], in: store) - 1) < 0.001)
    }
}

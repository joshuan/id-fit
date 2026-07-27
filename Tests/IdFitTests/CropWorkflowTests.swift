import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import IdFit

/// End-to-end crop behaviour through the store, on real image files of
/// different pixel sizes — the case the app exists for.
@MainActor
@Suite struct CropWorkflowTests {
    private let a4 = 210.0 / 297.0

    private func makeFolder(_ files: [(name: String, size: CGSize)]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("id-fit-crop-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in files {
            try writePNG(size: file.size, to: folder.appendingPathComponent(file.name))
        }
        return folder
    }

    private func writePNG(size: CGSize, to url: URL) throws {
        let context = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.6, green: 0.6, blue: 0.6, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        let image = context.makeImage()!
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        )!
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    private func exportedRatio(_ page: Page, in store: DocumentStore) -> Double? {
        guard let crop = page.crop, let size = store.sourceSizes[page.source] else { return nil }
        return (crop.width * size.width) / (crop.height * size.height)
    }

    private let mixedSizes: [(name: String, size: CGSize)] = [
        ("a-300dpi.png", CGSize(width: 620, height: 877)),   // A4-ish portrait
        ("b-150dpi.png", CGSize(width: 310, height: 438)),   // same page, half DPI
        ("c-landscape.png", CGSize(width: 800, height: 500)),
        ("d-square.png", CGSize(width: 400, height: 400)),
    ]

    @Test func settingRatioCropsEveryPageToTheSameExportRatio() async throws {
        let folder = try makeFolder(mixedSizes)
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = DocumentStore()
        await store.openFolder(folder)
        #expect(store.sourceSizes.count == 4)

        store.setAspectRatio(AspectRatio(width: 210, height: 297))

        for page in store.state.pages {
            let ratio = try #require(exportedRatio(page, in: store))
            #expect(abs(ratio - a4) < 0.0001)
        }
    }

    @Test func changingRatioRefitsExistingCrops() async throws {
        let folder = try makeFolder(mixedSizes)
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = DocumentStore()
        await store.openFolder(folder)
        store.setAspectRatio(AspectRatio(width: 210, height: 297))
        store.setAspectRatio(AspectRatio(width: 85.6, height: 54))

        let idCard = 85.6 / 54.0
        for page in store.state.pages {
            let ratio = try #require(exportedRatio(page, in: store))
            #expect(abs(ratio - idCard) < 0.0001)
        }
    }

    @Test func choosingOriginalClearsAllCrops() async throws {
        let folder = try makeFolder(mixedSizes)
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = DocumentStore()
        await store.openFolder(folder)
        store.setAspectRatio(AspectRatio(width: 1, height: 1))
        #expect(store.state.pages.allSatisfy { $0.crop != nil })

        store.setAspectRatio(nil)
        #expect(store.state.pages.allSatisfy { $0.crop == nil })
        #expect(store.state.cropAspectRatio == nil)
    }

    @Test func applyToAllCopiesFramingAndKeepsRatioPerPage() async throws {
        let folder = try makeFolder(mixedSizes)
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = DocumentStore()
        await store.openFolder(folder)
        store.setAspectRatio(AspectRatio(width: 210, height: 297))

        let first = store.state.pages[0]
        let tightened = CropGeometry.resized(
            try #require(first.crop),
            corner: .topLeft,
            toPixelPoint: CGPoint(x: 100, y: 100),
            outputRatio: a4,
            sourceSize: try #require(store.sourceSizes[first.source])
        )
        store.setCrop(tightened, forPageID: first.id)
        store.applyCropToAllPages(fromPageID: first.id)

        for page in store.state.pages {
            let ratio = try #require(exportedRatio(page, in: store))
            #expect(abs(ratio - a4) < 0.0001)
        }
        // The framing (center) is copied, not the raw normalized numbers.
        let template = try #require(store.state.pages[0].crop)
        for page in store.state.pages.dropFirst() {
            let crop = try #require(page.crop)
            #expect(abs((crop.x + crop.width / 2) - (template.x + template.width / 2)) < 0.05)
        }
    }

    @Test func cropsSurviveReopeningTheFolder() async throws {
        let folder = try makeFolder(mixedSizes)
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = DocumentStore()
        await store.openFolder(folder)
        store.setAspectRatio(AspectRatio(width: 210, height: 297))
        let saved = store.state.pages.map(\.crop)
        store.saveImmediately()

        let reopened = DocumentStore()
        await reopened.openFolder(folder)
        #expect(reopened.state.cropAspectRatio == AspectRatio(width: 210, height: 297))
        #expect(reopened.state.pages.map(\.crop) == saved)
    }

    @Test func cropsStayInsideEveryPage() async throws {
        let folder = try makeFolder(mixedSizes)
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = DocumentStore()
        await store.openFolder(folder)
        for ratio in [AspectRatio(width: 210, height: 297), AspectRatio(width: 35, height: 45),
                      AspectRatio(width: 297, height: 210), AspectRatio(width: 1, height: 1)] {
            store.setAspectRatio(ratio)
            for page in store.state.pages {
                let crop = try #require(page.crop)
                #expect(crop.x >= -0.0001)
                #expect(crop.y >= -0.0001)
                #expect(crop.x + crop.width <= 1.0001)
                #expect(crop.y + crop.height <= 1.0001)
            }
        }
    }
}

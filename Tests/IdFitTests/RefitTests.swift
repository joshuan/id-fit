import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import IdFit

/// Reshaping a crop must not resize it. Growing it to whatever would fit
/// throws away a framing the user chose and leaves a wide margin around
/// anything detected.
@Suite struct RefitTests {
    private let a4 = 210.0 / 297.0

    private func area(_ crop: CropRect, in size: CGSize) -> Double {
        (crop.width * size.width) * (crop.height * size.height)
    }

    @Test func reshapingKeepsTheCropTheSameSize() {
        let size = CGSize(width: 2000, height: 2000)
        let tight = CropRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)

        let refitted = CropGeometry.refit(tight, outputRatio: a4, sourceSize: size)

        #expect(abs(CropGeometry.exportedRatio(refitted, sourceSize: size) - a4) < 0.0001)
        // Same coverage, different shape.
        #expect(abs(area(refitted, in: size) / area(tight, in: size) - 1) < 0.01)
    }

    @Test func aCropThatAlreadyFitsIsLeftAlone() {
        let size = CGSize(width: 2400, height: 1800)
        let framed = CropGeometry.centeredCrop(outputRatio: a4, sourceSize: size)
        let tightened = CropGeometry.resized(
            framed, corner: .topLeft, toPixelPoint: CGPoint(x: 900, y: 300),
            outputRatio: a4, sourceSize: size
        )

        let refitted = CropGeometry.refit(tightened, outputRatio: a4, sourceSize: size)

        #expect(abs(refitted.x - tightened.x) < 0.001)
        #expect(abs(refitted.y - tightened.y) < 0.001)
        #expect(abs(refitted.width - tightened.width) < 0.001)
        #expect(abs(refitted.height - tightened.height) < 0.001)
    }

    @Test func aSmallCropNearAnEdgeSlidesInsteadOfShrinking() {
        let size = CGSize(width: 2000, height: 1000)
        let corner = CropRect(x: 0.8, y: 0.0, width: 0.18, height: 0.3)

        let refitted = CropGeometry.refit(corner, outputRatio: a4, sourceSize: size)

        #expect(abs(CropGeometry.exportedRatio(refitted, sourceSize: size) - a4) < 0.0001)
        #expect(refitted.x >= -0.0001)
        #expect(refitted.y >= -0.0001)
        #expect(refitted.x + refitted.width <= 1.0001)
        #expect(refitted.y + refitted.height <= 1.0001)
        // It kept its size rather than being cut down to fit at the corner.
        #expect(area(refitted, in: size) / area(corner, in: size) > 0.9)
    }

    @Test func aCropLargerThanTheSourceIsBroughtInside() {
        let size = CGSize(width: 1000, height: 1000)
        let everything = CropRect(x: 0, y: 0, width: 1, height: 1)

        let refitted = CropGeometry.refit(everything, outputRatio: a4, sourceSize: size)

        #expect(abs(CropGeometry.exportedRatio(refitted, sourceSize: size) - a4) < 0.0001)
        #expect(refitted.x + refitted.width <= 1.0001)
        #expect(refitted.y + refitted.height <= 1.0001)
    }

    @MainActor
    @Test func applyingAFramingLeavesTheChosenPageExactlyAsItWas() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("id-fit-refit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        for name in ["a.png", "b.png", "c.png"] {
            let context = CGContext(
                data: nil, width: 1600, height: 1200, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            let destination = CGImageDestinationCreateWithURL(
                folder.appendingPathComponent(name) as CFURL,
                UTType.png.identifier as CFString, 1, nil
            )!
            CGImageDestinationAddImage(destination, context.makeImage()!, nil)
            #expect(CGImageDestinationFinalize(destination))
        }

        let store = DocumentStore()
        await store.openFolder(folder)
        store.setAspectRatio(AspectRatio(width: 210, height: 297))

        // Frame the first page by hand, tighter and off to one side.
        let first = store.state.pages[0]
        let size = try #require(store.sourceSizes[first.source])
        var mine = CropGeometry.resized(
            try #require(first.crop), corner: .topLeft, toPixelPoint: CGPoint(x: 500, y: 260),
            outputRatio: a4, sourceSize: size
        )
        mine = CropGeometry.moved(mine, byPixels: CGSize(width: -120, height: 40), sourceSize: size)
        store.setCrop(mine, forPageID: first.id)

        store.applyCropToAllPages(fromPageID: first.id)

        // The page it came from must not move at all.
        #expect(store.state.pages[0].crop == mine)
        // And the others take the same framing.
        for page in store.state.pages.dropFirst() {
            let crop = try #require(page.crop)
            #expect(abs(crop.x - mine.x) < 0.01)
            #expect(abs(crop.y - mine.y) < 0.01)
            #expect(abs(crop.width - mine.width) < 0.01)
            #expect(abs(crop.height - mine.height) < 0.01)
        }
    }

    @MainActor
    @Test func aFramingSurvivesClosingAndReopeningTheEditor() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("id-fit-refit-reopen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let context = CGContext(
            data: nil, width: 1600, height: 1200, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let destination = CGImageDestinationCreateWithURL(
            folder.appendingPathComponent("a.png") as CFURL,
            UTType.png.identifier as CFString, 1, nil
        )!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(destination))

        let store = DocumentStore()
        await store.openFolder(folder)
        store.setAspectRatio(AspectRatio(width: 210, height: 297))
        let page = store.state.pages[0]
        let size = try #require(store.sourceSizes[page.source])
        let mine = CropGeometry.resized(
            try #require(page.crop), corner: .bottomRight, toPixelPoint: CGPoint(x: 900, y: 700),
            outputRatio: a4, sourceSize: size
        )
        store.setCrop(mine, forPageID: page.id)
        store.saveImmediately()

        // Reopening runs the crops through normalization again.
        let reopened = DocumentStore()
        await reopened.openFolder(folder)
        let restored = try #require(reopened.state.pages[0].crop)
        #expect(abs(restored.width - mine.width) < 0.001)
        #expect(abs(restored.height - mine.height) < 0.001)
        #expect(abs(restored.x - mine.x) < 0.001)
    }
}

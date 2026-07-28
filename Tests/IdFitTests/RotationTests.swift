import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import IdFit

@Suite struct RotationTests {
    private let a4 = 210.0 / 297.0

    private func exportedRatio(_ crop: CropRect, sourceSize: CGSize, rotation: Int) -> Double {
        let width = crop.width * sourceSize.width
        let height = crop.height * sourceSize.height
        return rotation % 180 == 0 ? width / height : height / width
    }

    @Test func rotatingACropMapsItOntoTheTurnedPage() {
        let topLeft = CropRect(x: 0, y: 0, width: 0.5, height: 0.5)

        // A clockwise quarter turn sends the top-left corner to the top-right.
        #expect(CropGeometry.rotated(topLeft, by: 90) == CropRect(x: 0.5, y: 0, width: 0.5, height: 0.5))
        #expect(CropGeometry.rotated(topLeft, by: 180) == CropRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5))
        #expect(CropGeometry.rotated(topLeft, by: 270) == CropRect(x: 0, y: 0.5, width: 0.5, height: 0.5))
        #expect(CropGeometry.rotated(topLeft, by: 0) == topLeft)
    }

    @Test func rotatingBackRestoresTheOriginalCrop() {
        let crop = CropRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        for angle in [90, 180, 270, -90] {
            let round = CropGeometry.rotated(CropGeometry.rotated(crop, by: angle), by: -angle)
            #expect(abs(round.x - crop.x) < 0.0001)
            #expect(abs(round.y - crop.y) < 0.0001)
            #expect(abs(round.width - crop.width) < 0.0001)
            #expect(abs(round.height - crop.height) < 0.0001)
        }
    }

    @Test func rotatingANonSquareCropSwapsItsSides() {
        let wide = CropRect(x: 0.1, y: 0.4, width: 0.8, height: 0.2)
        let turned = CropGeometry.rotated(wide, by: 90)
        #expect(turned.width == 0.2)
        #expect(turned.height == 0.8)
    }

    @Test func rotatingAnImageSwapsItsDimensions() {
        let context = CGContext(
            data: nil, width: 400, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let image = context.makeImage()!

        #expect(PageRenderer.rotate(image, by: 90).width == 600)
        #expect(PageRenderer.rotate(image, by: 90).height == 400)
        #expect(PageRenderer.rotate(image, by: 180).width == 400)
        #expect(PageRenderer.rotate(image, by: 0).width == 400)
    }

    /// A folder holding one blank scan of the given pixel size.
    private func makeImageFolder(size: CGSize) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("id-fit-rotation-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let destination = CGImageDestinationCreateWithURL(
            folder.appendingPathComponent("scan.png") as CFURL, UTType.png.identifier as CFString, 1, nil
        )!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(destination))
        return folder
    }

    @MainActor
    @Test func rotatingAPageTurnsItsCropWithIt() async throws {
        let size = CGSize(width: 600, height: 400)
        let folder = try makeImageFolder(size: size)
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = DocumentStore()
        await store.openFolder(folder)
        store.setAspectRatio(AspectRatio(width: 210, height: 297))

        let page = store.state.pages[0]
        let before = try #require(page.crop)
        #expect(abs(exportedRatio(before, sourceSize: size, rotation: 0) - a4) < 0.0001)

        store.rotatePage(id: page.id, by: 90)
        let rotated = store.state.pages[0]
        #expect(rotated.rotation == 90)

        // The very same region of the scan stays framed — turning the page
        // must not shift what was chosen.
        #expect(rotated.crop == before)

        // What it exports is that shape laid on its side, which is exactly
        // what the page now is.
        let after = try #require(rotated.crop)
        #expect(rotated.transposedRatio)
        #expect(abs(exportedRatio(after, sourceSize: size, rotation: 90) - 1 / a4) < 0.0001)
        #expect(abs(try #require(store.state.outputRatio(for: rotated)) - 1 / a4) < 0.0001)
    }

    @MainActor
    @Test func turningAPageAllTheWayRoundRestoresIt() async throws {
        let folder = try makeImageFolder(size: CGSize(width: 600, height: 400))
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = DocumentStore()
        await store.openFolder(folder)
        store.setAspectRatio(AspectRatio(width: 210, height: 297))
        let id = store.state.pages[0].id
        let original = store.state.pages[0]

        for _ in 0..<4 { store.rotatePage(id: id, by: 90) }

        #expect(store.state.pages[0].rotation == 0)
        #expect(store.state.pages[0].transposedRatio == original.transposedRatio)
        #expect(store.state.pages[0].crop == original.crop)
    }

    @MainActor
    @Test func aHalfTurnKeepsTheOrientationOfTheRatio() async throws {
        let folder = try makeImageFolder(size: CGSize(width: 600, height: 400))
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = DocumentStore()
        await store.openFolder(folder)
        store.setAspectRatio(AspectRatio(width: 210, height: 297))
        let id = store.state.pages[0].id

        store.rotatePage(id: id, by: 180)
        #expect(store.state.pages[0].rotation == 180)
        #expect(!store.state.pages[0].transposedRatio)
    }

    @MainActor
    @Test func aPageCanUseTheSharedShapeSideways() async throws {
        let folder = try makeImageFolder(size: CGSize(width: 600, height: 400))
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = DocumentStore()
        await store.openFolder(folder)
        store.setAspectRatio(AspectRatio(width: 210, height: 297))
        let id = store.state.pages[0].id

        // The document on this scan lies the other way round from the rest.
        store.toggleCropOrientation(forPageID: id)

        let page = store.state.pages[0]
        #expect(page.transposedRatio)
        let crop = try #require(page.crop)
        #expect(abs(exportedRatio(crop, sourceSize: CGSize(width: 600, height: 400), rotation: 0) - 1 / a4) < 0.0001)
        // Other pages are untouched by one page's orientation.
        #expect(store.state.cropAspectRatio == AspectRatio(width: 210, height: 297))
    }

    @MainActor
    @Test func rotationWrapsAroundAndPersists() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("id-fit-rotation-persist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data().write(to: folder.appendingPathComponent("a.jpg"))

        let store = DocumentStore()
        await store.openFolder(folder)
        let id = store.state.pages[0].id

        store.rotatePage(id: id, by: 90)
        store.rotatePage(id: id, by: 90)
        store.rotatePage(id: id, by: 90)
        store.rotatePage(id: id, by: 90)
        #expect(store.state.pages[0].rotation == 0)

        store.rotatePage(id: id, by: -90)
        #expect(store.state.pages[0].rotation == 270)

        store.saveImmediately()
        let reopened = DocumentStore()
        await reopened.openFolder(folder)
        #expect(reopened.state.pages[0].rotation == 270)
    }
}

@MainActor
@Suite struct MissingPageTests {
    private func makeFolder(files: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("id-fit-missing-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for name in files {
            try Data().write(to: url.appendingPathComponent(name))
        }
        return url
    }

    @Test func removingMissingPagesDropsOnlyThoseAndKeepsFiles() async throws {
        let folder = try makeFolder(files: ["a.jpg", "b.jpg"])
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = DocumentStore()
        await store.openFolder(folder)
        store.saveImmediately()

        try FileManager.default.removeItem(at: folder.appendingPathComponent("a.jpg"))
        let reopened = DocumentStore()
        await reopened.openFolder(folder)
        #expect(reopened.state.pages.count == 2)

        reopened.removeMissingPages()
        #expect(reopened.state.pages.map(\.source.file) == ["b.jpg"])
        #expect(reopened.missingSources.isEmpty)

        // The surviving source file is untouched.
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("b.jpg").path))
    }

    @Test func removingASinglePageNeverDeletesItsFile() async throws {
        let folder = try makeFolder(files: ["a.jpg", "b.jpg"])
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = DocumentStore()
        await store.openFolder(folder)
        store.removePage(id: store.state.pages[0].id)

        #expect(store.state.pages.map(\.source.file) == ["b.jpg"])
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("a.jpg").path))
    }

    @Test func removedPageComesBackOnReopenWhenItsFileIsStillThere() async throws {
        let folder = try makeFolder(files: ["a.jpg", "b.jpg"])
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = DocumentStore()
        await store.openFolder(folder)
        store.removePage(id: store.state.pages[0].id)
        store.saveImmediately()

        // Reconciliation re-adds it, because the folder is the source of truth.
        let reopened = DocumentStore()
        await reopened.openFolder(folder)
        #expect(reopened.state.pages.map(\.source.file) == ["b.jpg", "a.jpg"])
    }
}

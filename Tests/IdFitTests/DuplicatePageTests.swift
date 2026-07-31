import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import IdFit

/// One scan often holds two pages of the finished document — a passport cover
/// is both its front and its back.
@MainActor
@Suite struct DuplicatePageTests {
    private func makeFolder(files: [String]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("id-fit-duplicate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in files {
            let context = CGContext(
                data: nil, width: 800, height: 1200, bitsPerComponent: 8, bytesPerRow: 0,
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
        return folder
    }

    @Test func aCopyLandsRightAfterTheOriginalAndIsItsOwnPage() async throws {
        let folder = try makeFolder(files: ["cover.png", "zz-other.png"])
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = DocumentStore()
        await store.openFolder(folder)
        store.setAspectRatio(AspectRatio(width: 88, height: 125))
        let original = store.state.pages[0]

        store.duplicatePage(id: original.id)

        #expect(store.state.pages.count == 3)
        #expect(store.state.pages.map(\.source.file) == ["cover.png", "cover.png", "zz-other.png"])
        // Same scan, but a page in its own right.
        #expect(store.state.pages[1].id != original.id)
        #expect(store.state.pages[1].crop == original.crop)
    }

    @Test func theCopyCanBeFramedAndMovedOnItsOwn() async throws {
        let folder = try makeFolder(files: ["cover.png"])
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = DocumentStore()
        await store.openFolder(folder)
        store.setAspectRatio(AspectRatio(width: 88, height: 125))
        let original = store.state.pages[0]
        store.duplicatePage(id: original.id)
        let copy = store.state.pages[1]

        // Frame the copy on the other half of the scan.
        let size = try #require(store.sourceSizes[copy.source])
        let moved = CropGeometry.moved(
            try #require(copy.crop), byPixels: CGSize(width: 0, height: 400), sourceSize: size
        )
        store.setCrop(moved, forPageID: copy.id)

        #expect(store.state.pages[0].crop == original.crop)
        #expect(store.state.pages[1].crop == moved)
        #expect(store.state.pages[0].crop != store.state.pages[1].crop)
    }

    @Test func aCopyCanBeDraggedToTheEndAndSurvivesReopening() async throws {
        let folder = try makeFolder(files: ["cover.png", "p1.png", "p2.png"])
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = DocumentStore()
        await store.openFolder(folder)
        let cover = store.state.pages[0]
        store.duplicatePage(id: cover.id)
        let copy = store.state.pages[1]
        store.movePage(id: copy.id, toIndex: 3)

        #expect(store.state.pages.map(\.source.file) == ["cover.png", "p1.png", "p2.png", "cover.png"])
        store.saveDocument()

        let reopened = DocumentStore()
        await reopened.openFolder(folder)
        // Reconciliation must not collapse the two entries back into one.
        #expect(reopened.state.pages.map(\.source.file) == ["cover.png", "p1.png", "p2.png", "cover.png"])
    }

    @Test func removingOneCopyLeavesTheOther() async throws {
        let folder = try makeFolder(files: ["cover.png"])
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = DocumentStore()
        await store.openFolder(folder)
        store.duplicatePage(id: store.state.pages[0].id)
        store.removePage(id: store.state.pages[1].id)

        #expect(store.state.pages.count == 1)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("cover.png").path))
    }

    @Test func aDuplicatedScanIsNotRewrittenInPlace() async throws {
        let folder = try makeFolder(files: ["cover.png", "zz-other.png"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let coverURL = folder.appendingPathComponent("cover.png")
        let untouched = try Data(contentsOf: coverURL)

        let store = DocumentStore()
        await store.openFolder(folder)
        store.setAspectRatio(AspectRatio(width: 88, height: 125))
        store.duplicatePage(id: store.state.pages[0].id)

        let result = try OriginalsWriter.apply(
            pages: store.state.pages, folder: folder, makeBackup: false
        )

        // Two different framings cannot both be baked into one file, so the
        // file is left alone and reported rather than silently losing one.
        #expect(result.failures.contains("cover.png"))
        #expect(!result.changedFiles.contains("cover.png"))
        #expect(try Data(contentsOf: coverURL) == untouched)
        // The page that is not duplicated is still applied.
        #expect(result.changedFiles.contains("zz-other.png"))
    }
}

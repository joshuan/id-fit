import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import IdFit

/// A page whose file is absent while the shared ratio changes keeps its old
/// shape. When the file comes back it must be brought onto the shared ratio,
/// or the export would no longer be uniform.
@MainActor
@Suite struct CropNormalizationTests {
    private let a4 = 210.0 / 297.0
    private let idCard = 85.6 / 54.0

    private func makeFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("id-fit-normalize-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writePNG(size: CGSize, to url: URL) {
        let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        )!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    @Test func aReturningFileGetsItsCropRefittedToTheSharedRatio() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let away = folder.appendingPathComponent("away.png")
        writePNG(size: CGSize(width: 600, height: 400), to: away)
        writePNG(size: CGSize(width: 500, height: 700), to: folder.appendingPathComponent("here.png"))

        let store = DocumentStore()
        await store.openFolder(folder)
        store.setAspectRatio(AspectRatio(width: 210, height: 297))
        store.saveImmediately()

        // The folder is still syncing: one file disappears.
        let stashed = try Data(contentsOf: away)
        try FileManager.default.removeItem(at: away)

        let offline = DocumentStore()
        await offline.openFolder(folder)
        #expect(offline.missingSources == [SourceRef(file: "away.png")])
        // The ratio changes while that page cannot be measured.
        offline.setAspectRatio(AspectRatio(width: 85.6, height: 54))
        offline.saveImmediately()

        // Its crop is untouched and therefore still A4-shaped.
        let stale = try #require(offline.state.pages.first { $0.source.file == "away.png" }?.crop)
        #expect(abs(CropGeometry.exportedRatio(stale, sourceSize: CGSize(width: 600, height: 400)) - a4) < 0.001)

        // The file syncs back.
        try stashed.write(to: away)
        let reopened = DocumentStore()
        await reopened.openFolder(folder)

        #expect(reopened.missingSources.isEmpty)
        for page in reopened.state.pages {
            let crop = try #require(page.crop)
            let size = try #require(reopened.sourceSizes[page.source])
            #expect(abs(CropGeometry.exportedRatio(crop, sourceSize: size, rotation: page.rotation) - idCard) < 0.001)
        }
    }

    @Test func normalizationIsPersistedNotJustHeldInMemory() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        writePNG(size: CGSize(width: 600, height: 400), to: folder.appendingPathComponent("a.png"))

        // Hand-written state with a crop that does not match its ratio.
        let state = ProjectState(
            cropAspectRatio: AspectRatio(width: 210, height: 297),
            pages: [Page(source: SourceRef(file: "a.png"),
                         crop: CropRect(x: 0, y: 0, width: 1, height: 1))]
        )
        try StateStore.save(state, to: folder)

        let store = DocumentStore()
        await store.openFolder(folder)

        let saved = try #require(try StateStore.load(from: folder))
        let crop = try #require(saved.pages[0].crop)
        #expect(abs(CropGeometry.exportedRatio(crop, sourceSize: CGSize(width: 600, height: 400)) - a4) < 0.001)
    }

    @Test func matchingCropsAreLeftExactlyAsTheyAre() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        writePNG(size: CGSize(width: 600, height: 400), to: folder.appendingPathComponent("a.png"))

        let store = DocumentStore()
        await store.openFolder(folder)
        store.setAspectRatio(AspectRatio(width: 210, height: 297))
        // Frame it somewhere off-centre so a needless refit would show up.
        let page = store.state.pages[0]
        let moved = CropGeometry.moved(
            try #require(page.crop), byPixels: CGSize(width: -60, height: 0),
            sourceSize: CGSize(width: 600, height: 400)
        )
        store.setCrop(moved, forPageID: page.id)
        store.saveImmediately()

        let reopened = DocumentStore()
        await reopened.openFolder(folder)
        #expect(reopened.state.pages[0].crop == moved)
    }

    @Test func noSharedRatioMeansNoNormalization() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        writePNG(size: CGSize(width: 600, height: 400), to: folder.appendingPathComponent("a.png"))

        let odd = CropRect(x: 0.1, y: 0.1, width: 0.3, height: 0.7)
        try StateStore.save(
            ProjectState(pages: [Page(source: SourceRef(file: "a.png"), crop: odd)]),
            to: folder
        )

        let store = DocumentStore()
        await store.openFolder(folder)
        #expect(store.state.pages[0].crop == odd)
    }
}

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import IdFit

/// A straightened page whose recorded orientation disagrees with its corners
/// is not merely framed oddly — it is stretched, because straightening maps
/// those corners onto whatever shape the page claims to be. Older state files
/// carry such orientations, so opening one has to put them right.
@MainActor
@Suite struct OrientationRepairTests {
    private let passport = 88.0 / 125.0

    /// A portrait document, slightly tilted, on a 1000 × 1000 photo.
    private let portraitDocument = DocumentQuad(
        topLeft: CGPoint(x: 0.30, y: 0.12),
        topRight: CGPoint(x: 0.68, y: 0.16),
        bottomRight: CGPoint(x: 0.70, y: 0.86),
        bottomLeft: CGPoint(x: 0.32, y: 0.82)
    )

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("id-fit-orientation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let context = CGContext(
            data: nil, width: 1000, height: 1000, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let destination = CGImageDestinationCreateWithURL(
            folder.appendingPathComponent("cover.png") as CFURL,
            UTType.png.identifier as CFString, 1, nil
        )!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(destination))
        return folder
    }

    /// Writes a state file as version 1 wrote them, with the orientation the
    /// old guess would have produced for a tilted portrait page.
    private func writeLegacyState(to folder: URL, transposed: Bool) throws {
        var state = ProjectState(
            cropAspectRatio: AspectRatio(width: 88, height: 125),
            pages: [Page(
                source: SourceRef(file: "cover.png"),
                crop: CropRect(x: 0.3, y: 0.12, width: 0.4, height: 0.74),
                autoDetected: true,
                transposedRatio: transposed,
                quad: portraitDocument
            )]
        )
        state.version = 1
        try StateStore.save(state, to: folder)
    }

    @Test func openingAnOlderFolderPutsAStretchedPageBackUpright() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try writeLegacyState(to: folder, transposed: true)

        let store = DocumentStore()
        await store.openFolder(folder)

        let page = store.state.pages[0]
        // The document is plainly taller than it is wide, so the page must
        // hold the shape upright.
        #expect(!page.transposedRatio)
        let target = try #require(store.state.outputRatio(for: page))
        #expect(abs(target - passport) < 0.001)

        // And the crop was reshaped to match, so nothing is stretched.
        let size = try #require(store.sourceSizes[page.source])
        let crop = try #require(page.crop)
        #expect(abs(CropGeometry.exportedRatio(crop, sourceSize: size) - passport) < 0.001)
    }

    @Test func theRepairIsWrittenBackAndNotRedoneEveryTime() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try writeLegacyState(to: folder, transposed: true)

        let store = DocumentStore()
        await store.openFolder(folder)
        store.saveImmediately()

        let saved = try #require(try StateStore.load(from: folder))
        #expect(saved.version == ProjectState.currentVersion)
        #expect(!saved.pages[0].transposedRatio)

        // A page deliberately laid sideways afterwards stays that way.
        store.toggleCropOrientation(forPageID: store.state.pages[0].id)
        store.saveImmediately()

        let reopened = DocumentStore()
        await reopened.openFolder(folder)
        #expect(reopened.state.pages[0].transposedRatio)
    }

    @Test func aPageAlreadyPointingTheRightWayIsLeftAlone() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try writeLegacyState(to: folder, transposed: false)

        let store = DocumentStore()
        await store.openFolder(folder)
        #expect(!store.state.pages[0].transposedRatio)
    }

    @Test func switchingStraighteningOnPointsThePageTheRightWay() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = DocumentStore()
        await store.openFolder(folder)
        store.setAspectRatio(AspectRatio(width: 88, height: 125))
        let id = store.state.pages[0].id

        // Claim the wrong way round, then start straightening: the corners
        // must win, since they are what gets mapped onto the shape.
        store.toggleCropOrientation(forPageID: id)
        #expect(store.state.pages[0].transposedRatio)

        store.setQuad(portraitDocument, forPageID: id)
        #expect(!store.state.pages[0].transposedRatio)
    }

    @Test func aStraightenedPortraitPageIsNotStretched() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try writeLegacyState(to: folder, transposed: true)

        let store = DocumentStore()
        await store.openFolder(folder)
        let page = store.state.pages[0]
        let target = try #require(store.state.outputRatio(for: page))

        let rendered = try #require(
            PageRenderer.image(for: page, in: folder, outputRatio: target)
        )
        let produced = Double(rendered.width) / Double(rendered.height)
        #expect(abs(produced - passport) < 0.02)
        // Portrait, as a passport cover is.
        #expect(rendered.height > rendered.width)
    }
}

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import IdFit

@MainActor
@Suite struct BulkRotationTests {
    private func makeFolder(_ names: [String]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("id-fit-bulk-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in names {
            let context = CGContext(
                data: nil, width: 900, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
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

    @Test func severalPagesTurnTogether() async throws {
        let folder = try makeFolder(["a.png", "b.png", "c.png"])
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = DocumentStore()
        await store.openFolder(folder)
        store.setAspectRatio(AspectRatio(width: 210, height: 297))

        let chosen = [store.state.pages[0].id, store.state.pages[2].id]
        store.rotatePages(ids: chosen, by: 90)

        #expect(store.state.pages[0].rotation == 90)
        #expect(store.state.pages[1].rotation == 0)
        #expect(store.state.pages[2].rotation == 90)
        // Each turned page holds the shape sideways, as a single turn does.
        #expect(store.state.pages[0].transposedRatio)
        #expect(!store.state.pages[1].transposedRatio)
        #expect(store.state.pages[2].transposedRatio)
    }

    @Test func turningAllPagesTwiceLeavesThemAsTheyWere() async throws {
        let folder = try makeFolder(["a.png", "b.png"])
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = DocumentStore()
        await store.openFolder(folder)
        store.setAspectRatio(AspectRatio(width: 88, height: 125))
        let before = store.state.pages

        let all = store.state.pages.map(\.id)
        store.rotatePages(ids: all, by: 90)
        store.rotatePages(ids: all, by: -90)

        #expect(store.state.pages.map(\.rotation) == before.map(\.rotation))
        #expect(store.state.pages.map(\.transposedRatio) == before.map(\.transposedRatio))
        #expect(store.state.pages.map(\.crop) == before.map(\.crop))
    }

    @Test func aBulkTurnIsSaved() async throws {
        let folder = try makeFolder(["a.png", "b.png"])
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = DocumentStore()
        await store.openFolder(folder)
        store.rotatePages(ids: store.state.pages.map(\.id), by: -90)
        store.saveDocument()

        let reopened = DocumentStore()
        await reopened.openFolder(folder)
        #expect(reopened.state.pages.allSatisfy { $0.rotation == 270 })
    }

    @Test func anEmptySelectionChangesNothing() async throws {
        let folder = try makeFolder(["a.png"])
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = DocumentStore()
        await store.openFolder(folder)
        let before = store.state.pages
        store.rotatePages(ids: [], by: 90)
        #expect(store.state.pages == before)
    }
}

/// A portrait document photographed at an angle must not be called landscape:
/// the upright box around it tends towards square as the page tilts.
@Suite struct DocumentOrientationTests {
    @Test func theDocumentsOwnEdgesDecideItsOrientation() {
        // A 0.30 × 0.55 portrait sheet turned by 40°, which leaves the box
        // around it all but square.
        let tiltedPortrait = DocumentQuad(
            topLeft: CGPoint(x: 0.562, y: 0.193),
            topRight: CGPoint(x: 0.792, y: 0.386),
            bottomRight: CGPoint(x: 0.438, y: 0.807),
            bottomLeft: CGPoint(x: 0.208, y: 0.614)
        )
        let size = CGSize(width: 1000, height: 1000)

        let box = tiltedPortrait.boundingCrop
        let boxRatio = CropGeometry.exportedRatio(box, sourceSize: size)
        let document = tiltedPortrait.rectifiedSize(sourceSize: size)
        let documentRatio = document.width / document.height

        // The box looks almost square and would be a coin toss…
        #expect(abs(boxRatio - 1) < 0.15)
        // …while the sheet itself is plainly taller than it is wide.
        #expect(documentRatio < 0.8)
    }
}

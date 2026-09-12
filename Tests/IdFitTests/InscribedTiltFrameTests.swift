import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import IdFit

/// Turning a page that nobody framed used to leave it unframed: the slider
/// turned the scan and the corners it brought in were somebody else's problem.
/// A page under the slider is framed by the largest upright rectangle the turn
/// leaves standing.
@Suite struct InscribedTiltFrameTests {
    private let source = CGSize(width: 2000, height: 3000)

    /// Whether the turned rectangle a crop stands for lies inside the scan.
    private func liesInside(_ crop: CropRect, tilt: Double, size: CGSize) -> Bool {
        TiltGeometry.derivedQuad(crop: crop, tilt: tilt, sourceSize: size).corners.allSatisfy {
            $0.x >= -1e-6 && $0.x <= 1 + 1e-6 && $0.y >= -1e-6 && $0.y <= 1 + 1e-6
        }
    }

    /// How much of the scan a crop covers.
    private func area(_ crop: CropRect) -> Double { crop.width * crop.height }

    @Test func theFrameIsInsideTheTurnedPageAndCentredOnIt() {
        for tilt in [-30.0, -7.0, -0.4, 0.4, 3.0, 12.0, 45.0] {
            let crop = TiltGeometry.inscribed(outputRatio: nil, tilt: tilt, sourceSize: source)
            #expect(liesInside(crop, tilt: tilt, size: source), "tilt \(tilt)")
            #expect(abs(crop.x + crop.width / 2 - 0.5) < 1e-6, "centred across, tilt \(tilt)")
            #expect(abs(crop.y + crop.height / 2 - 0.5) < 1e-6, "centred down, tilt \(tilt)")
        }
    }

    /// The point of the whole thing: nothing larger fits. Nudging either side
    /// outwards has to push the turned rectangle off the scan.
    @Test func nothingLargerWouldFit() {
        for tilt in [-9.0, 2.0, 20.0] {
            let crop = TiltGeometry.inscribed(outputRatio: nil, tilt: tilt, sourceSize: source)
            let wider = CropRect(
                x: crop.x - 0.005, y: crop.y,
                width: crop.width + 0.01, height: crop.height
            )
            let taller = CropRect(
                x: crop.x, y: crop.y - 0.005,
                width: crop.width, height: crop.height + 0.01
            )
            #expect(!liesInside(wider, tilt: tilt, size: source), "wider still fits at \(tilt)")
            #expect(!liesInside(taller, tilt: tilt, size: source), "taller still fits at \(tilt)")
        }
    }

    /// Free of a common format the frame meets the turned page on all four
    /// sides, which is more of the scan than the scan's own shape can hold.
    @Test func aFreeShapeKeepsMoreThanTheScansOwnShapeCould() {
        let tilt = 6.0
        let free = TiltGeometry.inscribed(outputRatio: nil, tilt: tilt, sourceSize: source)
        let sameShape = TiltGeometry.fitted(
            CropRect(x: 0, y: 0, width: 1, height: 1), tilt: tilt, sourceSize: source
        )
        #expect(area(free) > area(sameShape))
        #expect(liesInside(sameShape, tilt: tilt, size: source))
    }

    /// With a format to keep, the frame keeps it — and is still the largest
    /// one of that shape the turn allows.
    @Test func aCommonFormatIsKeptAndFilled() {
        let tilt = 8.0
        let ratio = 210.0 / 297
        let crop = TiltGeometry.inscribed(outputRatio: ratio, tilt: tilt, sourceSize: source)

        #expect(abs(CropGeometry.exportedRatio(crop, sourceSize: source) - ratio) < 0.001)
        #expect(liesInside(crop, tilt: tilt, size: source))

        let grown = CropRect(
            x: crop.x - crop.width * 0.005, y: crop.y - crop.height * 0.005,
            width: crop.width * 1.01, height: crop.height * 1.01
        )
        #expect(!liesInside(grown, tilt: tilt, size: source), "a larger one of the same shape fits")
    }

    /// A page turned on its side holds the shared shape the other way round,
    /// and the frame has to be measured in the space the crop lives in.
    @Test func aQuarterTurnedPageHoldsTheFormatSideways() {
        let crop = TiltGeometry.inscribed(
            outputRatio: 210.0 / 297, rotation: 90, tilt: 5, sourceSize: source
        )
        #expect(abs(CropGeometry.exportedRatio(crop, sourceSize: source, rotation: 90) - 210.0 / 297) < 0.001)
        #expect(liesInside(crop, tilt: 5, size: source))
    }

    @Test func withoutATurnTheFrameIsTheWholeScanOrTheFormatCentredOnIt() {
        let whole = TiltGeometry.inscribed(outputRatio: nil, tilt: 0, sourceSize: source)
        #expect(whole == CropRect(x: 0, y: 0, width: 1, height: 1))

        let formatted = TiltGeometry.inscribed(outputRatio: 1, tilt: 0, sourceSize: source)
        #expect(formatted == CropGeometry.centeredCrop(outputRatio: 1, sourceSize: source))
    }

    /// A long page turned far is where the two conditions stop meeting at a
    /// rectangle with any width, and the answer comes from one of them alone.
    @Test func aLongPageTurnedFarStillGetsARealRectangle() {
        let narrow = CGSize(width: 400, height: 3000)
        for tilt in [20.0, 35.0, 45.0] {
            let crop = TiltGeometry.inscribed(outputRatio: nil, tilt: tilt, sourceSize: narrow)
            #expect(crop.width > 0 && crop.height > 0, "tilt \(tilt)")
            #expect(liesInside(crop, tilt: tilt, size: narrow), "tilt \(tilt)")
        }
    }
}

/// The same thing seen from the document: what the slider does to a page the
/// user has not framed, and what it must not do to one they have.
@MainActor
@Suite struct TiltFramingTests {
    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("id-fit-tilt-framing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let context = CGContext(
            data: nil, width: 800, height: 1200, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 800, height: 1200))
        let destination = CGImageDestinationCreateWithURL(
            folder.appendingPathComponent("scan.png") as CFURL,
            UTType.png.identifier as CFString, 1, nil
        )!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(destination))
        return folder
    }

    /// Detection finds nothing on a featureless scan, which is exactly the
    /// page this is about.
    private func openUnframed() async throws -> (DocumentStore, URL) {
        let folder = try makeFolder()
        let store = DocumentStore()
        await store.openFolder(folder)
        await store.redetectEdgesOnAllPages()
        return (store, folder)
    }

    @Test func turningAnUnframedPageFramesIt() async throws {
        let (store, folder) = try await openUnframed()
        defer { try? FileManager.default.removeItem(at: folder) }
        let page = try #require(store.state.pages.first)
        #expect(page.crop == nil)

        store.setTilt(4, forPageID: page.id)

        let size = try #require(store.sourceSizes[page.source])
        let crop = try #require(store.state.pages[0].crop)
        #expect(crop.isClose(to: TiltGeometry.inscribed(
            outputRatio: nil, tilt: store.state.pages[0].tilt, sourceSize: size
        )))
        // And the turned rectangle it stands for is inside the scan.
        let quad = TiltGeometry.derivedQuad(
            crop: crop, tilt: store.state.pages[0].tilt, sourceSize: size
        )
        #expect(quad.corners.allSatisfy {
            $0.x >= -1e-6 && $0.x <= 1 + 1e-6 && $0.y >= -1e-6 && $0.y <= 1 + 1e-6
        })
    }

    /// The frame keeps step with the slider rather than being made once and
    /// then merely shrunk.
    @Test func theFrameFollowsTheSliderAndLetsGoAtZero() async throws {
        let (store, folder) = try await openUnframed()
        defer { try? FileManager.default.removeItem(at: folder) }
        let id = try #require(store.state.pages.first).id

        store.setTilt(3, forPageID: id)
        let small = try #require(store.state.pages[0].crop)
        store.setTilt(12, forPageID: id)
        let smaller = try #require(store.state.pages[0].crop)
        #expect(smaller.width * smaller.height < small.width * small.height)

        store.setTilt(3, forPageID: id)
        let back = try #require(store.state.pages[0].crop)
        #expect(back.isClose(to: small), "the frame grows back as the turn comes out")

        // Straight again is unframed again, which is what hands the page back
        // its draw gesture.
        store.setTilt(0, forPageID: id)
        #expect(store.state.pages[0].crop == nil)
    }

    /// A framing somebody chose is theirs. The turn may slide or shrink it,
    /// never replace it.
    @Test func aFramingThatWasChosenIsNotOverruled() async throws {
        let (store, folder) = try await openUnframed()
        defer { try? FileManager.default.removeItem(at: folder) }
        let id = try #require(store.state.pages.first).id

        let mine = CropRect(x: 0.1, y: 0.1, width: 0.4, height: 0.3)
        store.drawCrop(mine, onPageID: id)
        store.setTilt(5, forPageID: id)

        let crop = try #require(store.state.pages[0].crop)
        #expect(abs(crop.width - mine.width) < 0.01)
        #expect(abs(crop.height - mine.height) < 0.01)
        #expect(abs(crop.x - mine.x) < 0.01)
    }

    /// Resetting a turned page cannot mean "no crop" — the whole of it is the
    /// largest rectangle the turn leaves standing.
    @Test func resettingATurnedPageGivesBackTheWholeTurnedPage() async throws {
        let (store, folder) = try await openUnframed()
        defer { try? FileManager.default.removeItem(at: folder) }
        let id = try #require(store.state.pages.first).id

        store.setTilt(6, forPageID: id)
        store.drawCrop(CropRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3), onPageID: id)
        store.resetCrop(forPageID: id)

        let size = try #require(store.sourceSizes[store.state.pages[0].source])
        let crop = try #require(store.state.pages[0].crop)
        #expect(crop.isClose(to: TiltGeometry.inscribed(
            outputRatio: nil, tilt: store.state.pages[0].tilt, sourceSize: size
        )))
    }

    /// With a common format the frame keeps the shape every other page has.
    @Test func aTurnedPageUnderACommonFormatKeepsTheFormat() async throws {
        let (store, folder) = try await openUnframed()
        defer { try? FileManager.default.removeItem(at: folder) }
        let id = try #require(store.state.pages.first).id
        store.setAspectRatio(AspectRatio(width: 210, height: 297))

        store.setTilt(7, forPageID: id)

        let page = store.state.pages[0]
        let size = try #require(store.sourceSizes[page.source])
        let crop = try #require(page.crop)
        let target = try #require(store.state.outputRatio(for: page))
        #expect(abs(CropGeometry.exportedRatio(crop, sourceSize: size, rotation: page.rotation) - target) < 0.01)
        #expect(crop.isClose(to: TiltGeometry.inscribed(
            outputRatio: target, rotation: page.rotation, tilt: page.tilt, sourceSize: size
        )))
    }
}

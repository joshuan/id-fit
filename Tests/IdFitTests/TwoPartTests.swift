import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import IdFit

@MainActor
@Suite struct TwoPartTests {
    private let top = DocumentQuad(
        topLeft: CGPoint(x: 0.10, y: 0.10), topRight: CGPoint(x: 0.65, y: 0.15),
        bottomRight: CGPoint(x: 0.70, y: 0.35), bottomLeft: CGPoint(x: 0.08, y: 0.40)
    )
    private let bottom = DocumentQuad(
        topLeft: CGPoint(x: 0.25, y: 0.60), topRight: CGPoint(x: 0.78, y: 0.55),
        bottomRight: CGPoint(x: 0.75, y: 0.90), bottomLeft: CGPoint(x: 0.28, y: 0.85)
    )

    private func scan() -> CGImage {
        let context = CGContext(data: nil, width: 800, height: 1000, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0, green: 0.6, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 800, height: 1000))
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        for (quad, color) in [(top, CGColor(colorSpace: space, components: [1, 0, 0, 1])!),
                              (bottom, CGColor(colorSpace: space, components: [0, 0, 1, 1])!)] {
            context.setFillColor(color)
            context.beginPath()
            for (index, point) in quad.corners.enumerated() {
                let pixel = CGPoint(x: point.x * 800, y: (1 - point.y) * 1000)
                if index == 0 { context.move(to: pixel) } else { context.addLine(to: pixel) }
            }
            context.closePath()
            context.fillPath()
        }
        return context.makeImage()!
    }

    private func color(_ image: CGImage, x: Double, y: Double) -> (r: Int, g: Int, b: Int) {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                                    bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        let offset = (Int(y * Double(image.height)) * image.width + Int(x * Double(image.width))) * 4
        return (Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2]))
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("id-fit-parts-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try ImageWriter.write(scan(), to: folder.appendingPathComponent("scan.png"), type: .png, inheritingMetadataFrom: nil)
        return folder
    }

    @Test(arguments: TwoPartComposition.Layout.allCases)
    func eachRegionIsRectifiedAndPlacedInDrawingOrderOnWhite(_ layout: TwoPartComposition.Layout) throws {
        // Deliberately draw the bottom part first: geometric position cannot
        // decide the ordering of the result.
        let composition = TwoPartComposition(regions: [bottom, top], layout: layout)
        let image = try #require(TwoPartCompositor.render(scan(), composition: composition, rotation: 0))
        let first = color(image, x: layout == .vertical ? 0.5 : 0.25, y: layout == .vertical ? 0.25 : 0.5)
        let second = color(image, x: layout == .vertical ? 0.5 : 0.75, y: layout == .vertical ? 0.75 : 0.5)
        #expect(first.b > 230 && first.r < 25 && first.g < 25)
        #expect(second.r > 230 && second.b < 25 && second.g < 25)
        let border = color(image, x: 0.005, y: 0.005)
        #expect(border.r == 255 && border.g == 255 && border.b == 255)
        #expect(image.alphaInfo == .noneSkipLast)
        #expect(layout == .vertical ? image.height > image.width : image.width > image.height)
    }

    @Test func rotatingPartsDoesNotReverseTheirOrder() throws {
        let image = try #require(TwoPartCompositor.render(
            scan(), composition: TwoPartComposition(regions: [top, bottom]), rotation: 180
        ))
        let first = color(image, x: 0.5, y: 0.25)
        let second = color(image, x: 0.5, y: 0.75)
        #expect(first.r > 230 && first.b < 25)
        #expect(second.b > 230 && second.r < 25)
    }

    @Test func incompleteOrCrossedRegionsCannotBeExportedAsAWholeScan() throws {
        #expect(TwoPartCompositor.render(scan(), composition: TwoPartComposition(regions: [top]), rotation: 0) == nil)
        var crossed = top
        crossed.topLeft = top.bottomRight
        crossed.bottomRight = top.topLeft
        #expect(!crossed.isConvex)
        #expect(TwoPartCompositor.render(scan(), composition: TwoPartComposition(regions: [crossed, bottom]), rotation: 0) == nil)
    }

    @Test func modeIsExplicitAndDetectionLeavesItAlone() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = DocumentStore()
        await store.openFolder(folder)
        let id = store.state.pages[0].id
        #expect(store.state.pages[0].composition == nil)
        store.setTwoPartMode(true, forPageID: id)
        store.addPart(bottom, forPageID: id)
        store.addPart(top, forPageID: id)
        store.addPart(top, forPageID: id)
        store.setPartLayout(.horizontal, forPageID: id)
        let page = store.state.pages[0]
        #expect(page.composition?.regions == [bottom, top])
        await store.redetectEdgesOnAllPages()
        #expect(store.state.pages[0] == page)
        store.saveDocument()
        let reopened = DocumentStore()
        await reopened.openFolder(folder)
        #expect(reopened.state.pages[0] == page)
        store.resetPage(forPageID: id)
        #expect(store.state.pages[0].composition == nil)
        #expect(!OriginalsWriter.isEdited(store.state.pages[0]))
    }

    @Test func movingCornersUpdatesOnlyThatPartAndTheResultKey() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = DocumentStore()
        await store.openFolder(folder)
        let id = store.state.pages[0].id
        store.setTwoPartMode(true, forPageID: id)
        store.addPart(top, forPageID: id)
        store.addPart(bottom, forPageID: id)
        let before = store.state.pages[0]
        var edited = top
        edited.topLeft.x += 0.02
        store.setPart(edited, at: 0, forPageID: id)
        let after = store.state.pages[0]
        #expect(after.composition?.regions == [edited, bottom])
        #expect(PagePreviewKey(before) == PagePreviewKey(after))
        #expect(PageThumbnailKey(before) != PageThumbnailKey(after))
        store.redrawParts(forPageID: id)
        store.addPart(bottom, forPageID: id)
        store.addPart(top, forPageID: id)
        #expect(store.state.pages[0].composition?.regions == [bottom, top])
    }

    @Test func exportingFilesMakesAJPGWithBothPartsEvenInOriginalFormat() throws {
        let folder = try makeFolder()
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("id-fit-parts-export-\(UUID())")
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: destination)
        }
        let page = Page(source: SourceRef(file: "scan.png"), composition: TwoPartComposition(regions: [top, bottom]))
        let result = try FileExporter.export(pages: [page], folder: folder, to: destination)
        #expect(result.writtenFiles == ["001.jpg"])
        let file = destination.appendingPathComponent("001.jpg")
        let source = try #require(CGImageSourceCreateWithURL(file as CFURL, nil))
        #expect(CGImageSourceGetType(source) as String? == "public.jpeg")
        let image = try #require(PageRenderer.fullResolutionImage(at: file))
        #expect(color(image, x: 0.5, y: 0.25).r > 230)
        #expect(color(image, x: 0.5, y: 0.75).b > 230)
        #expect(color(image, x: 0.005, y: 0.005).g > 245)
    }

    @Test func applyingACompositionKeepsTheScanAndReopensAsOnePage() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = try Data(contentsOf: folder.appendingPathComponent("scan.png"))
        let store = DocumentStore()
        await store.openFolder(folder)
        let id = store.state.pages[0].id
        store.setTwoPartMode(true, forPageID: id)
        store.addPart(top, forPageID: id)
        store.addPart(bottom, forPageID: id)
        await store.applyToOriginals(pageIDs: [id], makeBackup: true)
        #expect(store.lastError == nil)
        #expect(store.state.pages[0].source.file == "scan-parts.jpg")
        #expect(store.state.pages[0].composition == nil)
        #expect(store.lastApplyResult?.backupFolder == nil)
        #expect(try Data(contentsOf: folder.appendingPathComponent("scan.png")) == original)
        let reopened = DocumentStore()
        await reopened.openFolder(folder)
        #expect(reopened.state.pages.count == 1)
        #expect(reopened.state.pages[0].source.file == "scan-parts.jpg")
        #expect(!OriginalsWriter.isEdited(reopened.state.pages[0]))
    }

    @Test func savingOneCombinedJPGPreservesTheEditableComposition() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = DocumentStore()
        await store.openFolder(folder)
        let id = store.state.pages[0].id
        store.setTwoPartMode(true, forPageID: id)
        store.addPart(top, forPageID: id)
        store.addPart(bottom, forPageID: id)
        let page = store.state.pages[0]
        await store.exportCombinedJPG(forPageID: id, to: folder.appendingPathComponent("combined.jpg"))
        #expect(store.lastError == nil)
        #expect(store.state.pages[0] == page)
        let reopened = DocumentStore()
        await reopened.openFolder(folder)
        #expect(reopened.state.pages == [page])
        let original = try Data(contentsOf: folder.appendingPathComponent("scan.png"))
        await store.exportCombinedJPG(forPageID: id, to: folder.appendingPathComponent("scan.png"))
        #expect(store.lastError != nil)
        #expect(try Data(contentsOf: folder.appendingPathComponent("scan.png")) == original)
    }
}

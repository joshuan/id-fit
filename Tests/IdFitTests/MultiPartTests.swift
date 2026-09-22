import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Testing
@testable import IdFit

@Suite struct MultiPartTests {
    private static let regions = [
        DocumentQuad(CropRect(x: 0.08, y: 0.08, width: 0.34, height: 0.34)),
        DocumentQuad(CropRect(x: 0.58, y: 0.08, width: 0.34, height: 0.34)),
        DocumentQuad(CropRect(x: 0.08, y: 0.58, width: 0.34, height: 0.34)),
        DocumentQuad(CropRect(x: 0.58, y: 0.58, width: 0.34, height: 0.34))
    ]
    private static let colors: [[CGFloat]] = [[1, 0, 0, 1], [0, 1, 0, 1], [0, 0, 1, 1], [1, 1, 0, 1]]

    private static func scan(count: Int) -> CGImage {
        let context = CGContext(data: nil, width: 1000, height: 1000, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1000, height: 1000))
        for index in 0..<count {
            let crop = regions[index].boundingCrop
            context.setFillColor(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: colors[index])!)
            context.fill(CGRect(x: crop.x * 1000, y: (1 - crop.y - crop.height) * 1000,
                                width: crop.width * 1000, height: crop.height * 1000))
        }
        return context.makeImage()!
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) -> [Int] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes {
            let context = CGContext(data: $0.baseAddress, width: image.width, height: image.height,
                                    bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        let offset = (y * image.width + x) * 4
        return bytes[offset..<(offset + 3)].map(Int.init)
    }

    @Test(arguments: [2, 3, 4], PartComposition.Layout.allCases)
    func allPartsAndEveryGapAreRenderedInChosenOrder(count: Int, layout: PartComposition.Layout) throws {
        let order = Array((0..<count).reversed())
        let composition = PartComposition(regions: order.map { Self.regions[$0] }, layout: layout, partCount: count)
        let image = try #require(PartCompositor.render(Self.scan(count: count), composition: composition, rotation: 0))
        let vertical = layout == .vertical
        // The source parts are 340px squares; rectification may round an edge
        // by one pixel. The cross-axis dimension includes exactly two margins.
        let short = vertical ? image.width : image.height
        let margin = 9
        let gap = 2
        let side = short - 2 * margin
        #expect((vertical ? image.height : image.width) == count * side + (count - 1) * gap + 2 * margin)
        for (slot, source) in order.enumerated() {
            let along = margin + slot * (side + gap) + side / 2
            let actual = pixel(image, x: vertical ? short / 2 : along, y: vertical ? along : short / 2)
            let expected = Self.colors[source].prefix(3).map { Int($0 * 255) }
            #expect(zip(actual, expected).allSatisfy { abs($0 - $1) < 10 })
            if slot < count - 1 {
                let gapStart = margin + slot * (side + gap) + side
                for offset in 0..<2 {
                    #expect(pixel(image, x: vertical ? short / 2 : gapStart + offset,
                                  y: vertical ? gapStart + offset : short / 2) == [255, 255, 255])
                }
            }
        }
        #expect(pixel(image, x: image.width - 1, y: image.height - 1) == [255, 255, 255])
    }

    @Test(arguments: [2, 3, 4])
    func visionFindsTheNumberAndLocationsOfSeparateParts(count: Int) throws {
        let detection = try #require(DocumentEdgeDetector.detect(in: Self.scan(count: count)))
        #expect(detection.regions.count == count)
        for (actual, expected) in zip(detection.regions, Self.regions.prefix(count)) {
            #expect(actual.boundingCrop.isClose(to: expected.boundingCrop, tolerance: 0.025))
        }
    }

    @Test func photosAndDuplicateBordersAreNotSeparateParts() {
        let photo = DocumentQuad(CropRect(x: 0.12, y: 0.12, width: 0.15, height: 0.18))
        let border = DocumentQuad(CropRect(x: 0.09, y: 0.09, width: 0.32, height: 0.32))
        let found = DocumentEdgeDetector.separateRegions(from: [photo, border] + Self.regions.reversed())
        #expect(found == Self.regions)
        #expect(DocumentEdgeDetector.separateRegions(from: [photo, border, Self.regions[0]]) == [Self.regions[0]])
    }

    @Test func detectionNeverOffersMoreThanFourParts() {
        let candidates = (0..<6).map { index in
            DocumentQuad(CropRect(x: 0.05 + Double(index % 3) * 0.32,
                                  y: 0.05 + Double(index / 3) * 0.48, width: 0.24, height: 0.35))
        }
        #expect(DocumentEdgeDetector.separateRegions(from: candidates).count == 4)
    }

    @Test func oldTwoPartDocumentsLoadAndNewCountsRoundTrip() throws {
        let old = """
        {"regions":[],"layout":"horizontal"}
        """
        let legacy = try JSONDecoder().decode(PartComposition.self, from: Data(old.utf8))
        #expect(legacy.partCount == 2)
        #expect(legacy.layout == .horizontal)
        for count in 2...4 {
            let composition = PartComposition(regions: Array(Self.regions.prefix(count)), partCount: count)
            #expect(try JSONDecoder().decode(PartComposition.self, from: JSONEncoder().encode(composition)) == composition)
            var partial = composition
            partial.regions.removeLast()
            #expect(!partial.isComplete)
            #expect(PartCompositor.render(Self.scan(count: count), composition: partial, rotation: 0) == nil)
        }
    }

    @Test func tapCyclesButHeldClicksAssignSlotsWithoutCyclingOnRelease() {
        var composition = PartComposition(regions: Self.regions, partCount: 4)
        var ordering = PartOrdering()
        ordering.begin()
        ordering.begin() // Key repeat must not start a second press.
        if ordering.end() { composition.cycleOrder() }
        #expect(composition.regions == [Self.regions[1], Self.regions[2], Self.regions[3], Self.regions[0]])
        ordering.begin()
        for part in [2, 3, 2] {
            let slot = ordering.select(part: part, count: 4)!
            composition.movePart(at: part, to: slot)
        }
        #expect(composition.regions == [Self.regions[3], Self.regions[0], Self.regions[1], Self.regions[2]])
        #expect(ordering.nextSlot == 3)
        let repeated = ordering.select(part: 0, count: 4)
        #expect(repeated == nil)
        let cycleAfterClicks = ordering.end()
        #expect(!cycleAfterClicks)
        ordering.begin()
        let outside = ordering.select(part: nil, count: 4)
        #expect(outside == nil)
        let cycleAfterOutsideClick = ordering.end()
        #expect(!cycleAfterOutsideClick) // Clicking outside a part does not cycle.
    }

    @MainActor
    @Test func detectedModesCanBeChangedReorderedSavedAndRedetected() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("id-fit-multipart-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try ImageWriter.write(Self.scan(count: 4), to: folder.appendingPathComponent("scan.png"),
                              type: .png, inheritingMetadataFrom: nil)
        let store = DocumentStore()
        await store.openFolder(folder)
        let id = store.state.pages[0].id
        #expect(store.state.pages[0].composition == nil)
        await store.redetectEdges(forPageIDs: [id])
        let detected = try #require(store.state.pages[0].composition)
        #expect(detected.partCount == 4)
        #expect(detected.isComplete)
        store.cyclePartOrder(forPageID: id)
        store.movePart(at: 2, to: 0, forPageID: id)
        #expect(store.state.pages[0].composition?.regions.first == detected.regions[3])
        store.setPartCount(3, forPageID: id)
        #expect(store.state.pages[0].composition?.isComplete == true)
        store.setPartCount(4, forPageID: id)
        #expect(store.state.pages[0].composition?.isComplete == false)
        store.addPart(detected.regions[0], forPageID: id)
        store.addPart(detected.regions[0], forPageID: id)
        #expect(store.state.pages[0].composition?.regions.count == 4)
        store.saveDocument()
        let reopened = DocumentStore()
        await reopened.openFolder(folder)
        #expect(reopened.state.pages == store.state.pages)
        store.setPartCount(1, forPageID: id)
        #expect(store.state.pages[0].composition == nil)
        #expect(store.state.pages[0].quad == detected.regions[3])
        store.setPartCount(2, forPageID: id)
        await store.redetectEdges(forPageIDs: [id])
        #expect(store.state.pages[0].composition == detected)
    }

    @MainActor
    @Test(arguments: [2, 3, 4], ["png", "jpg", "jpeg", "tiff"])
    func applyReplacesTheSourceInItsOwnFormat(count: Int, ext: String) async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let name = "scan.\(ext)"
        let file = folder.appendingPathComponent(name)
        let type = try #require(ImageWriter.contentType(forExtension: ext))
        try ImageWriter.write(Self.scan(count: count), to: file, type: type, inheritingMetadataFrom: nil)
        let original = try Data(contentsOf: file)
        let store = DocumentStore()
        await store.openFolder(folder)
        let id = store.state.pages[0].id
        store.setPartCount(count, forPageID: id)
        for region in Self.regions.prefix(count).reversed() { store.addPart(region, forPageID: id) }
        store.setPartLayout(.horizontal, forPageID: id)
        let expected = try #require(PageRenderer.image(for: store.state.pages[0], in: folder, outputRatio: nil))

        await store.applyToOriginals(makeBackup: true)

        let result = try #require(store.lastApplyResult)
        #expect(result.failures.isEmpty)
        #expect(result.changedFiles == [name])
        #expect(result.createdFiles.isEmpty)
        #expect(result.newSources.isEmpty)
        #expect(store.state.pages[0].source.file == name)
        #expect(!OriginalsWriter.isEdited(store.state.pages[0]))
        #expect(store.state.retainedSources.isEmpty)
        let source = try #require(CGImageSourceCreateWithURL(file as CFURL, nil))
        #expect(CGImageSourceGetType(source) as String? == type.identifier)
        let output = try #require(PageRenderer.fullResolutionImage(at: file))
        #expect(output.width == expected.width)
        #expect(output.height == expected.height)
        for slot in 0..<count {
            let actual = pixel(output, x: (2 * slot + 1) * output.width / (2 * count), y: output.height / 2)
            let color = Self.colors[count - slot - 1].prefix(3).map { Int($0 * 255) }
            #expect(zip(actual, color).allSatisfy { abs($0 - $1) < 15 })
        }
        #expect(try Data(contentsOf: folder.appendingPathComponent(".id-fit-originals/\(name)")) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { !$0.hasPrefix(".") && !$0.hasSuffix(".idfit") } == [name])
        let reopened = DocumentStore()
        await reopened.openFolder(folder)
        #expect(reopened.state.pages == store.state.pages)
        let applied = try Data(contentsOf: file)
        await reopened.applyToOriginals(makeBackup: false)
        #expect(reopened.lastApplyResult == nil)
        #expect(try Data(contentsOf: file) == applied)
    }

    @MainActor
    @Test(arguments: [false, true])
    func onlyDuplicatedCompositionsCreateAdditionalFiles(selectedOnly: Bool) async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("scan.png")
        try ImageWriter.write(Self.scan(count: 4), to: file, type: .png, inheritingMetadataFrom: nil)
        let original = try Data(contentsOf: file)
        let store = DocumentStore()
        await store.openFolder(folder)
        let first = store.state.pages[0].id
        store.setPartCount(4, forPageID: first)
        for region in Self.regions { store.addPart(region, forPageID: first) }
        store.duplicatePage(id: first)
        let second = store.state.pages[1].id
        store.cyclePartOrder(forPageID: second)
        let before = store.state.pages[0]
        await store.applyToOriginals(pageIDs: selectedOnly ? [second] : nil, makeBackup: false)

        let result = try #require(store.lastApplyResult)
        #expect(result.failures.isEmpty)
        #expect(result.createdFiles == ["scan-2.png"])
        #expect(result.changedFiles == (selectedOnly ? [] : ["scan.png"]))
        #expect(store.state.pages.map(\.source.file) == ["scan.png", "scan-2.png"])
        let copy = try #require(PageRenderer.fullResolutionImage(at: folder.appendingPathComponent("scan-2.png")))
        #expect(pixel(copy, x: copy.width / 2, y: copy.height / 8) == [0, 255, 0])
        if selectedOnly {
            #expect(try Data(contentsOf: file) == original)
            #expect(store.state.pages[0] == before)
        } else {
            let replaced = try #require(PageRenderer.fullResolutionImage(at: file))
            #expect(pixel(replaced, x: replaced.width / 2, y: replaced.height / 8) == [255, 0, 0])
        }
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(".id-fit-originals").path))
    }

    @Test func incompleteCompositionsNeverRewriteOrCreateFiles() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("scan.png")
        try ImageWriter.write(Self.scan(count: 4), to: file, type: .png, inheritingMetadataFrom: nil)
        let original = try Data(contentsOf: file)
        let page = Page(source: SourceRef(file: "scan.png"),
                        composition: PartComposition(regions: Array(Self.regions.prefix(3)), partCount: 4))
        let result = try OriginalsWriter.apply(pages: [page], folder: folder, makeBackup: true)
        #expect(result.changedFiles.isEmpty && result.createdFiles.isEmpty && result.appliedPageIDs.isEmpty)
        #expect(try Data(contentsOf: file) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["scan.png"])
    }

    @Test(arguments: PartComposition.Layout.allCases, [0, 90])
    func applyingAPDFCompositionReplacesOnlyItsPageAtTheCorrectScale(layout: PartComposition.Layout, rotation: Int) throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("scan.pdf")
        try writePDF(to: file)
        let original = try Data(contentsOf: file)
        let source = SourceRef(file: "scan.pdf", pdfPage: 1)
        let page = Page(source: source, rotation: rotation,
                        composition: PartComposition(regions: Self.regions, layout: layout, partCount: 4))
        let expected = try #require(PageRenderer.image(for: page, in: folder, outputRatio: nil))
        let sourceImage = try #require(ThumbnailProvider.shared.renderedImage(for: source, in: folder,
                                                                              maxPixel: PageRenderer.pdfRasterSize))
        let result = try OriginalsWriter.apply(pages: [page], folder: folder, makeBackup: true)
        #expect(result.failures.isEmpty)
        #expect(result.changedFiles == ["scan.pdf"])
        #expect(result.createdFiles.isEmpty)
        #expect(try Data(contentsOf: folder.appendingPathComponent(".id-fit-originals/scan.pdf")) == original)
        let document = try #require(PDFDocument(url: file))
        #expect(document.pageCount == 3)
        #expect(try #require(document.page(at: 0)).bounds(for: .cropBox).size == CGSize(width: 400, height: 600))
        #expect(try #require(document.page(at: 2)).bounds(for: .cropBox).size == CGSize(width: 400, height: 600))
        let bounds = try #require(document.page(at: 1)).bounds(for: .cropBox)
        let scale = 600 / CGFloat(max(sourceImage.width, sourceImage.height))
        #expect(abs(bounds.width - CGFloat(expected.width) * scale) < 0.01)
        #expect(abs(bounds.height - CGFloat(expected.height) * scale) < 0.01)
        let output = try #require(ThumbnailProvider.shared.renderedImage(for: source, in: folder, maxPixel: 1000))
        for slot in 0..<4 {
            let x = layout == .horizontal ? (2 * slot + 1) * output.width / 8 : output.width / 2
            let y = layout == .vertical ? (2 * slot + 1) * output.height / 8 : output.height / 2
            let actual = pixel(output, x: x, y: y)
            let color = Self.colors[slot].prefix(3).map { Int($0 * 255) }
            #expect(zip(actual, color).allSatisfy { abs($0 - $1) < 15 })
        }
    }

    @Test func duplicatedPDFCompositionsStayPDFAndKeepUnselectedPagesIntact() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("scan.pdf")
        try writePDF(to: file)
        let original = try Data(contentsOf: file)
        let first = Page(source: SourceRef(file: "scan.pdf", pdfPage: 1),
                         composition: PartComposition(regions: Self.regions, partCount: 4))
        var second = first
        second.id = UUID()
        second.composition?.cycleOrder()
        let result = try OriginalsWriter.apply(pages: [first, second], folder: folder,
                                               makeBackup: false, pageIDs: [second.id])
        #expect(result.failures.isEmpty)
        #expect(result.changedFiles.isEmpty)
        #expect(result.createdFiles == ["scan-2.pdf"])
        #expect(result.newSources[second.id] == SourceRef(file: "scan-2.pdf", pdfPage: 0))
        #expect(try Data(contentsOf: file) == original)
        let copy = try #require(PDFDocument(url: folder.appendingPathComponent("scan-2.pdf")))
        #expect(copy.pageCount == 1)
        let image = try #require(ThumbnailProvider.shared.renderedImage(for: SourceRef(file: "scan-2.pdf", pdfPage: 0),
                                                                       in: folder, maxPixel: 1000))
        let firstColor = pixel(image, x: image.width / 2, y: image.height / 8)
        #expect(firstColor[1] > 240 && firstColor[0] < 15 && firstColor[2] < 15)
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("id-fit-apply-parts-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func writePDF(to file: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 400, height: 600)
        let context = try #require(CGContext(file as CFURL, mediaBox: &box, nil))
        for _ in 0..<3 {
            context.beginPage(mediaBox: &box)
            context.draw(Self.scan(count: 4), in: box)
            context.endPage()
        }
        context.closePDF()
    }
}

import Foundation
import Testing
@testable import IdFit

/// Guards the invariant behind a nasty class of bug: if the preview key
/// changes while a crop is being dragged, the image reloads, the view holding
/// the gesture is torn down, and the drag dies mid-motion.
@Suite struct PagePreviewKeyTests {
    private let source = SourceRef(file: "scan.png")

    @Test func croppingDoesNotChangeThePreviewKey() {
        let page = Page(source: source)
        var dragged = page

        // A crop drag produces a stream of slightly different crops.
        for step in 1...20 {
            dragged.crop = CropRect(
                x: Double(step) * 0.001,
                y: 0,
                width: 0.5 - Double(step) * 0.001,
                height: 0.5
            )
            #expect(PagePreviewKey(dragged) == PagePreviewKey(page))
        }
    }

    @Test func clearingACropDoesNotChangeThePreviewKey() {
        let cropped = Page(source: source, crop: CropRect(x: 0, y: 0, width: 0.5, height: 0.5))
        var cleared = cropped
        cleared.crop = nil
        #expect(PagePreviewKey(cleared) == PagePreviewKey(cropped))
    }

    @Test func rotationChangesThePreviewKey() {
        let page = Page(source: source)
        var rotated = page
        rotated.rotation = 90
        #expect(PagePreviewKey(rotated) != PagePreviewKey(page))
    }

    @Test func adifferentSourceChangesThePreviewKey() {
        let first = Page(source: source)
        let second = Page(source: SourceRef(file: "other.png"))
        let firstPDFPage = Page(source: SourceRef(file: "doc.pdf", pdfPage: 0))
        let secondPDFPage = Page(source: SourceRef(file: "doc.pdf", pdfPage: 1))

        #expect(PagePreviewKey(first) != PagePreviewKey(second))
        #expect(PagePreviewKey(firstPDFPage) != PagePreviewKey(secondPDFPage))
    }

    @Test func identityOfThePageItselfIsIrrelevant() {
        // Two entries for the same file must share one rendered preview.
        let first = Page(source: source)
        let second = Page(source: source)
        #expect(first.id != second.id)
        #expect(PagePreviewKey(first) == PagePreviewKey(second))
    }
}

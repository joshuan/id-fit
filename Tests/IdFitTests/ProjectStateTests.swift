import Foundation
import Testing
@testable import IdFit

@Suite struct ProjectStateTests {
    @Test func codableRoundTrip() throws {
        let state = ProjectState(
            cropAspectRatio: AspectRatio(width: 210, height: 297),
            pages: [
                Page(source: SourceRef(file: "scan-01.jpg"), rotation: 90,
                     crop: CropRect(x: 0.1, y: 0.2, width: 0.5, height: 0.6)),
                Page(source: SourceRef(file: "scans.pdf", pdfPage: 2)),
            ]
        )
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(ProjectState.self, from: data)
        #expect(decoded == state)
    }

    @Test func decodesMinimalJSONWithDefaults() throws {
        let json = """
        {"pages": [{"source": {"file": "a.jpg"}}]}
        """
        let state = try JSONDecoder().decode(ProjectState.self, from: Data(json.utf8))
        #expect(state.version == ProjectState.currentVersion)
        #expect(state.cropAspectRatio == nil)
        #expect(state.pages.count == 1)
        #expect(state.pages[0].source == SourceRef(file: "a.jpg"))
        #expect(state.pages[0].rotation == 0)
        #expect(state.pages[0].crop == nil)
    }

    @Test func decodesEmptyObject() throws {
        let state = try JSONDecoder().decode(ProjectState.self, from: Data("{}".utf8))
        #expect(state.pages.isEmpty)
        #expect(state.version == ProjectState.currentVersion)
    }

    @Test func reconcileAppendsNewSourcesInDiscoveryOrder() {
        let a = SourceRef(file: "a.jpg")
        let state = ProjectState(pages: [Page(source: a)])
        let b = SourceRef(file: "b.jpg")
        let c = SourceRef(file: "c.jpg")

        let result = state.reconciled(with: [a, b, c])

        #expect(result.pages.map(\.source) == [a, b, c])
        #expect(result.pages[0].id == state.pages[0].id)
    }

    @Test func reconcileKeepsUserOrderAndMissingPages() {
        let a = SourceRef(file: "a.jpg")
        let c = SourceRef(file: "c.jpg")
        let cropped = Page(source: a, crop: CropRect(x: 0, y: 0, width: 0.5, height: 0.5))
        let state = ProjectState(pages: [Page(source: c), cropped])

        // "a.jpg" is gone from the folder, "b.jpg" is new.
        let b = SourceRef(file: "b.jpg")
        let result = state.reconciled(with: [b, c])

        #expect(result.pages.map(\.source) == [c, a, b])
        #expect(result.pages[1].crop == cropped.crop)
        #expect(result.missingSources(given: [b, c]) == [a])
    }

    @Test func reconcileExpandsPDFPagesAsSeparateSources() {
        let pdfPages = (0..<3).map { SourceRef(file: "scans.pdf", pdfPage: $0) }
        let result = ProjectState().reconciled(with: pdfPages)
        #expect(result.pages.map(\.source) == pdfPages)
    }

    @Test func cropClampsIntoUnitSquare() {
        let shifted = CropRect(x: 0.8, y: -0.1, width: 0.5, height: 0.5).clampedToUnitSquare()
        #expect(shifted == CropRect(x: 0.5, y: 0, width: 0.5, height: 0.5))

        let oversized = CropRect(x: 0, y: 0, width: 2, height: 3).clampedToUnitSquare()
        #expect(oversized == CropRect(x: 0, y: 0, width: 1, height: 1))
    }
}

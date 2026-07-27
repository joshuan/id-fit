import Foundation
import Testing
@testable import IdFit

@Suite struct ReorderTests {
    private func makeState(_ names: [String]) -> ProjectState {
        ProjectState(pages: names.map { Page(source: SourceRef(file: $0)) })
    }

    private func fileOrder(_ state: ProjectState) -> [String] {
        state.pages.map(\.source.file)
    }

    @Test func movesPageForward() {
        var state = makeState(["a", "b", "c", "d"])
        state.movePage(id: state.pages[0].id, toIndex: 2)
        #expect(fileOrder(state) == ["b", "c", "a", "d"])
    }

    @Test func movesPageBackward() {
        var state = makeState(["a", "b", "c", "d"])
        state.movePage(id: state.pages[3].id, toIndex: 1)
        #expect(fileOrder(state) == ["a", "d", "b", "c"])
    }

    @Test func movingOntoOwnIndexIsNoop() {
        var state = makeState(["a", "b", "c"])
        state.movePage(id: state.pages[1].id, toIndex: 1)
        #expect(fileOrder(state) == ["a", "b", "c"])
    }

    @Test func clampsOutOfRangeTarget() {
        var state = makeState(["a", "b", "c"])
        state.movePage(id: state.pages[0].id, toIndex: 99)
        #expect(fileOrder(state) == ["b", "c", "a"])

        state.movePage(id: state.pages[2].id, toIndex: -5)
        #expect(fileOrder(state) == ["a", "b", "c"])
    }

    @Test func ignoresUnknownPageID() {
        var state = makeState(["a", "b"])
        state.movePage(id: UUID(), toIndex: 0)
        #expect(fileOrder(state) == ["a", "b"])
    }

    @Test func reorderSurvivesSaveLoadAndRescan() throws {
        var state = makeState(["a.jpg", "b.jpg", "c.jpg"])
        state.movePage(id: state.pages[2].id, toIndex: 0)

        let data = try JSONEncoder().encode(state)
        let reloaded = try JSONDecoder().decode(ProjectState.self, from: data)

        // A rescan reports files in alphabetical order; the saved order wins.
        let discovered = ["a.jpg", "b.jpg", "c.jpg"].map { SourceRef(file: $0) }
        let reconciled = reloaded.reconciled(with: discovered)

        #expect(fileOrder(reconciled) == ["c.jpg", "a.jpg", "b.jpg"])
    }
}

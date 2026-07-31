import Foundation
import Testing
@testable import IdFit

@Suite struct StateStoreTests {
    private func makeTempFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("id-fit-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func loadReturnsNilWhenNoStateFile() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(try StateStore.load(from: folder) == nil)
    }

    @Test func saveAndLoadRoundTrip() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let state = ProjectState(
            cropAspectRatio: AspectRatio(width: 1, height: 1.414),
            pages: [Page(source: SourceRef(file: "scan.png"))]
        )
        try StateStore.save(state, to: folder)
        let loaded = try StateStore.load(from: folder)
        #expect(loaded == state)
    }

    @Test func saveOverwritesPreviousState() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        try StateStore.save(ProjectState(pages: [Page(source: SourceRef(file: "a.jpg"))]), to: folder)
        let second = ProjectState(pages: [Page(source: SourceRef(file: "b.jpg"))])
        try StateStore.save(second, to: folder)
        #expect(try StateStore.load(from: folder) == second)
    }

    @Test func stateFileIsHiddenDotFileInsideFolder() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        try StateStore.save(ProjectState(), to: folder)
        let url = StateStore.stateFileURL(for: folder)
        #expect(url.lastPathComponent == folder.lastPathComponent + ".idfit")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}

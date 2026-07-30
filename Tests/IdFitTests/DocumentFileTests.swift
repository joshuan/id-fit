import Foundation
import Testing
@testable import IdFit

/// The folder's document is a visible `.idfit` file holding JSON, so it can be
/// seen, clicked and reasoned about — not a hidden dotfile.
@MainActor
@Suite struct DocumentFileTests {
    private func makeFolder(files: [String] = []) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("id-fit-document-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in files {
            try Data().write(to: folder.appendingPathComponent(name))
        }
        return folder
    }

    private func names(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    @Test func theDocumentIsVisibleAndHoldsJSON() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        try StateStore.save(ProjectState(pages: [Page(source: SourceRef(file: "a.jpg"))]), to: folder)

        let url = StateStore.stateFileURL(for: folder)
        #expect(url.lastPathComponent == "Document.idfit")
        #expect(!url.lastPathComponent.hasPrefix("."))
        #expect(url.pathExtension == "idfit")

        // Readable as JSON by anything, not just this app.
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        #expect(json?["pages"] != nil)
    }

    @Test func aFolderKeptByTheOldHiddenFileIsPickedUpAndMovedOn() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        // A folder last opened by an earlier version.
        let legacy = folder.appendingPathComponent(StateStore.legacyFileName)
        let saved = ProjectState(
            cropAspectRatio: AspectRatio(width: 88, height: 125),
            pages: [Page(source: SourceRef(file: "a.jpg"), crop: CropRect(x: 0, y: 0, width: 0.5, height: 0.5))]
        )
        try JSONEncoder().encode(saved).write(to: legacy)

        // Its work is read…
        let loaded = try #require(try StateStore.load(from: folder))
        #expect(loaded.cropAspectRatio == AspectRatio(width: 88, height: 125))
        #expect(loaded.pages.count == 1)

        // …and once written back, the visible document replaces the dotfile
        // rather than sitting beside it as a second, stale copy.
        try StateStore.save(loaded, to: folder)
        #expect(try names(in: folder) == ["Document.idfit"])
    }

    @Test func aRenamedDocumentIsStillFoundAndWrittenTo() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let renamed = folder.appendingPathComponent("Passport.idfit")
        try JSONEncoder()
            .encode(ProjectState(pages: [Page(source: SourceRef(file: "a.jpg"))]))
            .write(to: renamed)

        #expect(StateStore.existingStateFile(in: folder)?.lastPathComponent == "Passport.idfit")

        var state = try #require(try StateStore.load(from: folder))
        state.pages.append(Page(source: SourceRef(file: "b.jpg")))
        try StateStore.save(state, to: folder)

        // No second document appears beside the one the folder already uses.
        #expect(try names(in: folder) == ["Passport.idfit"])
        #expect(try StateStore.load(from: folder)?.pages.count == 2)
    }

    @Test func theDocumentIsNotMistakenForAScan() async throws {
        let folder = try makeFolder(files: ["a.jpg", "b.jpg"])
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = DocumentStore()
        await store.openFolder(folder)
        store.saveImmediately()

        // Now that it is a visible file, the scanner has to keep ignoring it.
        let reopened = DocumentStore()
        await reopened.openFolder(folder)
        #expect(reopened.state.pages.map(\.source.file) == ["a.jpg", "b.jpg"])
        #expect(FileManager.default.fileExists(atPath: StateStore.stateFileURL(for: folder).path))
    }

    @Test func clickingTheDocumentOpensTheFolderAroundIt() async throws {
        let folder = try makeFolder(files: ["a.jpg"])
        defer { try? FileManager.default.removeItem(at: folder) }
        try StateStore.save(ProjectState(), to: folder)

        // What Finder hands over when the document is double-clicked.
        let store = DocumentStore()
        await store.openFolderOrParent(of: StateStore.stateFileURL(for: folder))

        #expect(store.folderURL?.standardizedFileURL == folder.standardizedFileURL)
        #expect(store.state.pages.map(\.source.file) == ["a.jpg"])
    }

    @Test func openingAFolderWithNothingToChangeStillMovesItOn() async throws {
        let folder = try makeFolder(files: ["a.jpg"])
        defer { try? FileManager.default.removeItem(at: folder) }

        // A folder whose saved work needs no correction at all: the dotfile
        // must not be kept forever for want of an unrelated edit.
        let store = DocumentStore()
        await store.openFolder(folder)
        store.saveImmediately()
        let settled = try #require(try StateStore.load(from: folder))

        let legacy = folder.appendingPathComponent(StateStore.legacyFileName)
        try FileManager.default.removeItem(at: StateStore.stateFileURL(for: folder))
        try JSONEncoder().encode(settled).write(to: legacy)
        #expect(StateStore.usesLegacyDocument(in: folder))

        let reopened = DocumentStore()
        await reopened.openFolder(folder)

        #expect(!StateStore.usesLegacyDocument(in: folder))
        #expect(try names(in: folder) == ["Document.idfit", "a.jpg"])
    }

    @Test func anEmptyFolderHasNoDocumentYet() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(StateStore.existingStateFile(in: folder) == nil)
        #expect(try StateStore.load(from: folder) == nil)
    }
}

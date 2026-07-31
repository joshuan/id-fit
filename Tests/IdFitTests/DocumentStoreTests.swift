import Foundation
import Testing
@testable import IdFit

@MainActor
@Suite struct DocumentStoreTests {
    private func makeFolder(files: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("id-fit-store-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for name in files {
            try Data().write(to: url.appendingPathComponent(name))
        }
        return url
    }

    private func names(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    /// Looking at a folder is not editing it: somebody who opens a folder to
    /// see what is in it must not find a file left behind afterwards.
    @Test func openingAFolderLeavesNothingInIt() async throws {
        let folder = try makeFolder(files: ["b.jpg", "a.jpg", "notes.txt"])
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = DocumentStore()
        await store.openFolder(folder)

        #expect(store.state.pages.map(\.source.file) == ["a.jpg", "b.jpg"])
        #expect(store.missingSources.isEmpty)
        #expect(store.lastError == nil)
        #expect(try names(in: folder) == ["a.jpg", "b.jpg", "notes.txt"])
        #expect(!store.hasDocument)
        // The work exists, it is simply nowhere yet — which is what the Save
        // button being enabled tells the user.
        #expect(store.hasUnsavedChanges)
        #expect(store.canSave)
    }

    @Test func editingAFolderWithNoDocumentStillLeavesItAlone() async throws {
        let folder = try makeFolder(files: ["a.jpg", "b.jpg"])
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = DocumentStore()
        await store.openFolder(folder)
        store.movePage(id: store.state.pages[1].id, toIndex: 0)
        // Longer than the autosave debounce, which must not fire here.
        try await Task.sleep(for: .milliseconds(900))

        #expect(try names(in: folder) == ["a.jpg", "b.jpg"])
        #expect(store.hasUnsavedChanges)
    }

    @Test func savingWritesADocumentNamedAfterTheFolder() async throws {
        let folder = try makeFolder(files: ["a.jpg", "b.jpg"])
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = DocumentStore()
        await store.openFolder(folder)
        store.movePage(id: store.state.pages[1].id, toIndex: 0)
        store.saveDocument()

        #expect(store.hasDocument)
        #expect(!store.hasUnsavedChanges)
        #expect(!store.canSave)
        #expect(try names(in: folder).contains(folder.lastPathComponent + ".idfit"))
        #expect(try StateStore.load(from: folder)?.pages.map(\.source.file) == ["b.jpg", "a.jpg"])
    }

    /// A folder saved by an earlier version keeps the name it was given rather
    /// than gaining a second document beside it.
    @Test func aFolderThatAlreadyHasADocumentKeepsItsName() async throws {
        let folder = try makeFolder(files: ["a.jpg"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let existing = folder.appendingPathComponent(StateStore.legacyDocumentName)
        try JSONEncoder().encode(ProjectState()).write(to: existing)

        let store = DocumentStore()
        await store.openFolder(folder)
        #expect(store.hasDocument)
        store.setAspectRatio(AspectRatio(width: 210, height: 297))
        store.saveDocument()

        #expect(try names(in: folder) == ["Document.idfit", "a.jpg"])
    }

    @Test func reorderIsPersistedAndRestoredOnReopen() async throws {
        let folder = try makeFolder(files: ["a.jpg", "b.jpg", "c.jpg"])
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = DocumentStore()
        await store.openFolder(folder)
        store.movePage(id: store.state.pages[2].id, toIndex: 0)
        #expect(store.hasUnsavedChanges)

        store.saveDocument()
        #expect(!store.hasUnsavedChanges)

        let reopened = DocumentStore()
        await reopened.openFolder(folder)
        #expect(reopened.state.pages.map(\.source.file) == ["c.jpg", "a.jpg", "b.jpg"])
    }

    @Test func debouncedAutosaveWritesWithoutExplicitFlush() async throws {
        let folder = try makeFolder(files: ["a.jpg", "b.jpg"])
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = DocumentStore()
        await store.openFolder(folder)
        // Once the folder has a document, edits keep it up to date by
        // themselves — that is what this checks.
        store.saveDocument()
        store.movePage(id: store.state.pages[1].id, toIndex: 0)

        try await Task.sleep(for: .milliseconds(900))

        #expect(!store.hasUnsavedChanges)
        let onDisk = try StateStore.load(from: folder)
        #expect(onDisk?.pages.map(\.source.file) == ["b.jpg", "a.jpg"])
    }

    @Test func newFilesAppendAfterExistingOrderOnReopen() async throws {
        let folder = try makeFolder(files: ["a.jpg", "b.jpg"])
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = DocumentStore()
        await store.openFolder(folder)
        store.movePage(id: store.state.pages[1].id, toIndex: 0)
        store.saveDocument()

        // A scanner drops one more file into the folder later.
        try Data().write(to: folder.appendingPathComponent("aaa-new.jpg"))

        let reopened = DocumentStore()
        await reopened.openFolder(folder)
        #expect(reopened.state.pages.map(\.source.file) == ["b.jpg", "a.jpg", "aaa-new.jpg"])
    }

    @Test func missingFileKeepsPageAndIsReported() async throws {
        let folder = try makeFolder(files: ["a.jpg", "b.jpg"])
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = DocumentStore()
        await store.openFolder(folder)
        store.saveDocument()

        try FileManager.default.removeItem(at: folder.appendingPathComponent("a.jpg"))

        let reopened = DocumentStore()
        await reopened.openFolder(folder)
        #expect(reopened.state.pages.count == 2)
        #expect(reopened.missingSources == [SourceRef(file: "a.jpg")])
    }

    @Test func corruptStateFileIsReportedAndNotOverwritten() async throws {
        let folder = try makeFolder(files: ["a.jpg"])
        defer { try? FileManager.default.removeItem(at: folder) }

        let corrupt = "{ this is not json"
        try Data(corrupt.utf8).write(to: StateStore.stateFileURL(for: folder))

        let store = DocumentStore()
        await store.openFolder(folder)

        #expect(store.lastError != nil)
        #expect(store.folderURL == nil)
        let onDisk = try String(contentsOf: StateStore.stateFileURL(for: folder), encoding: .utf8)
        #expect(onDisk == corrupt)
    }
}

import Foundation
import Testing
@testable import IdFit

/// Deleting is the one action that takes something out of the working folder,
/// so what it takes — and what it leaves — is worth being exact about.
///
/// The files are named after this suite because they really do end up in the
/// Trash, and they are taken back out again afterwards.
@MainActor
@Suite struct TrashTests {
    private func makeFolder(files: [String]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("id-fit-trash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in files {
            try Data("scan".utf8).write(to: folder.appendingPathComponent(name))
        }
        return folder
    }

    private func names(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    /// Unique per run, so nothing already in the Trash is mistaken for ours
    /// and nothing of ours is renamed on the way in.
    private func scanName(_ label: String) -> String {
        "id-fit-trash-test-\(label)-\(UUID().uuidString.prefix(8)).jpg"
    }

    private func emptyFromTrash(_ names: [String]) {
        guard let trash = try? FileManager.default.url(
            for: .trashDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ) else { return }
        for name in names {
            try? FileManager.default.removeItem(at: trash.appendingPathComponent(name))
        }
    }

    @Test func theFileLeavesTheFolderAndThePageLeavesTheDocument() async throws {
        let kept = scanName("kept")
        let gone = scanName("gone")
        let folder = try makeFolder(files: [kept, gone])
        defer {
            try? FileManager.default.removeItem(at: folder)
            emptyFromTrash([gone])
        }

        let store = DocumentStore()
        await store.openFolder(folder)
        let page = try #require(store.state.pages.first { $0.source.file == gone })

        #expect(store.moveToTrash(pageIDs: [page.id]) == 1)
        #expect(try names(in: folder) == [kept])
        #expect(store.state.pages.map(\.source.file) == [kept])
        #expect(store.lastError == nil)
        // It went to the Trash rather than being destroyed.
        let trash = try FileManager.default.url(
            for: .trashDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        )
        #expect(FileManager.default.fileExists(atPath: trash.appendingPathComponent(gone).path))
    }

    /// A scan standing behind two pages cannot half-leave: the file is what
    /// goes, so both copies go with it.
    @Test func everyPageOnATrashedFileGoesWithIt() async throws {
        let gone = scanName("shared")
        let folder = try makeFolder(files: [gone])
        defer {
            try? FileManager.default.removeItem(at: folder)
            emptyFromTrash([gone])
        }

        let store = DocumentStore()
        await store.openFolder(folder)
        let page = try #require(store.state.pages.first)
        store.duplicatePage(id: page.id)
        #expect(store.state.pages.count == 2)

        #expect(store.moveToTrash(pageIDs: [page.id]) == 2)
        #expect(store.state.pages.isEmpty)
        #expect(try names(in: folder).isEmpty)
    }

    /// Deleting changes the folder, but it still does not decide for the user
    /// that this folder wants a document.
    @Test func deletingWritesNoDocumentIntoAFolderThatHasNone() async throws {
        let kept = scanName("kept")
        let gone = scanName("gone")
        let folder = try makeFolder(files: [kept, gone])
        defer {
            try? FileManager.default.removeItem(at: folder)
            emptyFromTrash([gone])
        }

        let store = DocumentStore()
        await store.openFolder(folder)
        let page = try #require(store.state.pages.first { $0.source.file == gone })
        store.moveToTrash(pageIDs: [page.id])
        // Longer than the autosave debounce, which must not fire here.
        try await Task.sleep(for: .milliseconds(900))

        #expect(try names(in: folder) == [kept])
        #expect(!store.hasDocument)
    }

    /// A folder that keeps a document keeps it honest: the page is gone from
    /// what is on disk too, without anybody pressing Save.
    @Test func aSavedFolderRecordsTheDeletion() async throws {
        let kept = scanName("kept")
        let gone = scanName("gone")
        let folder = try makeFolder(files: [kept, gone])
        defer {
            try? FileManager.default.removeItem(at: folder)
            emptyFromTrash([gone])
        }

        let store = DocumentStore()
        await store.openFolder(folder)
        store.saveDocument()
        let page = try #require(store.state.pages.first { $0.source.file == gone })
        store.moveToTrash(pageIDs: [page.id])
        try await Task.sleep(for: .milliseconds(900))

        let saved = try #require(try StateStore.load(from: folder))
        #expect(saved.pages.map(\.source.file) == [kept])
    }

    /// The file went missing while the folder was open — whoever asked for it
    /// to be deleted has got what they asked for.
    @Test func aPageWhoseFileIsAlreadyGoneJustGoes() async throws {
        let gone = scanName("vanished")
        let folder = try makeFolder(files: [gone])
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = DocumentStore()
        await store.openFolder(folder)
        let page = try #require(store.state.pages.first)
        try FileManager.default.removeItem(at: folder.appendingPathComponent(gone))

        #expect(store.moveToTrash(pageIDs: [page.id]) == 1)
        #expect(store.state.pages.isEmpty)
        #expect(store.lastError == nil)
    }
}

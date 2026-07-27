import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import IdFit

/// Saving the exported PDF into the folder being edited is the natural choice,
/// so it must not turn into pages the next time the folder is opened.
@MainActor
@Suite struct ExportInsideFolderTests {
    private func makeFolder(files: [String]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("id-fit-export-folder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in files {
            let context = CGContext(
                data: nil, width: 400, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            let destination = CGImageDestinationCreateWithURL(
                folder.appendingPathComponent(name) as CFURL,
                UTType.png.identifier as CFString, 1, nil
            )!
            CGImageDestinationAddImage(destination, context.makeImage()!, nil)
            #expect(CGImageDestinationFinalize(destination))
        }
        return folder
    }

    @Test func exportSavedIntoTheFolderIsNotScannedBackIn() async throws {
        let folder = try makeFolder(files: ["a.png", "b.png"])
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = DocumentStore()
        await store.openFolder(folder)
        #expect(store.state.pages.count == 2)

        let output = folder.appendingPathComponent("Scans.pdf")
        await store.exportPDF(to: output, paper: .fitContent)
        #expect(store.lastError == nil)
        #expect(FileManager.default.fileExists(atPath: output.path))
        #expect(store.state.exportedFiles == ["Scans.pdf"])

        let reopened = DocumentStore()
        await reopened.openFolder(folder)
        #expect(reopened.state.pages.map(\.source.file) == ["a.png", "b.png"])
        #expect(reopened.state.exportedFiles == ["Scans.pdf"])
    }

    @Test func reExportingUnderTheSameNameDoesNotDuplicateTheRecord() async throws {
        let folder = try makeFolder(files: ["a.png"])
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = DocumentStore()
        await store.openFolder(folder)
        let output = folder.appendingPathComponent("Scans.pdf")
        await store.exportPDF(to: output, paper: .fitContent)
        await store.exportPDF(to: output, paper: .a4)

        #expect(store.state.exportedFiles == ["Scans.pdf"])
    }

    @Test func severalExportsAreAllRemembered() async throws {
        let folder = try makeFolder(files: ["a.png"])
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = DocumentStore()
        await store.openFolder(folder)
        await store.exportPDF(to: folder.appendingPathComponent("First.pdf"), paper: .fitContent)
        await store.exportPDF(to: folder.appendingPathComponent("Second.pdf"), paper: .fitContent)

        let reopened = DocumentStore()
        await reopened.openFolder(folder)
        #expect(reopened.state.pages.map(\.source.file) == ["a.png"])
        #expect(Set(reopened.state.exportedFiles) == ["First.pdf", "Second.pdf"])
    }

    @Test func exportOutsideTheFolderIsNotRecorded() async throws {
        let folder = try makeFolder(files: ["a.png"])
        let elsewhere = try makeFolder(files: [])
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: elsewhere)
        }

        let store = DocumentStore()
        await store.openFolder(folder)
        await store.exportPDF(to: elsewhere.appendingPathComponent("Scans.pdf"), paper: .fitContent)

        #expect(store.state.exportedFiles.isEmpty)
    }

    @Test func aPDFTheUserPutInTheFolderIsStillReadAsPages() async throws {
        let folder = try makeFolder(files: ["a.png"])
        defer { try? FileManager.default.removeItem(at: folder) }

        // A scanner-produced PDF, not one of ours.
        var box = CGRect(x: 0, y: 0, width: 300, height: 300)
        let context = CGContext(folder.appendingPathComponent("scanner.pdf") as CFURL, mediaBox: &box, nil)!
        context.beginPage(mediaBox: &box)
        context.endPage()
        context.closePDF()

        let store = DocumentStore()
        await store.openFolder(folder)
        #expect(store.state.pages.map(\.source.file).contains("scanner.pdf"))
    }

    @Test func theRecordOfExportsSurvivesInTheStateFile() async throws {
        let folder = try makeFolder(files: ["a.png"])
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = DocumentStore()
        await store.openFolder(folder)
        await store.exportPDF(to: folder.appendingPathComponent("Out.pdf"), paper: .fitContent)

        let saved = try #require(try StateStore.load(from: folder))
        #expect(saved.exportedFiles == ["Out.pdf"])
    }

    @Test func olderStateFilesWithoutTheFieldStillLoad() throws {
        let json = """
        {"pages": [{"source": {"file": "a.jpg"}}], "version": 1}
        """
        let state = try JSONDecoder().decode(ProjectState.self, from: Data(json.utf8))
        #expect(state.exportedFiles.isEmpty)
        #expect(state.pages.count == 1)
    }
}

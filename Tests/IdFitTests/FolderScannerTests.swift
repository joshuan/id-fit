import Foundation
import PDFKit
import Testing
@testable import IdFit

@Suite struct FolderScannerTests {
    private func makeTempFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("id-fit-scanner-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func touch(_ name: String, in folder: URL) throws {
        try Data().write(to: folder.appendingPathComponent(name))
    }

    @Test func findsSupportedImagesSkipsOthers() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        for name in ["a.jpg", "b.PNG", "c.tiff", "d.heic", "notes.txt", ".hidden.jpg"] {
            try touch(name, in: folder)
        }
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("subfolder.jpg", isDirectory: true),
            withIntermediateDirectories: true
        )

        let refs = FolderScanner.discoverSources(in: folder)
        #expect(refs == [
            SourceRef(file: "a.jpg"),
            SourceRef(file: "b.PNG"),
            SourceRef(file: "c.tiff"),
            SourceRef(file: "d.heic"),
        ])
    }

    @Test func usesFinderLikeNumericOrdering() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        for name in ["scan-10.png", "scan-2.png", "scan-1.png"] {
            try touch(name, in: folder)
        }

        let refs = FolderScanner.discoverSources(in: folder)
        #expect(refs.map(\.file) == ["scan-1.png", "scan-2.png", "scan-10.png"])
    }

    @Test func expandsPDFIntoPerPageSources() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let document = PDFDocument()
        for index in 0..<3 {
            document.insert(PDFPage(), at: index)
        }
        #expect(document.write(to: folder.appendingPathComponent("bundle.pdf")))
        try touch("cover.jpg", in: folder)

        let refs = FolderScanner.discoverSources(in: folder)
        #expect(refs == [
            SourceRef(file: "bundle.pdf", pdfPage: 0),
            SourceRef(file: "bundle.pdf", pdfPage: 1),
            SourceRef(file: "bundle.pdf", pdfPage: 2),
            SourceRef(file: "cover.jpg"),
        ])
    }
}

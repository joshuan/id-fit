import CoreGraphics
import Foundation
import PDFKit

/// Applies the edits to the source files themselves. This is the one place in
/// the app that modifies the user's originals, and it only runs from an
/// explicit, confirmed action.
enum OriginalsWriter {
    /// Untouched copies are kept here; the folder starts with a dot so the
    /// scanner never picks it up.
    static let backupFolderName = ".id-fit-originals"

    struct Result: Sendable {
        var changedFiles: [String] = []
        var appliedPageIDs: Set<UUID> = []
        var failures: [String] = []
        var backupFolder: URL?
    }

    static func apply(pages: [Page], folder: URL, makeBackup: Bool) throws -> Result {
        let edited = pages.filter { $0.crop != nil || $0.rotation != 0 }
        guard !edited.isEmpty else { return Result() }

        var backupFolder: URL?
        if makeBackup {
            let url = folder.appendingPathComponent(backupFolderName, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            backupFolder = url
        }

        var result = Result(backupFolder: backupFolder)
        // Group by file: a multi-page PDF must be rewritten once, not once
        // per page.
        let byFile = Dictionary(grouping: edited) { $0.source.file }

        for (file, filePages) in byFile.sorted(by: { $0.key < $1.key }) {
            let url = folder.appendingPathComponent(file)
            guard FileManager.default.fileExists(atPath: url.path) else {
                result.failures.append(file)
                continue
            }
            do {
                if url.pathExtension.lowercased() == "pdf" {
                    try applyToPDF(at: url, pages: filePages, backupFolder: backupFolder)
                } else {
                    guard let page = filePages.first else { continue }
                    try applyToImage(at: url, page: page, folder: folder, backupFolder: backupFolder)
                }
                result.changedFiles.append(file)
                result.appliedPageIDs.formUnion(filePages.map(\.id))
            } catch {
                result.failures.append(file)
            }
        }

        return result
    }

    // MARK: - Images

    private static func applyToImage(at url: URL, page: Page, folder: URL, backupFolder: URL?) throws {
        guard let type = ImageWriter.contentType(forExtension: url.pathExtension),
              let content = PageRenderer.content(for: page, in: folder),
              case .image(let image) = content
        else { throw ImageWriter.WriteError.unsupportedFormat(url.lastPathComponent) }

        try replaceFile(at: url, backupFolder: backupFolder) { temp in
            try ImageWriter.write(image, to: temp, type: type, inheritingMetadataFrom: url)
        }
    }

    // MARK: - PDFs

    /// Cropping a PDF means narrowing its crop box — the page content stays
    /// untouched and fully vector.
    private static func applyToPDF(at url: URL, pages: [Page], backupFolder: URL?) throws {
        guard let document = PDFDocument(url: url) else {
            throw ImageWriter.WriteError.unsupportedFormat(url.lastPathComponent)
        }

        for page in pages {
            let index = page.source.pdfPage ?? 0
            guard let pdfPage = document.page(at: index) else { continue }

            let box = pdfPage.bounds(for: .cropBox)
            if let crop = page.crop, box.width > 0, box.height > 0 {
                // The stored crop is relative to the page as displayed, so it
                // has to be turned back into the page's own coordinates, and
                // flipped because PDF y grows upwards.
                let inPageSpace = CropGeometry.rotated(crop, by: -pdfPage.rotation)
                let newBox = CGRect(
                    x: box.minX + inPageSpace.x * box.width,
                    y: box.minY + box.height - (inPageSpace.y + inPageSpace.height) * box.height,
                    width: inPageSpace.width * box.width,
                    height: inPageSpace.height * box.height
                )
                pdfPage.setBounds(newBox, for: .cropBox)
            }
            if page.rotation != 0 {
                pdfPage.rotation = pdfPage.rotation + page.rotation
            }
        }

        try replaceFile(at: url, backupFolder: backupFolder) { temp in
            guard document.write(to: temp) else {
                throw ImageWriter.WriteError.encodingFailed(url.lastPathComponent)
            }
        }
    }

    // MARK: - Safe replacement

    /// Writes to a temporary file first and swaps it in, so an interrupted
    /// run can never leave a half-written original behind.
    private static func replaceFile(
        at url: URL,
        backupFolder: URL?,
        write: (URL) throws -> Void
    ) throws {
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".id-fit-tmp-\(UUID().uuidString).\(url.pathExtension)")
        defer { try? FileManager.default.removeItem(at: temp) }

        try write(temp)

        if let backupFolder {
            let backup = backupFolder.appendingPathComponent(url.lastPathComponent)
            // Keep the earliest copy: it is the true original.
            if !FileManager.default.fileExists(atPath: backup.path) {
                try FileManager.default.copyItem(at: url, to: backup)
            }
        }

        _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
    }
}

import CoreGraphics
import Foundation
import UniformTypeIdentifiers

/// Writes the edited pages as individual files into a separate folder,
/// leaving the working folder untouched.
enum FileExporter {
    struct Result: Sendable {
        var writtenFiles: [String]
        var skippedPages: [String]
    }

    enum ExportError: LocalizedError {
        case destinationInsideWorkingFolder

        var errorDescription: String? {
            switch self {
            case .destinationInsideWorkingFolder:
                "Choose a folder outside the one you are editing, so the exported files are not picked up as new pages."
            }
        }
    }

    /// Files are numbered by page order, so the sequence survives outside the
    /// app. PDF pages stay PDF (and stay vector); images keep their format.
    static func export(pages: [Page], folder: URL, to destination: URL) throws -> Result {
        guard !isDescendant(destination, of: folder) else {
            throw ExportError.destinationInsideWorkingFolder
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        var written: [String] = []
        var skipped: [String] = []
        let width = max(String(pages.count).count, 2)

        for (index, page) in pages.enumerated() {
            let prefix = String(format: "%0\(width)d", index + 1)
            do {
                let name = try writeFile(page: page, prefix: prefix, folder: folder, destination: destination)
                written.append(name)
            } catch {
                skipped.append(page.source.displayName)
            }
        }

        return Result(writtenFiles: written, skippedPages: skipped)
    }

    private enum WriteFailure: Error {
        case unreadableSource
    }

    private static func writeFile(
        page: Page,
        prefix: String,
        folder: URL,
        destination: URL
    ) throws -> String {
        let sourceURL = folder.appendingPathComponent(page.source.file)
        let base = sourceURL.deletingPathExtension().lastPathComponent

        if let pdfPage = page.source.pdfPage {
            let name = "\(prefix)-\(base)-p\(pdfPage + 1).pdf"
            let output = destination.appendingPathComponent(name)
            _ = try PDFExporter.export(pages: [page], folder: folder, to: output, paper: .fitContent)
            return name
        }

        let ext = sourceURL.pathExtension
        guard let type = ImageWriter.contentType(forExtension: ext),
              let content = PageRenderer.content(for: page, in: folder),
              case .image(let image) = content
        else { throw WriteFailure.unreadableSource }

        let name = "\(prefix)-\(base).\(ext)"
        let output = destination.appendingPathComponent(name)
        try ImageWriter.write(image, to: output, type: type, inheritingMetadataFrom: sourceURL)
        return name
    }

    private static func isDescendant(_ candidate: URL, of folder: URL) -> Bool {
        let target = candidate.standardizedFileURL.resolvingSymlinksInPath().path
        let root = folder.standardizedFileURL.resolvingSymlinksInPath().path
        return target == root || target.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}

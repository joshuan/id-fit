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

    static func export(
        pages: [Page],
        folder: URL,
        to destination: URL,
        format: ExportOptions.Format = .originalFormat,
        naming: ExportOptions.Naming = .sequential,
        sharedRatio: AspectRatio? = nil
    ) throws -> Result {
        guard !isDescendant(destination, of: folder) else {
            throw ExportError.destinationInsideWorkingFolder
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        var written: [String] = []
        var skipped: [String] = []
        var names = NameAllocator(pageCount: pages.count, naming: naming)

        for (index, page) in pages.enumerated() {
            do {
                let name = try writeFile(
                    page: page,
                    index: index,
                    names: &names,
                    folder: folder,
                    destination: destination,
                    format: format,
                    sharedRatio: sharedRatio
                )
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

    /// Hands out one file name per page, never the same one twice — a scan
    /// used as two pages of the document would otherwise overwrite itself.
    private struct NameAllocator {
        let width: Int
        let naming: ExportOptions.Naming
        private var taken: Set<String> = []

        init(pageCount: Int, naming: ExportOptions.Naming) {
            self.width = max(String(pageCount).count, 3)
            self.naming = naming
        }

        mutating func name(for page: Page, index: Int, extension ext: String) -> String {
            let base: String
            switch naming {
            case .sequential:
                base = String(format: "%0\(width)d", index + 1)
            case .original:
                let stem = (page.source.file as NSString).deletingPathExtension
                base = page.source.pdfPage.map { "\(stem)-p\($0 + 1)" } ?? stem
            }

            var candidate = "\(base).\(ext)"
            var copy = 2
            while taken.contains(candidate.lowercased()) {
                candidate = "\(base) (\(copy)).\(ext)"
                copy += 1
            }
            taken.insert(candidate.lowercased())
            return candidate
        }
    }

    private static func writeFile(
        page: Page,
        index: Int,
        names: inout NameAllocator,
        folder: URL,
        destination: URL,
        format: ExportOptions.Format,
        sharedRatio: AspectRatio?
    ) throws -> String {
        let sourceURL = folder.appendingPathComponent(page.source.file)
        let outputRatio = page.outputRatio(sharedRatio: sharedRatio)

        if format == .jpeg {
            guard let image = PageRenderer.image(for: page, in: folder, outputRatio: outputRatio) else {
                throw WriteFailure.unreadableSource
            }
            let name = names.name(for: page, index: index, extension: "jpg")
            try ImageWriter.write(
                image, to: destination.appendingPathComponent(name),
                type: .jpeg, inheritingMetadataFrom: sourceURL
            )
            return name
        }

        // Keeping the original format: a PDF page stays a PDF, and stays
        // vector with it.
        if page.source.pdfPage != nil {
            let name = names.name(for: page, index: index, extension: "pdf")
            _ = try PDFExporter.export(
                pages: [page], folder: folder,
                to: destination.appendingPathComponent(name),
                paper: .fitContent, sharedRatio: sharedRatio
            )
            return name
        }

        let ext = sourceURL.pathExtension
        guard let type = ImageWriter.contentType(forExtension: ext),
              let image = PageRenderer.image(for: page, in: folder, outputRatio: outputRatio)
        else { throw WriteFailure.unreadableSource }

        let name = names.name(for: page, index: index, extension: ext)
        try ImageWriter.write(
            image, to: destination.appendingPathComponent(name),
            type: type, inheritingMetadataFrom: sourceURL
        )
        return name
    }

    private static func isDescendant(_ candidate: URL, of folder: URL) -> Bool {
        let target = candidate.standardizedFileURL.resolvingSymlinksInPath().path
        let root = folder.standardizedFileURL.resolvingSymlinksInPath().path
        return target == root || target.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}

import Foundation
import PDFKit

/// Discovers page sources in a working folder.
enum FolderScanner {
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "tif", "tiff", "heic"]

    /// Scans the top level of the folder (subfolders are ignored so that e.g.
    /// our own export folders never get picked up as pages) and expands each
    /// PDF into one `SourceRef` per page. Files are ordered with Finder-like
    /// numeric sorting, so `scan-2` comes before `scan-10`.
    static func discoverSources(in folder: URL) -> [SourceRef] {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let files = entries
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }

        var refs: [SourceRef] = []
        for url in files {
            let ext = url.pathExtension.lowercased()
            if imageExtensions.contains(ext) {
                refs.append(SourceRef(file: url.lastPathComponent))
            } else if ext == "pdf" {
                guard let document = PDFDocument(url: url) else { continue }
                for index in 0..<document.pageCount {
                    refs.append(SourceRef(file: url.lastPathComponent, pdfPage: index))
                }
            }
        }
        return refs
    }
}

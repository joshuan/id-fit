import Foundation

/// Cache key for anything derived from a source file.
///
/// It has to include the folder — two folders routinely hold files with the
/// same name — and the file's modification date, so that a file updated
/// underneath the app (cloud sync, or our own apply-to-originals) is not
/// served from a stale cache.
enum SourceCacheKey {
    static func make(for ref: SourceRef, in folder: URL, variant: String = "") -> NSString {
        let url = folder.appendingPathComponent(ref.file)
        let stamp: String
        if let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) {
            let modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
            let size = values.fileSize ?? 0
            stamp = "\(modified)-\(size)"
        } else {
            stamp = "missing"
        }
        return "\(folder.path)|\(ref.file)|\(ref.pdfPage ?? -1)|\(stamp)|\(variant)" as NSString
    }
}

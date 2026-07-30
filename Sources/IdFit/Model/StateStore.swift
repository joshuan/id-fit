import Foundation

/// Reads and writes the document file that sits in the working folder.
///
/// It is deliberately visible: it is the document, it can be clicked to open
/// the folder in ID Fit, and hiding the one file that carries all the work
/// only makes it easy to lose. The contents are JSON.
enum StateStore {
    static let fileExtension = "idfit"
    static let fileName = "Document.idfit"
    /// Earlier versions kept a hidden dotfile.
    static let legacyFileName = ".id-fit.json"

    static func stateFileURL(for folder: URL) -> URL {
        folder.appendingPathComponent(fileName, isDirectory: false)
    }

    /// The document to read: the usual name, else any `.idfit` in the folder
    /// so a renamed one still works, else the old hidden file.
    static func existingStateFile(in folder: URL) -> URL? {
        let manager = FileManager.default
        let expected = stateFileURL(for: folder)
        if manager.fileExists(atPath: expected.path) { return expected }

        if let entries = try? manager.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil
        ) {
            let documents = entries
                .filter { $0.pathExtension.lowercased() == fileExtension }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            if let first = documents.first { return first }
        }

        let legacy = folder.appendingPathComponent(legacyFileName, isDirectory: false)
        return manager.fileExists(atPath: legacy.path) ? legacy : nil
    }

    /// Whether the folder is still kept by the old hidden dotfile, and so
    /// wants writing out as a visible document even if nothing else changed.
    static func usesLegacyDocument(in folder: URL) -> Bool {
        guard let url = existingStateFile(in: folder) else { return false }
        return url.pathExtension.lowercased() != fileExtension
    }

    /// Returns nil when the folder has not been opened before.
    static func load(from folder: URL) throws -> ProjectState? {
        guard let url = existingStateFile(in: folder) else { return nil }
        return try JSONDecoder().decode(ProjectState.self, from: Data(contentsOf: url))
    }

    static func save(_ state: ProjectState, to folder: URL) throws {
        let encoder = JSONEncoder()
        // Stable, human-readable output keeps cloud-sync diffs small.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)

        // Keep writing to whichever document the folder already uses, so a
        // renamed one is not orphaned by a second file appearing beside it.
        let destination = existingStateFile(in: folder)
            .flatMap { $0.pathExtension.lowercased() == fileExtension ? $0 : nil }
            ?? stateFileURL(for: folder)
        try data.write(to: destination, options: .atomic)

        // Having written the visible document, the old hidden file is only a
        // stale copy of it.
        let legacy = folder.appendingPathComponent(legacyFileName, isDirectory: false)
        if FileManager.default.fileExists(atPath: legacy.path) {
            try? FileManager.default.removeItem(at: legacy)
        }
    }
}

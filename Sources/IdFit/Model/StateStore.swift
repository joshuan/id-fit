import Foundation

/// Reads and writes `.id-fit.json` in a working folder.
enum StateStore {
    static let fileName = ".id-fit.json"

    static func stateFileURL(for folder: URL) -> URL {
        folder.appendingPathComponent(fileName, isDirectory: false)
    }

    /// Returns nil when the folder has no state file yet.
    static func load(from folder: URL) throws -> ProjectState? {
        let url = stateFileURL(for: folder)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ProjectState.self, from: data)
    }

    static func save(_ state: ProjectState, to folder: URL) throws {
        let encoder = JSONEncoder()
        // Stable, human-readable output keeps cloud-sync diffs small.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: stateFileURL(for: folder), options: .atomic)
    }
}

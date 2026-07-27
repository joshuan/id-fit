import Foundation
import Observation

/// Central app state: the currently open working folder and its project
/// state. All mutations go through this object; it never touches source
/// files, only `.id-fit.json`.
@MainActor @Observable
final class DocumentStore {
    private(set) var folderURL: URL?
    private(set) var state = ProjectState()
    private(set) var missingSources: Set<SourceRef> = []
    private(set) var isLoading = false
    private(set) var lastError: String?

    /// Drives the folder picker; settable from menu commands and views.
    var isPickingFolder = false

    var folderName: String { folderURL?.lastPathComponent ?? "" }

    func openFolder(_ url: URL) async {
        isLoading = true
        defer { isLoading = false }
        lastError = nil

        let discovered = await Task.detached(priority: .userInitiated) {
            FolderScanner.discoverSources(in: url)
        }.value

        do {
            let loaded = try StateStore.load(from: url) ?? ProjectState()
            let reconciled = loaded.reconciled(with: discovered)
            folderURL = url
            state = reconciled
            missingSources = reconciled.missingSources(given: discovered)
            if reconciled != loaded {
                try StateStore.save(reconciled, to: url)
            }
        } catch {
            // A corrupt state file must never be silently overwritten — the
            // user may have edits from another machine in it.
            lastError = "Could not open folder: \(error.localizedDescription)"
        }
    }
}

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
    private(set) var hasUnsavedChanges = false

    /// Drives the folder picker; settable from menu commands and views.
    var isPickingFolder = false

    @ObservationIgnored private var saveTask: Task<Void, Never>?

    var folderName: String { folderURL?.lastPathComponent ?? "" }

    // MARK: - Opening

    func openFolder(_ url: URL) async {
        saveImmediately()
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
            hasUnsavedChanges = false
            if reconciled != loaded {
                try StateStore.save(reconciled, to: url)
            }
        } catch {
            // A corrupt state file must never be silently overwritten — the
            // user may have edits from another machine in it.
            lastError = "Could not open folder: \(error.localizedDescription)"
        }
    }

    // MARK: - Mutations

    func movePage(id: UUID, toIndex index: Int) {
        let before = state.pages.map(\.id)
        state.movePage(id: id, toIndex: index)
        guard state.pages.map(\.id) != before else { return }
        scheduleSave()
    }

    // MARK: - Saving

    /// Coalesces bursts of edits (e.g. a flurry of drags) into one write.
    private func scheduleSave() {
        hasUnsavedChanges = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await self?.performSave()
        }
    }

    private func performSave() async {
        guard let folderURL else { return }
        let snapshot = state
        do {
            try await Task.detached(priority: .utility) {
                try StateStore.save(snapshot, to: folderURL)
            }.value
            if state == snapshot { hasUnsavedChanges = false }
        } catch {
            lastError = "Could not save changes: \(error.localizedDescription)"
        }
    }

    /// Flushes pending edits synchronously — used on quit, where an async
    /// write would not finish in time.
    func saveImmediately() {
        saveTask?.cancel()
        saveTask = nil
        guard hasUnsavedChanges, let folderURL else { return }
        do {
            try StateStore.save(state, to: folderURL)
            hasUnsavedChanges = false
        } catch {
            lastError = "Could not save changes: \(error.localizedDescription)"
        }
    }
}

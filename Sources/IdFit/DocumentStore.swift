import CoreGraphics
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
    /// Displayed pixel size of every readable source, prefetched on open so
    /// that crop math stays synchronous.
    private(set) var sourceSizes: [SourceRef: CGSize] = [:]
    private(set) var isLoading = false
    private(set) var lastError: String?
    private(set) var hasUnsavedChanges = false

    /// Drive the folder picker from menu commands as well as from the views.
    var isPickingFolder = false
    /// Remembered between exports in the same session.
    var preferredPaper: PDFExporter.Paper = .a4

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
            sourceSizes = await Task.detached(priority: .userInitiated) {
                var sizes: [SourceRef: CGSize] = [:]
                for ref in discovered {
                    sizes[ref] = SourceGeometry.shared.size(for: ref, in: url)
                }
                return sizes
            }.value
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

    // MARK: - Cropping

    /// The crop ratio is shared by the whole document, so changing it
    /// reshapes every page: pages already cropped keep their framing and are
    /// refitted, the rest get a maximal centered crop. Passing nil clears all
    /// crops (export uses the full pages).
    func setAspectRatio(_ ratio: AspectRatio?) {
        state.cropAspectRatio = ratio

        guard let ratio else {
            for index in state.pages.indices {
                state.pages[index].crop = nil
            }
            scheduleSave()
            return
        }

        for index in state.pages.indices {
            let page = state.pages[index]
            guard let size = sourceSizes[page.source] else { continue }
            if let existing = page.crop {
                state.pages[index].crop = CropGeometry.refit(
                    existing, outputRatio: ratio.ratio, sourceSize: size, rotation: page.rotation
                )
            } else {
                state.pages[index].crop = CropGeometry.centeredCrop(
                    outputRatio: ratio.ratio, sourceSize: size, rotation: page.rotation
                )
            }
        }
        scheduleSave()
    }

    func setCrop(_ crop: CropRect, forPageID id: UUID) {
        guard let index = state.pages.firstIndex(where: { $0.id == id }),
              state.pages[index].crop != crop else { return }
        state.pages[index].crop = crop
        scheduleSave()
    }

    func resetCrop(forPageID id: UUID) {
        guard let ratio = state.cropAspectRatio,
              let index = state.pages.firstIndex(where: { $0.id == id }),
              let size = sourceSizes[state.pages[index].source] else { return }
        state.pages[index].crop = CropGeometry.centeredCrop(
            outputRatio: ratio.ratio, sourceSize: size, rotation: state.pages[index].rotation
        )
        scheduleSave()
    }

    /// Copies one page's framing onto every page — handy when scans are
    /// aligned the same way. Each page is refitted to the shared ratio, so
    /// sources of different pixel sizes still export uniformly.
    func applyCropToAllPages(fromPageID id: UUID) {
        guard let ratio = state.cropAspectRatio,
              let template = state.pages.first(where: { $0.id == id })?.crop else { return }
        for index in state.pages.indices {
            guard let size = sourceSizes[state.pages[index].source] else { continue }
            state.pages[index].crop = CropGeometry.refit(
                template, outputRatio: ratio.ratio, sourceSize: size, rotation: state.pages[index].rotation
            )
        }
        scheduleSave()
    }

    // MARK: - Export

    private(set) var isExporting = false
    /// Set after a successful export so the UI can offer to reveal the file.
    private(set) var lastExport: (url: URL, result: PDFExporter.Result)?

    /// Asks for a destination, then writes the PDF.
    func runExportFlow() async {
        guard let folderURL, !state.pages.isEmpty else { return }
        let missing = state.pages.filter { missingSources.contains($0.source) }.count
        guard let choice = ExportPanel.run(
            defaultName: suggestedExportName,
            directory: folderURL.deletingLastPathComponent(),
            pageCount: state.pages.count - missing,
            missingCount: missing,
            paper: preferredPaper
        ) else { return }

        preferredPaper = choice.paper
        await exportPDF(to: choice.url, paper: choice.paper)
    }

    func exportPDF(to destination: URL, paper: PDFExporter.Paper) async {
        guard let folderURL else { return }
        isExporting = true
        defer { isExporting = false }
        lastError = nil
        lastExport = nil

        let pages = state.pages
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try PDFExporter.export(pages: pages, folder: folderURL, to: destination, paper: paper)
            }.value
            lastExport = (destination, result)
        } catch {
            lastError = "Export failed: \(error.localizedDescription)"
        }
    }

    func clearLastExport() {
        lastExport = nil
    }

    /// A sensible default file name for the export panel.
    var suggestedExportName: String {
        let base = folderName.isEmpty ? "Scans" : folderName
        return "\(base).pdf"
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

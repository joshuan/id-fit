import AppKit
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
    var preferredPaper: PDFExporter.Paper = .fitContent

    @ObservationIgnored private var saveTask: Task<Void, Never>?

    var folderName: String { folderURL?.lastPathComponent ?? "" }

    // MARK: - Opening

    private static let lastFolderKey = "lastFolderPath"

    /// Reopens whatever was open last time, so launching the app lands
    /// straight back in the document being worked on.
    func restoreLastSession() async {
        guard folderURL == nil,
              let path = UserDefaults.standard.string(forKey: Self.lastFolderKey)
        else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return }
        await openFolder(URL(fileURLWithPath: path, isDirectory: true))
    }

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
            // Our own exports live in the folder but are not pages of it.
            let generated = Set(loaded.exportedFiles)
            let discovered = discovered.filter { !generated.contains($0.file) }
            let reconciled = loaded.reconciled(with: discovered)
            folderURL = url
            state = reconciled
            missingSources = reconciled.missingSources(given: discovered)
            hasUnsavedChanges = false
            UserDefaults.standard.set(url.path, forKey: Self.lastFolderKey)
            sourceSizes = await Task.detached(priority: .userInitiated) {
                var sizes: [SourceRef: CGSize] = [:]
                for ref in discovered {
                    sizes[ref] = SourceGeometry.shared.size(for: ref, in: url)
                }
                return sizes
            }.value
            normalizeCropsToSharedRatio()
            if state != loaded {
                try StateStore.save(state, to: url)
            }
        } catch {
            // A corrupt state file must never be silently overwritten — the
            // user may have edits from another machine in it.
            lastError = "Could not open folder: \(error.localizedDescription)"
        }
    }

    /// Makes sure every page really does export at the shared ratio.
    ///
    /// Two cases need it on open: a scan added to the folder after the ratio
    /// was chosen has no crop at all, and a page whose file was missing when
    /// the ratio last changed still carries its old shape. Either one would
    /// break the uniform export the ratio exists to guarantee.
    private func normalizeCropsToSharedRatio() {
        guard let ratio = state.cropAspectRatio else { return }
        for index in state.pages.indices {
            let page = state.pages[index]
            guard let size = sourceSizes[page.source] else { continue }

            guard let crop = page.crop else {
                state.pages[index].crop = CropGeometry.centeredCrop(
                    outputRatio: ratio.ratio, sourceSize: size, rotation: page.rotation
                )
                continue
            }
            let actual = CropGeometry.exportedRatio(crop, sourceSize: size, rotation: page.rotation)
            guard abs(actual - ratio.ratio) > 0.001 else { continue }
            state.pages[index].crop = CropGeometry.refit(
                crop, outputRatio: ratio.ratio, sourceSize: size, rotation: page.rotation
            )
        }
    }

    // MARK: - Mutations

    func movePage(id: UUID, toIndex index: Int) {
        let before = state.pages.map(\.id)
        state.movePage(id: id, toIndex: index)
        guard state.pages.map(\.id) != before else { return }
        scheduleSave()
    }

    /// Drops a page from the document. Source files are never deleted — this
    /// only forgets pages whose file is gone.
    func removePage(id: UUID) {
        guard let index = state.pages.firstIndex(where: { $0.id == id }) else { return }
        let source = state.pages.remove(at: index).source
        if !state.pages.contains(where: { $0.source == source }) {
            missingSources.remove(source)
        }
        scheduleSave()
    }

    func removeMissingPages() {
        let before = state.pages.count
        state.pages.removeAll { missingSources.contains($0.source) }
        guard state.pages.count != before else { return }
        missingSources = []
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

    /// Rotating changes which shape the crop must have in source space, so
    /// the existing framing is refitted rather than left at the wrong aspect.
    func rotatePage(id: UUID, by degrees: Int) {
        guard let index = state.pages.firstIndex(where: { $0.id == id }) else { return }
        let rotation = (((state.pages[index].rotation + degrees) % 360) + 360) % 360
        state.pages[index].rotation = rotation

        if let ratio = state.cropAspectRatio,
           let crop = state.pages[index].crop,
           let size = sourceSizes[state.pages[index].source] {
            state.pages[index].crop = CropGeometry.refit(
                crop, outputRatio: ratio.ratio, sourceSize: size, rotation: rotation
            )
        }
        scheduleSave()
    }

    /// Takes the shape the user just drew on one page and makes it the
    /// document's ratio — the natural way to crop a document that matches no
    /// preset. The drawn rectangle is given in the page's rotated space.
    func defineAspectRatio(fromDrawnCrop crop: CropRect, onPageID id: UUID) {
        guard let index = state.pages.firstIndex(where: { $0.id == id }),
              let size = sourceSizes[state.pages[index].source] else { return }
        let rotation = state.pages[index].rotation
        let displayed = rotation % 180 == 0
            ? size
            : CGSize(width: size.height, height: size.width)

        let width = (crop.width * displayed.width).rounded()
        let height = (crop.height * displayed.height).rounded()
        guard width > 0, height > 0 else { return }

        // Every other page gets a centered crop of the new ratio…
        setAspectRatio(AspectRatio(width: width, height: height))
        // …while this one keeps exactly the framing that defined it.
        state.pages[index].crop = CropGeometry.rotated(crop, by: -rotation)
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
            directory: folderURL,
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
            rememberExportInsideFolder(destination)
            lastExport = (destination, result)
        } catch {
            lastError = "Export failed: \(error.localizedDescription)"
        }
    }

    /// Saving the PDF next to the scans is the obvious thing to do, so the
    /// file has to be remembered — otherwise the next scan of the folder would
    /// read the export back in as a fresh stack of pages.
    private func rememberExportInsideFolder(_ destination: URL) {
        guard let folderURL else { return }
        let parent = destination.deletingLastPathComponent()
            .standardizedFileURL.resolvingSymlinksInPath().path
        let root = folderURL.standardizedFileURL.resolvingSymlinksInPath().path
        guard parent == root else { return }

        let name = destination.lastPathComponent
        guard !state.exportedFiles.contains(name) else { return }
        state.exportedFiles.append(name)
        hasUnsavedChanges = true
        saveImmediately()
    }

    func clearLastExport() {
        lastExport = nil
    }

    /// Writes the edited pages as separate files into a folder the user picks.
    func runFileExportFlow() async {
        guard let folderURL, !state.pages.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.title = "Export Cropped Files"
        panel.message = "Choose a folder for the exported files."
        panel.prompt = "Export"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = folderURL.deletingLastPathComponent()
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        isExporting = true
        defer { isExporting = false }
        lastError = nil

        let pages = state.pages
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try FileExporter.export(pages: pages, folder: folderURL, to: destination)
            }.value
            lastExport = (destination, PDFExporter.Result(
                exportedPages: result.writtenFiles.count,
                skippedPages: result.skippedPages
            ))
        } catch {
            lastError = "Export failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Applying to the originals

    /// The single destructive action in the app: rewrites the source files
    /// with their crops and rotations baked in. Only ever called after an
    /// explicit confirmation.
    func applyToOriginals(makeBackup: Bool) async {
        guard let folderURL else { return }
        isExporting = true
        defer { isExporting = false }
        lastError = nil

        let pages = state.pages
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try OriginalsWriter.apply(pages: pages, folder: folderURL, makeBackup: makeBackup)
            }.value

            // The files now contain the crop, so keeping it in the state
            // would apply it a second time on the next export.
            for index in state.pages.indices where result.appliedPageIDs.contains(state.pages[index].id) {
                state.pages[index].crop = nil
                state.pages[index].rotation = 0
            }

            ThumbnailProvider.shared.invalidate()
            SourceGeometry.shared.invalidate()
            await reloadSourceSizes()
            hasUnsavedChanges = true
            saveImmediately()

            if !result.failures.isEmpty {
                lastError = "Some files could not be updated: \(result.failures.joined(separator: ", "))"
            }
            lastApplyResult = result
        } catch {
            lastError = "Could not apply changes: \(error.localizedDescription)"
        }
    }

    private(set) var lastApplyResult: OriginalsWriter.Result?

    func clearLastApplyResult() {
        lastApplyResult = nil
    }

    private func reloadSourceSizes() async {
        guard let folderURL else { return }
        let refs = state.pages.map(\.source)
        sourceSizes = await Task.detached(priority: .userInitiated) {
            var sizes: [SourceRef: CGSize] = [:]
            for ref in refs {
                sizes[ref] = SourceGeometry.shared.size(for: ref, in: folderURL)
            }
            return sizes
        }.value
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

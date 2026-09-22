import SwiftUI

/// Everything shown for an open folder: the grid of pages, or — once a page is
/// picked — the crop editor in its place.
///
/// Framing used to happen in a sheet. Keeping it in the window means the
/// document stays visible while a page is being framed, and the toolbar's
/// document-wide controls (the shared ratio above all) stay reachable instead
/// of being blocked by a modal.
struct WorkspaceView: View {
    @Bindable var store: DocumentStore

    @State private var editingPageID: UUID?
    @State private var selection: Set<UUID> = []
    @State private var selectionAnchor: UUID?
    @State private var isEditingCustomRatio = false
    @State private var applyRequest: ApplyRequest?

    private struct ApplyRequest: Identifiable {
        let id = UUID()
        let pageIDs: Set<UUID>?
    }

    /// The page being framed, if it is still part of the document — a page can
    /// disappear underneath the editor when its file turns out to be gone.
    private var editedPage: UUID? {
        guard let editingPageID,
              store.state.pages.contains(where: { $0.id == editingPageID }) else { return nil }
        return editingPageID
    }

    var body: some View {
        VStack(spacing: 0) {
            if !store.missingSources.isEmpty {
                missingBanner
                Divider()
            }
            if editedPage != nil {
                // The state itself is handed over, not a binding wrapping the
                // unwrapped copy: a keyboard shortcut fires the action it was
                // registered with, and a captured page id would keep sending
                // the arrows back to whichever page the editor opened on.
                PageEditorView(store: store, pageID: $editingPageID, onClose: { close() })
                    .transition(.opacity)
            } else {
                PagesGridView(
                    store: store,
                    selection: $selection,
                    selectionAnchor: $selectionAnchor,
                    onOpen: { open($0) },
                    onTrash: { moveToTrash($0) },
                    onApply: { confirmApply(pageIDs: $0) }
                )
                .transition(.opacity)
            }
        }
        .disabled(store.isExporting || store.isLoading)
        .navigationTitle(store.folderName)
        .toolbar { toolbarContent }
        // What the Page menu acts on while this window is in front. Scene-
        // scoped for the same reason the store is: a grid of pages may never
        // give anything inside it keyboard focus.
        .focusedSceneValue(\.pageActions, PageActions(
            hasTargets: !actionTargets.isEmpty,
            trashTitle: trashTitle,
            rotate: { store.rotatePages(ids: actionTargets, by: $0) },
            moveToTrash: { moveToTrash(actionTargets) },
            partCount: editedPage.flatMap { id in
                store.state.pages.first(where: { $0.id == id }).map { $0.composition?.partCount ?? 1 }
            },
            setPartCount: { count in
                if let editedPage { store.setPartCount(count, forPageID: editedPage) }
            },
            canCycleParts: editedPage.flatMap { id in
                store.state.pages.first(where: { $0.id == id })?.composition?.regions.count
            }.map { $0 > 1 } ?? false,
            cyclePartOrder: {
                if let editedPage { store.cyclePartOrder(forPageID: editedPage) }
            }
        ))
        .sheet(isPresented: $isEditingCustomRatio) {
            CustomRatioSheet(current: store.state.cropAspectRatio) { ratio in
                store.setAspectRatio(ratio)
            }
        }
        .sheet(item: $applyRequest) { request in
            ApplyToOriginalsSheet(store: store, pageIDs: request.pageIDs)
        }
        .sheet(isPresented: $store.isPresentingExport) {
            ExportSheet(store: store)
        }
        .overlay {
            if store.isExporting {
                ProgressView("Exporting…")
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private func open(_ id: UUID) {
        withAnimation(.snappy(duration: 0.18)) { editingPageID = id }
    }

    private func close() {
        if let editingPageID {
            selection = [editingPageID]
            selectionAnchor = editingPageID
        }
        withAnimation(.snappy(duration: 0.18)) { editingPageID = nil }
    }

    private func confirmApply(pageIDs: Set<UUID>? = nil) {
        applyRequest = ApplyRequest(pageIDs: pageIDs)
    }

    // MARK: - Acting on pages

    /// What a keyboard shortcut means by "this page": the one being framed, or
    /// the ones picked out in the grid.
    private var actionTargets: [UUID] {
        if let editedPage { return [editedPage] }
        return store.state.pages.map(\.id).filter(selection.contains)
    }

    /// Names what will actually leave the folder — files, not pages, since a
    /// scan standing behind two pages leaves with both of them.
    private var trashTitle: String {
        let targets = Set(actionTargets)
        let files = Set(store.state.pages.filter { targets.contains($0.id) }.map(\.source.file))
        return files.count > 1 ? "Move \(files.count) Files to Trash" : "Move File to Trash"
    }

    private func moveToTrash(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        // Where the framed page sits now, so framing can carry on from the
        // same place once it is gone.
        let framedIndex = editedPage.flatMap { id in
            store.state.pages.firstIndex { $0.id == id }
        }
        guard store.moveToTrash(pageIDs: ids) > 0 else { return }

        let remaining = Set(store.state.pages.map(\.id))
        selection.formIntersection(remaining)
        if let anchor = selectionAnchor, !remaining.contains(anchor) { selectionAnchor = nil }

        // Only when the page that was being framed is one of the ones that
        // went: deleting from the grid leaves the editor closed.
        guard let framedIndex, editedPage == nil else { return }
        if store.state.pages.isEmpty {
            close()
        } else {
            // The page that slid into its place, or the last one if it was at
            // the end of the document.
            editingPageID = store.state.pages[min(framedIndex, store.state.pages.count - 1)].id
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .status) {
            Group {
                if store.isDetectingEdges {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Finding edges…")
                    }
                } else {
                    Text(store.state.pages.count == 1 ? "1 page" : "\(store.state.pages.count) pages")
                        .monospacedDigit()
                }
            }
            // The toolbar draws its own capsule tight around the content;
            // without this the text sits flush against it.
            .padding(.horizontal, 8)
            .foregroundStyle(.secondary)
        }
        ToolbarItem {
            Button("Auto-Straighten All", systemImage: "wand.and.rays") {
                Task { await store.redetectEdgesOnAllPages() }
            }
            .disabled(store.state.pages.isEmpty || store.isDetectingEdges || store.isExporting || store.isLoading)
            .help("Find edges and straighten all pages; review before applying to originals")
        }
        ToolbarItem {
            AspectRatioMenu(store: store, isEditingCustom: $isEditingCustomRatio)
                .disabled(store.isExporting)
        }
        ToolbarItem {
            Button("Save", systemImage: "square.and.arrow.down") {
                store.saveDocument()
            }
            .disabled(!store.canSave)
            .help(store.hasDocument
                ? "Save changes to the document"
                : "Write this folder's pages and crops to a document")
        }
        ToolbarItem {
            Button("Apply…", systemImage: "checkmark.circle") {
                confirmApply()
            }
            .labelStyle(.titleAndIcon)
            .disabled(!hasEdits || store.isDetectingEdges || store.isExporting || store.isLoading)
            .help("Apply all changes to the original files, including combined parts")
        }
        ToolbarItem {
            Button("Export…", systemImage: "square.and.arrow.up") {
                store.isPresentingExport = true
            }
            .disabled(store.state.pages.isEmpty || store.isExporting)
        }
        ToolbarItem {
            Menu {
                if editedPage == nil {
                    Button("Select All Pages") {
                        selection = Set(store.state.pages.map(\.id))
                    }
                    .keyboardShortcut("a", modifiers: .command)
                    Divider()
                }
                Toggle("Straighten Photographed Documents", isOn: Binding(
                    get: { store.state.straightenByDefault },
                    set: { store.setStraightenByDefault($0) }
                ))
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .disabled(store.state.pages.isEmpty || store.isExporting)
        }
        ToolbarItem {
            Button("Open Folder…", systemImage: "folder") {
                store.isPickingFolder = true
            }
            .disabled(store.isExporting)
        }
    }

    private var missingBanner: some View {
        HStack {
            Label(
                "\(missingPageCount) page(s) can't find their file. Their edits are kept in case the folder is still syncing.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.callout)
            Spacer()
            Button("Remove Them") { store.removeMissingPages() }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.orange.opacity(0.15))
    }

    private var missingPageCount: Int {
        store.state.pages.filter { store.missingSources.contains($0.source) }.count
    }

    /// Whether applying would do anything — asked of the writer, which counts
    /// a fine turn and a set of corners as edits too, and knows that a page
    /// sharing a scan has work to do even when it was never framed itself.
    private var hasEdits: Bool {
        let division = OriginalsWriter.divide(store.state.pages)
        return !division.applied.isEmpty || !division.spilled.isEmpty
    }
}

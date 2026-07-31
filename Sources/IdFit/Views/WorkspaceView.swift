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
    @State private var isConfirmingApply = false

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
                    onOpen: { open($0) }
                )
                .transition(.opacity)
            }
        }
        .navigationTitle(store.folderName)
        .toolbar { toolbarContent }
        .sheet(isPresented: $isEditingCustomRatio) {
            CustomRatioSheet(current: store.state.cropAspectRatio) { ratio in
                store.setAspectRatio(ratio)
            }
        }
        .sheet(isPresented: $isConfirmingApply) {
            ApplyToOriginalsSheet(store: store)
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
        withAnimation(.snappy(duration: 0.18)) { editingPageID = nil }
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
            AspectRatioMenu(store: store, isEditingCustom: $isEditingCustomRatio)
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
                Button("Detect Edges on All Pages") {
                    Task { await store.redetectEdgesOnAllPages() }
                }
                .disabled(store.isDetectingEdges)
                Toggle("Straighten Photographed Documents", isOn: Binding(
                    get: { store.state.straightenByDefault },
                    set: { store.setStraightenByDefault($0) }
                ))
                Divider()
                Button("Apply Changes to Original Files…", role: .destructive) {
                    isConfirmingApply = true
                }
                .disabled(!hasEdits)
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .disabled(store.state.pages.isEmpty || store.isExporting)
        }
        ToolbarItem {
            Button("Open Folder…", systemImage: "folder") {
                store.isPickingFolder = true
            }
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

    private var hasEdits: Bool {
        store.state.pages.contains { $0.crop != nil || $0.rotation != 0 }
    }
}

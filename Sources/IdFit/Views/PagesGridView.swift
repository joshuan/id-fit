import SwiftUI

/// The board of pages: reorder by dragging, pick pages for batch actions, and
/// click one to frame it. Framing itself happens in `PageEditorView`, which
/// takes this view's place in the window.
struct PagesGridView: View {
    let store: DocumentStore
    @Binding var selection: Set<UUID>
    @Binding var selectionAnchor: UUID?
    /// Opens a page in the editor.
    let onOpen: (UUID) -> Void
    /// Sends these pages' files to the Trash.
    let onTrash: ([UUID]) -> Void
    let onApply: (Set<UUID>) -> Void

    @State private var drag: DragState?
    @State private var cellFrames: [UUID: CGRect] = [:]

    nonisolated private static let boardSpace = "board"
    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 240), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            if !selection.isEmpty {
                selectionBar
                Divider()
            }
            ZStack {
                grid
                floatingCard
            }
        }
        .coordinateSpace(.named(Self.boardSpace))
        .overlay {
            // Only while the folder itself is being read: once the pages are
            // known, each cell reports its own progress and a second spinner
            // on top of them says nothing.
            if store.isLoading && store.state.pages.isEmpty {
                ProgressView("Reading folder…")
            } else if !store.isLoading && store.state.pages.isEmpty {
                ContentUnavailableView(
                    "No scans found",
                    systemImage: "doc.questionmark",
                    description: Text("This folder has no supported files (JPEG, PNG, TIFF, HEIC, PDF).")
                )
            }
        }
    }

    /// Every batch action uses the same selection, including a single page.
    private var selectionBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("\(selection.count) of \(store.state.pages.count) pages selected")
                    .font(.callout)
                    .monospacedDigit()

                Button {
                    store.rotatePages(ids: orderedSelection, by: -90)
                } label: {
                    Label("Rotate Left", systemImage: "rotate.left").labelStyle(.iconOnly)
                }
                .help("Rotate left")
                Button {
                    store.rotatePages(ids: orderedSelection, by: 90)
                } label: {
                    Label("Rotate Right", systemImage: "rotate.right").labelStyle(.iconOnly)
                }
                .help("Rotate right")

                Spacer()

                Button("Select All") { selection = Set(store.state.pages.map(\.id)) }
                Button("Deselect") { selection.removeAll() }
            }
            HStack(spacing: 12) {
                Button("Auto-Straighten Selected", systemImage: "wand.and.rays") {
                    let ids = orderedSelection
                    Task { await store.redetectEdges(forPageIDs: ids) }
                }
                .disabled(store.isDetectingEdges)

                Button("Apply Selected to Originals…", systemImage: "doc.badge.arrow.up") {
                    onApply(selection)
                }
                .disabled(!canApply(selection))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.4))
    }

    private var orderedSelection: [UUID] {
        store.state.pages.map(\.id).filter(selection.contains)
    }

    private var grid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(Array(store.state.pages.enumerated()), id: \.element.id) { index, page in
                        cell(page: page, index: index)
                    }
                }
                .padding()
                // Only the slots animate; the dragged card tracks the cursor
                // directly, so it must not be part of this animation.
                .animation(.snappy(duration: 0.25), value: store.state.pages.map(\.id))
                .frame(maxWidth: .infinity, minHeight: 400, alignment: .top)
                .background(
                    // Clicking past the pages clears the selection.
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { selection.removeAll() }
                )
            }
            .onAppear {
                // Coming back from the editor, land on the page that was being
                // framed rather than at the top of a long folder.
                guard let anchor = selectionAnchor else { return }
                proxy.scrollTo(anchor, anchor: .center)
            }
        }
    }

    private func cell(page: Page, index: Int) -> some View {
        PageCell(
            page: page,
            number: index + 1,
            folder: store.folderURL!,
            outputRatio: store.state.outputRatio(for: page),
            isMissing: store.missingSources.contains(page.source),
            sourceRevision: store.sourceRevision
        )
        // The slot left behind stays visible as an outline, so it is obvious
        // where the page will land.
        .opacity(drag?.pageID == page.id ? 0 : 1)
        .overlay {
            if drag?.pageID == page.id {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            }
        }
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named(Self.boardSpace))
        } action: { frame in
            cellFrames[page.id] = frame
        }
        .overlay {
            if selection.contains(page.id) {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
            }
        }
        .onTapGesture { click(page: page, at: index) }
        .contextMenu {
            Button(selectionApplies(to: page) ? "Crop First Selected…" : "Crop…") {
                onOpen(page.id)
            }
            Divider()
            Button(rotateTitle("Rotate Left", page: page)) {
                store.rotatePages(ids: targets(for: page), by: -90)
            }
            Button(rotateTitle("Rotate Right", page: page)) {
                store.rotatePages(ids: targets(for: page), by: 90)
            }
            Divider()
            Button(selectionApplies(to: page) ? "Auto-Straighten Selected" : "Auto-Straighten") {
                let ids = targets(for: page)
                Task { await store.redetectEdges(forPageIDs: ids) }
            }
            .disabled(store.isDetectingEdges || store.missingSources.contains(page.source))
            Button(selectionApplies(to: page) ? "Apply Selected to Originals…" : "Apply to Original…") {
                onApply(Set(targets(for: page)))
            }
            .disabled(!canApply(Set(targets(for: page))))
            Divider()
            Button("Duplicate Page") { store.duplicatePage(id: page.id) }
            Divider()
            Button("Move to Front") { store.movePage(id: page.id, toIndex: 0) }
            Button("Move to Back") {
                store.movePage(id: page.id, toIndex: store.state.pages.count - 1)
            }
            Divider()
            if store.missingSources.contains(page.source) {
                // Nothing to send anywhere: the file is already gone, and this
                // only forgets the page that was pointing at it.
                Button("Remove Page", role: .destructive) { store.removePage(id: page.id) }
            } else {
                Button(trashTitle(for: page), role: .destructive) { onTrash(targets(for: page)) }
            }
        }
        .gesture(dragGesture(for: page))
    }

    // MARK: - Selecting

    /// Which pages an action should act on: the selection when the page
    /// belongs to it, otherwise just the page itself.
    private func targets(for page: Page) -> [UUID] {
        selectionApplies(to: page) ? store.state.pages.map(\.id).filter(selection.contains) : [page.id]
    }

    private func selectionApplies(to page: Page) -> Bool {
        selection.count > 1 && selection.contains(page.id)
    }

    private func canApply(_ ids: Set<UUID>) -> Bool {
        let division = OriginalsWriter.divide(store.state.pages, pageIDs: ids)
        return !division.applied.isEmpty || !division.spilled.isEmpty
    }

    private func rotateTitle(_ base: String, page: Page) -> String {
        selectionApplies(to: page) ? "\(base) (\(selection.count) pages)" : base
    }

    /// Counted in files rather than pages: a scan two pages stand on leaves
    /// with both of them, and one PDF holds however many pages it holds.
    private func trashTitle(for page: Page) -> String {
        let ids = Set(targets(for: page))
        let files = Set(store.state.pages.filter { ids.contains($0.id) }.map(\.source.file))
        return files.count > 1 ? "Move \(files.count) Files to Trash" : "Move File to Trash"
    }

    /// A plain click opens the page — that is what the grid is for. Holding
    /// Command or Shift builds a selection for the batch actions instead, and
    /// deliberately does not open anything.
    private func click(page: Page, at index: Int) {
        let modifiers = NSEvent.modifierFlags
        if modifiers.contains(.command) {
            if selection.contains(page.id) { selection.remove(page.id) } else { selection.insert(page.id) }
            selectionAnchor = page.id
        } else if modifiers.contains(.shift), let anchor = selectionAnchor,
                  let from = store.state.pages.firstIndex(where: { $0.id == anchor }) {
            let range = from <= index ? from...index : index...from
            selection.formUnion(store.state.pages[range].map(\.id))
        } else {
            selection = [page.id]
            selectionAnchor = page.id
            onOpen(page.id)
        }
    }

    @ViewBuilder
    private var floatingCard: some View {
        if let drag,
           let index = store.state.pages.firstIndex(where: { $0.id == drag.pageID }) {
            PageCell(
                page: store.state.pages[index],
                number: index + 1,
                folder: store.folderURL!,
                outputRatio: store.state.outputRatio(for: store.state.pages[index]),
                isMissing: store.missingSources.contains(store.state.pages[index].source),
                sourceRevision: store.sourceRevision
            )
            .frame(width: drag.size.width, height: drag.size.height)
            .scaleEffect(1.04)
            .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
            .position(drag.point)
            .allowsHitTesting(false)
        }
    }

    // MARK: - Dragging

    struct DragState {
        let pageID: UUID
        /// Where the pointer grabbed the card, relative to its center.
        let grabOffset: CGSize
        let size: CGSize
        var point: CGPoint
    }

    private func dragGesture(for page: Page) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named(Self.boardSpace))
            .onChanged { value in
                var current: DragState
                if let drag, drag.pageID == page.id {
                    current = drag
                } else {
                    guard let frame = cellFrames[page.id] else { return }
                    current = DragState(
                        pageID: page.id,
                        grabOffset: CGSize(
                            width: value.startLocation.x - frame.midX,
                            height: value.startLocation.y - frame.midY
                        ),
                        size: frame.size,
                        point: CGPoint(x: frame.midX, y: frame.midY)
                    )
                }
                current.point = CGPoint(
                    x: value.location.x - current.grabOffset.width,
                    y: value.location.y - current.grabOffset.height
                )
                drag = current
                reorderIfNeeded(for: current)
            }
            .onEnded { _ in
                drag = nil
            }
    }

    /// Moves the dragged page into the slot its card currently hovers over,
    /// which makes the neighbours slide aside to open a gap.
    private func reorderIfNeeded(for drag: DragState) {
        guard let currentIndex = store.state.pages.firstIndex(where: { $0.id == drag.pageID }),
              let target = nearestSlot(to: drag.point),
              target != currentIndex
        else { return }
        store.movePage(id: drag.pageID, toIndex: target)
    }

    private func nearestSlot(to point: CGPoint) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        for (index, page) in store.state.pages.enumerated() {
            guard let frame = cellFrames[page.id] else { continue }
            let dx = frame.midX - point.x
            let dy = frame.midY - point.y
            let distance = dx * dx + dy * dy
            if best == nil || distance < best!.distance {
                best = (index, distance)
            }
        }
        return best?.index
    }
}

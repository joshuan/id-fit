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

    @State private var drag: DragState?
    @State private var cellFrames: [UUID: CGRect] = [:]

    private static let boardSpace = "board"
    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 240), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            if selection.count > 1 {
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

    /// Appears once more than one page is picked, so a batch of scans off by
    /// the same quarter turn can be fixed in one go.
    private var selectionBar: some View {
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
            isMissing: store.missingSources.contains(page.source)
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
            Button("Duplicate Page") { store.duplicatePage(id: page.id) }
            Divider()
            Button("Move to Front") { store.movePage(id: page.id, toIndex: 0) }
            Button("Move to Back") {
                store.movePage(id: page.id, toIndex: store.state.pages.count - 1)
            }
            if store.missingSources.contains(page.source) {
                Divider()
                Button("Remove Page", role: .destructive) { store.removePage(id: page.id) }
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

    private func rotateTitle(_ base: String, page: Page) -> String {
        selectionApplies(to: page) ? "\(base) (\(selection.count) pages)" : base
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
                isMissing: store.missingSources.contains(store.state.pages[index].source)
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

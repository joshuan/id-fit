import SwiftUI

struct PagesGridView: View {
    @Bindable var store: DocumentStore

    @State private var drag: DragState?
    @State private var cellFrames: [UUID: CGRect] = [:]
    @State private var editorTarget: EditorTarget?
    @State private var isEditingCustomRatio = false
    @State private var isConfirmingApply = false

    private static let boardSpace = "board"
    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 240), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            if !store.missingSources.isEmpty {
                missingBanner
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
        .navigationTitle(store.folderName)
        .toolbar {
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
                Button("Export PDF…", systemImage: "square.and.arrow.up") {
                    Task { await store.runExportFlow() }
                }
                .disabled(store.state.pages.isEmpty || store.isExporting)
            }
            ToolbarItem {
                Menu {
                    Button("Detect Edges on All Pages") {
                        Task { await store.redetectEdgesOnAllPages() }
                    }
                    .disabled(store.isDetectingEdges)
                    Divider()
                    Button("Export Cropped Files to Folder…") {
                        Task { await store.runFileExportFlow() }
                    }
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
        .sheet(item: $editorTarget) { target in
            CropEditorView(store: store, pageIndex: target.id)
        }
        .sheet(isPresented: $isEditingCustomRatio) {
            CustomRatioSheet(current: store.state.cropAspectRatio) { ratio in
                store.setAspectRatio(ratio)
            }
        }
        .sheet(isPresented: $isConfirmingApply) {
            ApplyToOriginalsSheet(store: store)
        }
        .overlay {
            if store.isExporting {
                ProgressView("Exporting…")
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
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

    private var grid: some View {
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
        .onTapGesture(count: 2) { editorTarget = EditorTarget(id: index) }
        .contextMenu {
            Button("Crop…") { editorTarget = EditorTarget(id: index) }
            Divider()
            Button("Rotate Left") { store.rotatePage(id: page.id, by: -90) }
            Button("Rotate Right") { store.rotatePage(id: page.id, by: 90) }
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

    private var hasEdits: Bool {
        store.state.pages.contains { $0.crop != nil || $0.rotation != 0 }
    }

    struct EditorTarget: Identifiable {
        let id: Int
    }
}

struct PageCell: View {
    let page: Page
    let number: Int
    let folder: URL
    let outputRatio: Double?
    let isMissing: Bool

    @State private var thumbnail: CGImage?

    private var caption: String {
        if let pdfPage = page.source.pdfPage {
            return "\(page.source.file) · p\(pdfPage + 1)"
        }
        return page.source.file
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary.opacity(0.5))
                if let thumbnail {
                    // Show the page as it will be exported: rotated, cropped.
                    CroppedImage(
                        image: thumbnail,
                        crop: page.crop.map { CropGeometry.rotated($0, by: page.rotation) },
                        outputRatio: outputRatio
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(4)
                } else if isMissing {
                    VStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.title)
                            .foregroundStyle(.orange)
                        Text("File missing")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(height: 190)
            .overlay(alignment: .topLeading) {
                Text("\(number)")
                    .font(.caption.bold())
                    .monospacedDigit()
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.thinMaterial, in: Capsule())
                    .padding(6)
            }

            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .contentShape(Rectangle())
        .task(id: PagePreviewKey(page)) {
            guard !isMissing else { return }
            guard let image = await ThumbnailProvider.shared.thumbnail(for: page.source, in: folder) else { return }
            thumbnail = page.rotation == 0 ? image : PageRenderer.rotate(image, by: page.rotation)
        }
    }
}

/// Renders only the cropped region of an image, at the shared output ratio.
private struct CroppedImage: View {
    let image: CGImage
    let crop: CropRect?
    let outputRatio: Double?

    var body: some View {
        if let crop, let outputRatio, crop.width > 0, crop.height > 0 {
            GeometryReader { geometry in
                let fullWidth = geometry.size.width / crop.width
                let fullHeight = geometry.size.height / crop.height
                Image(decorative: image, scale: 1)
                    .resizable()
                    .frame(width: fullWidth, height: fullHeight)
                    .offset(x: -crop.x * fullWidth, y: -crop.y * fullHeight)
            }
            .aspectRatio(outputRatio, contentMode: .fit)
            .clipped()
        } else {
            Image(decorative: image, scale: 1)
                .resizable()
                .scaledToFit()
        }
    }
}

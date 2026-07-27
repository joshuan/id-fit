import SwiftUI

struct PagesGridView: View {
    @Bindable var store: DocumentStore

    @State private var drag: DragState?
    @State private var cellFrames: [UUID: CGRect] = [:]
    @State private var editorTarget: EditorTarget?
    @State private var isEditingCustomRatio = false

    private static let boardSpace = "board"
    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 240), spacing: 16)]

    var body: some View {
        ZStack {
            grid
            floatingCard
        }
        .coordinateSpace(.named(Self.boardSpace))
        .overlay {
            if store.isLoading {
                ProgressView()
            } else if store.state.pages.isEmpty {
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
                Text("\(store.state.pages.count) pages")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            ToolbarItem { aspectRatioMenu }
            ToolbarItem {
                Button("Export PDF…", systemImage: "square.and.arrow.up") {
                    Task { await store.runExportFlow() }
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
        .overlay {
            if store.isExporting {
                ProgressView("Exporting…")
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
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
            outputRatio: store.state.cropAspectRatio?.ratio,
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
            Button("Move to Front") { store.movePage(id: page.id, toIndex: 0) }
            Button("Move to Back") {
                store.movePage(id: page.id, toIndex: store.state.pages.count - 1)
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
                outputRatio: store.state.cropAspectRatio?.ratio,
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

    // MARK: - Aspect ratio

    private var aspectRatioMenu: some View {
        Menu {
            ForEach(AspectRatioPreset.allCases) { preset in
                Button {
                    store.setAspectRatio(preset.aspectRatio)
                } label: {
                    if currentPreset == preset {
                        Label(preset.title, systemImage: "checkmark")
                    } else {
                        Text(preset.title)
                    }
                }
            }
            Divider()
            Button("Custom…") { isEditingCustomRatio = true }
        } label: {
            Label(ratioLabel, systemImage: "aspectratio")
        }
        .help("Crop aspect ratio, shared by all pages")
    }

    private var currentPreset: AspectRatioPreset? {
        AspectRatioPreset.matching(store.state.cropAspectRatio)
    }

    private var ratioLabel: String {
        if let currentPreset { return currentPreset.title }
        guard let ratio = store.state.cropAspectRatio else { return AspectRatioPreset.original.title }
        return "Custom (\(formatted(ratio.width)) × \(formatted(ratio.height)))"
    }

    private func formatted(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }

    struct EditorTarget: Identifiable {
        let id: Int
    }
}

private struct CustomRatioSheet: View {
    let current: AspectRatio?
    let onApply: (AspectRatio) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var width: Double
    @State private var height: Double

    init(current: AspectRatio?, onApply: @escaping (AspectRatio) -> Void) {
        self.current = current
        self.onApply = onApply
        _width = State(initialValue: current?.width ?? 210)
        _height = State(initialValue: current?.height ?? 297)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Custom Aspect Ratio")
                .font(.headline)
            HStack {
                TextField("Width", value: $width, format: .number)
                    .frame(width: 90)
                Text("×")
                TextField("Height", value: $height, format: .number)
                    .frame(width: 90)
            }
            .textFieldStyle(.roundedBorder)
            Text("Only the proportion matters, not the units.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Apply") {
                    onApply(AspectRatio(width: width, height: height))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(width <= 0 || height <= 0)
            }
        }
        .padding(20)
        .frame(width: 320)
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
                    // Show the page as it will be exported, crop included.
                    CroppedImage(image: thumbnail, crop: page.crop, outputRatio: outputRatio)
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
        .task(id: page.source) {
            guard !isMissing else { return }
            thumbnail = await ThumbnailProvider.shared.thumbnail(for: page.source, in: folder)
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

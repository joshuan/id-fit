import SwiftUI

/// Full-page crop editor. The aspect ratio is fixed document-wide, so the
/// user only frames the content; the rectangle can never change shape.
///
/// Everything here works in the page's *rotated* space — what the export will
/// look like — and crops are converted back to source space on the way out.
struct CropEditorView: View {
    let store: DocumentStore
    @State var pageIndex: Int
    @Environment(\.dismiss) private var dismiss

    @State private var preview: CGImage?
    @State private var isEditingCustomRatio = false

    private var page: Page? {
        store.state.pages.indices.contains(pageIndex) ? store.state.pages[pageIndex] : nil
    }

    /// Source size as seen after rotation.
    private var displayedSize: CGSize? {
        guard let page, let size = store.sourceSizes[page.source] else { return nil }
        return page.rotation % 180 == 0 ? size : CGSize(width: size.height, height: size.width)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            canvas
            Divider()
            footer
        }
        .frame(minWidth: 760, minHeight: 580)
        .task(id: page.map(PagePreviewKey.init)) { await loadPreview() }
        .sheet(isPresented: $isEditingCustomRatio) {
            CustomRatioSheet(current: store.state.cropAspectRatio) { ratio in
                store.setAspectRatio(ratio)
            }
        }
    }

    private var header: some View {
        HStack {
            Button {
                pageIndex -= 1
            } label: {
                Label("Previous", systemImage: "chevron.left")
            }
            .disabled(pageIndex == 0)
            .keyboardShortcut(.leftArrow, modifiers: [])

            Button {
                pageIndex += 1
            } label: {
                Label("Next", systemImage: "chevron.right")
            }
            .disabled(pageIndex >= store.state.pages.count - 1)
            .keyboardShortcut(.rightArrow, modifiers: [])

            Spacer()

            VStack(spacing: 2) {
                Text("Page \(pageIndex + 1) of \(store.state.pages.count)")
                    .font(.headline)
                if let page {
                    Text(page.source.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            AspectRatioMenu(store: store, isEditingCustom: $isEditingCustomRatio)
                .fixedSize()

            Button {
                if let page { store.rotatePage(id: page.id, by: -90) }
            } label: {
                Label("Rotate Left", systemImage: "rotate.left")
            }
            .keyboardShortcut("[", modifiers: .command)

            Button {
                if let page { store.rotatePage(id: page.id, by: 90) }
            } label: {
                Label("Rotate Right", systemImage: "rotate.right")
            }
            .keyboardShortcut("]", modifiers: .command)

            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    @ViewBuilder
    private var canvas: some View {
        if let page, let size = displayedSize, let preview {
            CropCanvas(
                image: preview,
                displayedSize: size,
                crop: page.crop.map { CropGeometry.rotated($0, by: page.rotation) },
                outputRatio: store.state.cropAspectRatio?.ratio,
                onChange: { edited in
                    store.setCrop(CropGeometry.rotated(edited, by: -page.rotation), forPageID: page.id)
                },
                onDraw: { drawn in
                    store.defineAspectRatio(fromDrawnCrop: drawn, onPageID: page.id)
                }
            )
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let page, store.missingSources.contains(page.source) {
            ContentUnavailableView(
                "File is missing",
                systemImage: "exclamationmark.triangle",
                description: Text("\(page.source.file) is not in the folder right now. Its crop is kept.")
            )
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var footer: some View {
        HStack {
            if store.state.cropAspectRatio == nil {
                Label(
                    "Drag on the page to draw a crop — its shape becomes the ratio for every page. Or pick a preset above.",
                    systemImage: "hand.draw"
                )
                .foregroundStyle(.secondary)
                .font(.callout)
            } else {
                Button("Reset Crop") {
                    if let page { store.resetCrop(forPageID: page.id) }
                }
                Button("Apply This Framing to All Pages") {
                    if let page { store.applyCropToAllPages(fromPageID: page.id) }
                }
                .disabled(page?.crop == nil)
            }
            Spacer()
        }
        .padding(12)
    }

    private func loadPreview() async {
        preview = nil
        guard let page, let folder = store.folderURL else { return }
        guard let image = await ThumbnailProvider.shared.thumbnail(
            for: page.source, in: folder, maxPixel: 1600
        ) else { return }
        // Rotate once here rather than on every redraw.
        preview = page.rotation == 0 ? image : PageRenderer.rotate(image, by: page.rotation)
    }
}

/// Draws the page with a dimmed area outside the crop and drag handles on the
/// corners. Editing happens in the page's rotated pixel space, which is the
/// same space the exported image lives in.
private struct CropCanvas: View {
    let image: CGImage
    let displayedSize: CGSize
    let crop: CropRect?
    let outputRatio: Double?
    let onChange: (CropRect) -> Void
    /// Called with a freehand rectangle when no ratio has been chosen yet.
    let onDraw: (CropRect) -> Void

    @State private var gestureStart: CropRect?
    @State private var drawnRect: CGRect?

    private let handleSize: CGFloat = 14
    private let hitSize: CGFloat = 32

    var body: some View {
        GeometryReader { geometry in
            let frame = fittedImageFrame(in: geometry.size)

            ZStack(alignment: .topLeading) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)

                if outputRatio == nil {
                    // Nothing to frame yet: let the user draw the shape that
                    // will define the ratio for the whole document.
                    Color.white.opacity(0.001)
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                        .contentShape(Rectangle())
                        .pointerStyle(.rectSelection)
                        .gesture(drawGesture(frame: frame))

                    if let drawnRect {
                        Rectangle()
                            .strokeBorder(.white, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                            .background(Rectangle().fill(.white.opacity(0.12)))
                            .frame(width: drawnRect.width, height: drawnRect.height)
                            .offset(x: frame.minX + drawnRect.minX, y: frame.minY + drawnRect.minY)
                            .allowsHitTesting(false)
                    }
                }

                if let crop, outputRatio != nil {
                    let rect = viewRect(for: crop, in: frame)

                    Color.black.opacity(0.55)
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                        .reverseMask {
                            Rectangle()
                                .frame(width: rect.width, height: rect.height)
                                .offset(x: rect.minX, y: rect.minY)
                        }
                        .allowsHitTesting(false)

                    Rectangle()
                        .strokeBorder(.white, lineWidth: 1.5)
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                        .contentShape(Rectangle())
                        .pointerStyle(.grabIdle)
                        .gesture(moveGesture(crop: crop, frame: frame))

                    ForEach(CropGeometry.Corner.allCases, id: \.self) { corner in
                        let point = handlePosition(corner: corner, in: rect)
                        Circle()
                            .fill(.white)
                            .overlay(Circle().strokeBorder(.black.opacity(0.4), lineWidth: 1))
                            .frame(width: handleSize, height: handleSize)
                            // A generous invisible target around the dot, so
                            // the corner is easy to grab.
                            .frame(width: hitSize, height: hitSize)
                            .contentShape(Rectangle())
                            .pointerStyle(.frameResize(position: resizePosition(for: corner)))
                            .offset(x: point.x - hitSize / 2, y: point.y - hitSize / 2)
                            .gesture(resizeGesture(corner: corner, crop: crop, frame: frame))
                    }
                }
            }
        }
    }

    // MARK: - Gestures

    /// Attached to a layer that exactly covers the image, so these locations
    /// are already relative to the image's top-left corner.
    private func drawGesture(frame: CGRect) -> some Gesture {
        let bounds = CGRect(origin: .zero, size: frame.size)
        return DragGesture(minimumDistance: 4)
            .onChanged { value in
                drawnRect = rectangle(from: value.startLocation, to: value.location, clampedTo: bounds)
            }
            .onEnded { value in
                let rect = rectangle(from: value.startLocation, to: value.location, clampedTo: bounds)
                drawnRect = nil
                // Ignore stray clicks that would produce a degenerate ratio.
                guard rect.width > frame.width * 0.05, rect.height > frame.height * 0.05 else { return }
                onDraw(CropRect(
                    x: rect.minX / frame.width,
                    y: rect.minY / frame.height,
                    width: rect.width / frame.width,
                    height: rect.height / frame.height
                ).clampedToUnitSquare())
            }
    }

    private func rectangle(from start: CGPoint, to end: CGPoint, clampedTo frame: CGRect) -> CGRect {
        let minX = min(max(min(start.x, end.x), frame.minX), frame.maxX)
        let maxX = min(max(max(start.x, end.x), frame.minX), frame.maxX)
        let minY = min(max(min(start.y, end.y), frame.minY), frame.maxY)
        let maxY = min(max(max(start.y, end.y), frame.minY), frame.maxY)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func moveGesture(crop: CropRect, frame: CGRect) -> some Gesture {
        DragGesture()
            .onChanged { value in
                let start = gestureStart ?? crop
                if gestureStart == nil { gestureStart = crop }
                let delta = CGSize(
                    width: value.translation.width * (displayedSize.width / frame.width),
                    height: value.translation.height * (displayedSize.height / frame.height)
                )
                onChange(CropGeometry.moved(start, byPixels: delta, sourceSize: displayedSize))
            }
            .onEnded { _ in gestureStart = nil }
    }

    /// Tracked by how far the pointer moved rather than where it is: a
    /// gesture's `location` is reported in the coordinate space of the view it
    /// is attached to — here the small handle — while `translation` is a plain
    /// delta and needs no conversion. Using the former made the corner jump.
    private func resizeGesture(corner: CropGeometry.Corner, crop: CropRect, frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard let outputRatio else { return }
                let start = gestureStart ?? crop
                if gestureStart == nil { gestureStart = crop }

                let origin = CropGeometry.cornerPoint(corner, of: start, sourceSize: displayedSize)
                let point = CGPoint(
                    x: origin.x + value.translation.width * (displayedSize.width / frame.width),
                    y: origin.y + value.translation.height * (displayedSize.height / frame.height)
                )
                onChange(CropGeometry.resized(
                    start,
                    corner: corner,
                    toPixelPoint: point,
                    outputRatio: outputRatio,
                    sourceSize: displayedSize
                ))
            }
            .onEnded { _ in gestureStart = nil }
    }

    // MARK: - Layout helpers

    private func fittedImageFrame(in container: CGSize) -> CGRect {
        let scale = min(container.width / displayedSize.width, container.height / displayedSize.height)
        let size = CGSize(width: displayedSize.width * scale, height: displayedSize.height * scale)
        return CGRect(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    private func viewRect(for crop: CropRect, in frame: CGRect) -> CGRect {
        CGRect(
            x: frame.minX + crop.x * frame.width,
            y: frame.minY + crop.y * frame.height,
            width: crop.width * frame.width,
            height: crop.height * frame.height
        )
    }

    private func resizePosition(for corner: CropGeometry.Corner) -> FrameResizePosition {
        switch corner {
        case .topLeft: .topLeading
        case .topRight: .topTrailing
        case .bottomLeft: .bottomLeading
        case .bottomRight: .bottomTrailing
        }
    }

    private func handlePosition(corner: CropGeometry.Corner, in rect: CGRect) -> CGPoint {
        switch corner {
        case .topLeft: CGPoint(x: rect.minX, y: rect.minY)
        case .topRight: CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomRight: CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }
}

private extension View {
    /// Punches a hole into the receiver — used for the dimmed area around the
    /// crop rectangle.
    func reverseMask<Mask: View>(@ViewBuilder _ mask: () -> Mask) -> some View {
        self.mask {
            ZStack(alignment: .topLeading) {
                Rectangle()
                mask()
                    .blendMode(.destinationOut)
            }
            .compositingGroup()
        }
    }
}

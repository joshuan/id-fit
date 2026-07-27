import SwiftUI

/// Full-page crop editor. The aspect ratio is fixed document-wide, so the
/// user only frames the content; the rectangle can never change shape.
struct CropEditorView: View {
    let store: DocumentStore
    @State var pageIndex: Int
    @Environment(\.dismiss) private var dismiss

    @State private var preview: CGImage?

    private var page: Page? {
        store.state.pages.indices.contains(pageIndex) ? store.state.pages[pageIndex] : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            canvas
            Divider()
            footer
        }
        .frame(minWidth: 720, minHeight: 560)
        .task(id: page?.source) { await loadPreview() }
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
                    Text(page.source.pdfPage.map { "\(page.source.file) · p\($0 + 1)" } ?? page.source.file)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    @ViewBuilder
    private var canvas: some View {
        if let page, let size = store.sourceSizes[page.source], let preview {
            CropCanvas(
                image: preview,
                sourceSize: size,
                crop: page.crop,
                outputRatio: store.state.cropAspectRatio?.ratio,
                rotation: page.rotation
            ) { newCrop in
                store.setCrop(newCrop, forPageID: page.id)
            }
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
                Label("Choose an aspect ratio to start cropping.", systemImage: "info.circle")
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
        preview = await ThumbnailProvider.shared.thumbnail(for: page.source, in: folder, maxPixel: 1600)
    }
}

/// Draws the page with a dimmed area outside the crop and drag handles on the
/// corners. All editing happens in source-pixel space and is converted to
/// normalized coordinates on the way out.
private struct CropCanvas: View {
    let image: CGImage
    let sourceSize: CGSize
    let crop: CropRect?
    let outputRatio: Double?
    let rotation: Int
    let onChange: (CropRect) -> Void

    @State private var gestureStart: CropRect?

    private let handleSize: CGFloat = 14

    var body: some View {
        GeometryReader { geometry in
            let frame = fittedImageFrame(in: geometry.size)

            ZStack(alignment: .topLeading) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)

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
                        .gesture(moveGesture(crop: crop, frame: frame))

                    ForEach(CropGeometry.Corner.allCases, id: \.self) { corner in
                        let point = handlePosition(corner: corner, in: rect)
                        Circle()
                            .fill(.white)
                            .overlay(Circle().strokeBorder(.black.opacity(0.4), lineWidth: 1))
                            .frame(width: handleSize, height: handleSize)
                            .offset(x: point.x - handleSize / 2, y: point.y - handleSize / 2)
                            .gesture(resizeGesture(corner: corner, crop: crop, frame: frame))
                    }
                }
            }
        }
    }

    // MARK: - Gestures

    private func moveGesture(crop: CropRect, frame: CGRect) -> some Gesture {
        DragGesture()
            .onChanged { value in
                let start = gestureStart ?? crop
                if gestureStart == nil { gestureStart = crop }
                let scale = sourceSize.width / frame.width
                let delta = CGSize(
                    width: value.translation.width * scale,
                    height: value.translation.height * (sourceSize.height / frame.height)
                )
                onChange(CropGeometry.moved(start, byPixels: delta, sourceSize: sourceSize))
            }
            .onEnded { _ in gestureStart = nil }
    }

    private func resizeGesture(corner: CropGeometry.Corner, crop: CropRect, frame: CGRect) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard let outputRatio else { return }
                let start = gestureStart ?? crop
                if gestureStart == nil { gestureStart = crop }
                let point = CGPoint(
                    x: (value.location.x - frame.minX) / frame.width * sourceSize.width,
                    y: (value.location.y - frame.minY) / frame.height * sourceSize.height
                )
                onChange(CropGeometry.resized(
                    start,
                    corner: corner,
                    toPixelPoint: point,
                    outputRatio: outputRatio,
                    sourceSize: sourceSize,
                    rotation: rotation
                ))
            }
            .onEnded { _ in gestureStart = nil }
    }

    // MARK: - Layout helpers

    private func fittedImageFrame(in container: CGSize) -> CGRect {
        let scale = min(container.width / sourceSize.width, container.height / sourceSize.height)
        let size = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
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

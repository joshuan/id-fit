import SwiftUI

/// One page drawn the way it will be exported: rotated, straightened, cropped.
///
/// The same cell serves the grid and the filmstrip under the editor — only the
/// size and whether it carries a caption differ.
struct PageCell: View {
    enum Layout {
        case grid
        case filmstrip
        case result

        var pictureHeight: CGFloat {
            switch self {
            case .grid: 190
            case .filmstrip: 76
            case .result: 150
            }
        }

        var cornerRadius: CGFloat {
            switch self {
            case .grid: 8
            case .filmstrip, .result: 6
            }
        }

        var showsCaption: Bool { self == .grid }
    }

    let page: Page
    let number: Int
    let folder: URL
    let outputRatio: Double?
    let isMissing: Bool
    var layout: Layout = .grid
    var sourceRevision: Int = 0

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
                RoundedRectangle(cornerRadius: layout.cornerRadius)
                    .fill(.quaternary.opacity(0.5))
                if let thumbnail {
                    // Show the page as it will be exported: rotated, cropped.
                    CroppedImage(
                        image: thumbnail,
                        // A straightened or tilted page is already exactly its
                        // own content; there is nothing left to crop off.
                        crop: page.composition == nil && page.quad == nil && page.tilt == 0
                            ? page.crop.map { CropGeometry.rotated($0, by: page.rotation) }
                            : nil,
                        outputRatio: outputRatio
                    )
                    .clipShape(RoundedRectangle(cornerRadius: layout.cornerRadius))
                    .padding(4)
                } else if let composition = page.composition, !composition.isComplete {
                    Text("Draw part \(composition.regions.count + 1) of \(composition.partCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(8)
                } else if isMissing {
                    VStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(layout == .grid ? .title : .body)
                            .foregroundStyle(.orange)
                        if layout.showsCaption {
                            Text("File missing")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(height: layout.pictureHeight)
            .overlay(alignment: .topLeading) {
                if layout != .result { badge }
            }

            if layout.showsCaption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .contentShape(Rectangle())
        .task(id: PageThumbnailKey(page, outputRatio: outputRatio, sourceRevision: sourceRevision)) {
            guard !isMissing else { return }
            if let composition = page.composition, !composition.isComplete {
                thumbnail = nil
                return
            }
            // Corners and the tilt slider are now dragged with this cell on
            // screen, and every step of that drag arrives here as a new key. A
            // page that already has a picture waits for the drag to settle
            // rather than warping itself dozens of times a second; a page
            // showing nothing yet is loaded at once.
            if layout != .result && (page.composition != nil || page.quad != nil || page.tilt != 0) && thumbnail != nil {
                try? await Task.sleep(for: .milliseconds(40))
                guard !Task.isCancelled else { return }
            }
            guard let image = await ThumbnailProvider.shared.thumbnail(for: page.source, in: folder) else { return }
            guard !Task.isCancelled else { return }
            if page.composition != nil || page.quad != nil || page.tilt != 0 {
                let page = page
                let ratio = outputRatio
                let rendered = await Task.detached(priority: .userInitiated) {
                    PageRenderer.render(image, for: page, outputRatio: ratio)
                }.value
                guard !Task.isCancelled else { return }
                thumbnail = rendered
            } else {
                thumbnail = page.rotation == 0 ? image : PageRenderer.rotate(image, by: page.rotation)
            }
        }
    }

    private var badge: some View {
        Text("\(number)")
            .font(layout == .grid ? .caption.bold() : .caption2.bold())
            .monospacedDigit()
            .padding(.horizontal, layout == .grid ? 7 : 5)
            .padding(.vertical, layout == .grid ? 3 : 2)
            .background(.thinMaterial, in: Capsule())
            .padding(layout == .grid ? 6 : 4)
    }
}

/// Renders only the cropped region of an image, at the proportions it will
/// export with.
private struct CroppedImage: View {
    let image: CGImage
    let crop: CropRect?
    let outputRatio: Double?

    var body: some View {
        if let crop, crop.width > 0, crop.height > 0 {
            GeometryReader { geometry in
                let fullWidth = geometry.size.width / crop.width
                let fullHeight = geometry.size.height / crop.height
                Image(decorative: image, scale: 1)
                    .resizable()
                    .frame(width: fullWidth, height: fullHeight)
                    .offset(x: -crop.x * fullWidth, y: -crop.y * fullHeight)
            }
            // Without a common format the crop's own proportions are the
            // page's, measured on the picture the crop was drawn over.
            .aspectRatio(outputRatio ?? shownRatio(crop), contentMode: .fit)
            .clipped()
        } else {
            Image(decorative: image, scale: 1)
                .resizable()
                .scaledToFit()
        }
    }

    private func shownRatio(_ crop: CropRect) -> Double {
        (crop.width * Double(image.width)) / (crop.height * Double(image.height))
    }
}

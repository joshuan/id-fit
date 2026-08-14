import SwiftUI

/// One page drawn the way it will be exported: rotated, straightened, cropped.
///
/// The same cell serves the grid and the filmstrip under the editor — only the
/// size and whether it carries a caption differ.
struct PageCell: View {
    enum Layout {
        case grid
        case filmstrip

        var pictureHeight: CGFloat {
            switch self {
            case .grid: 190
            case .filmstrip: 76
            }
        }

        var cornerRadius: CGFloat {
            switch self {
            case .grid: 8
            case .filmstrip: 6
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
                        crop: page.quad == nil && page.tilt == 0
                            ? page.crop.map { CropGeometry.rotated($0, by: page.rotation) }
                            : nil,
                        outputRatio: outputRatio
                    )
                    .clipShape(RoundedRectangle(cornerRadius: layout.cornerRadius))
                    .padding(4)
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
            .overlay(alignment: .topLeading) { badge }

            if layout.showsCaption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .contentShape(Rectangle())
        .task(id: PageThumbnailKey(page)) {
            guard !isMissing else { return }
            // Corners and the tilt slider are now dragged with this cell on
            // screen, and every step of that drag arrives here as a new key. A
            // page that already has a picture waits for the drag to settle
            // rather than warping itself dozens of times a second; a page
            // showing nothing yet is loaded at once.
            if (page.quad != nil || page.tilt != 0) && thumbnail != nil {
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
            }
            guard let image = await ThumbnailProvider.shared.thumbnail(for: page.source, in: folder) else { return }
            let size = CGSize(width: image.width, height: image.height)

            // Straightened pages are shown straightened, so the grid matches
            // what the export will contain.
            if let quad = page.quad,
               let aspect = PageRenderer.straighteningAspect(
                   quad: quad,
                   outputRatio: outputRatio,
                   rotation: page.rotation,
                   sourceSize: size
               ),
               let corrected = PerspectiveCorrector.straighten(image, quad: quad, targetAspect: aspect) {
                thumbnail = PageRenderer.rotate(corrected, by: page.rotation)
                return
            }

            // A tilted page travels the same road, its corners being the crop
            // turned under the page.
            if page.quad == nil, page.tilt != 0 {
                let crop = TiltGeometry.fitted(
                    page.crop ?? CropRect(x: 0, y: 0, width: 1, height: 1),
                    tilt: page.tilt, sourceSize: size
                )
                let aspect = CropGeometry.exportedRatio(crop, sourceSize: size)
                if aspect > 0, let corrected = PerspectiveCorrector.straighten(
                    image,
                    quad: TiltGeometry.derivedQuad(crop: crop, tilt: page.tilt, sourceSize: size),
                    targetAspect: aspect
                ) {
                    thumbnail = PageRenderer.rotate(corrected, by: page.rotation)
                    return
                }
            }
            thumbnail = page.rotation == 0 ? image : PageRenderer.rotate(image, by: page.rotation)
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

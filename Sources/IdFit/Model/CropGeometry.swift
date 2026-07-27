import CoreGraphics
import Foundation

/// Pure crop math. Crops are stored normalized (fractions of the source), but
/// the aspect ratio the user cares about is the ratio of the *exported*
/// image in pixels — so every conversion needs the source's pixel size.
enum CropGeometry {
    enum Corner: Hashable, CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    /// Smallest allowed crop, as a fraction of the source, to keep the rect
    /// grabbable and the export meaningful.
    static let minimumFraction: Double = 0.05

    /// The width/height ratio the crop must have *in source pixels* to export
    /// at `outputRatio`. A page rotated by 90° swaps the two.
    static func sourceAspect(outputRatio: Double, rotation: Int) -> Double {
        let normalized = ((rotation % 360) + 360) % 360
        return normalized % 180 == 0 ? outputRatio : 1 / outputRatio
    }

    /// Maps a crop expressed on the unrotated source into the coordinates of
    /// the same source rotated clockwise by `degrees`.
    static func rotated(_ crop: CropRect, by degrees: Int) -> CropRect {
        switch ((degrees % 360) + 360) % 360 {
        case 90:
            CropRect(x: 1 - crop.y - crop.height, y: crop.x, width: crop.height, height: crop.width)
        case 180:
            CropRect(x: 1 - crop.x - crop.width, y: 1 - crop.y - crop.height, width: crop.width, height: crop.height)
        case 270:
            CropRect(x: crop.y, y: 1 - crop.x - crop.width, width: crop.height, height: crop.width)
        default:
            crop
        }
    }

    /// The width/height ratio this crop will actually produce once exported.
    static func exportedRatio(_ crop: CropRect, sourceSize: CGSize, rotation: Int = 0) -> Double {
        let width = crop.width * sourceSize.width
        let height = crop.height * sourceSize.height
        guard width > 0, height > 0 else { return 0 }
        let normalized = ((rotation % 360) + 360) % 360
        return normalized % 180 == 0 ? width / height : height / width
    }

    static func pixelRect(_ crop: CropRect, sourceSize: CGSize) -> CGRect {
        CGRect(
            x: crop.x * sourceSize.width,
            y: crop.y * sourceSize.height,
            width: crop.width * sourceSize.width,
            height: crop.height * sourceSize.height
        )
    }

    static func cropRect(_ pixels: CGRect, sourceSize: CGSize) -> CropRect {
        CropRect(
            x: pixels.origin.x / sourceSize.width,
            y: pixels.origin.y / sourceSize.height,
            width: pixels.width / sourceSize.width,
            height: pixels.height / sourceSize.height
        ).clampedToUnitSquare()
    }

    /// The largest crop of the required ratio, centered on the source.
    static func centeredCrop(outputRatio: Double, sourceSize: CGSize, rotation: Int = 0) -> CropRect {
        let aspect = sourceAspect(outputRatio: outputRatio, rotation: rotation)
        var width = sourceSize.width
        var height = width / aspect
        if height > sourceSize.height {
            height = sourceSize.height
            width = height * aspect
        }
        let rect = CGRect(
            x: (sourceSize.width - width) / 2,
            y: (sourceSize.height - height) / 2,
            width: width,
            height: height
        )
        return cropRect(rect, sourceSize: sourceSize)
    }

    /// Reshapes an existing crop to a new ratio, keeping its center and as
    /// much of its area as fits.
    static func refit(_ crop: CropRect, outputRatio: Double, sourceSize: CGSize, rotation: Int = 0) -> CropRect {
        let aspect = sourceAspect(outputRatio: outputRatio, rotation: rotation)
        let current = pixelRect(crop, sourceSize: sourceSize)
        let center = CGPoint(x: current.midX, y: current.midY)

        var width = current.width
        var height = width / aspect
        if height > current.height {
            height = current.height
            width = height * aspect
        }
        // Grow back into the source if the shape allows it.
        let maxWidth = min(center.x, sourceSize.width - center.x) * 2
        let maxHeight = min(center.y, sourceSize.height - center.y) * 2
        let scale = min(maxWidth / width, maxHeight / height)
        if scale > 1 {
            width *= scale
            height *= scale
        }

        let rect = CGRect(
            x: center.x - width / 2,
            y: center.y - height / 2,
            width: width,
            height: height
        )
        return cropRect(rect, sourceSize: sourceSize).clampedToUnitSquare()
    }

    /// Moves the crop by a delta given in source pixels, keeping it inside
    /// the source.
    static func moved(_ crop: CropRect, byPixels delta: CGSize, sourceSize: CGSize) -> CropRect {
        var rect = pixelRect(crop, sourceSize: sourceSize)
        rect.origin.x = min(max(rect.origin.x + delta.width, 0), sourceSize.width - rect.width)
        rect.origin.y = min(max(rect.origin.y + delta.height, 0), sourceSize.height - rect.height)
        return cropRect(rect, sourceSize: sourceSize)
    }

    /// Resizes the crop by dragging one corner; the opposite corner stays
    /// put, the ratio is preserved, and the result stays inside the source.
    static func resized(
        _ crop: CropRect,
        corner: Corner,
        toPixelPoint point: CGPoint,
        outputRatio: Double,
        sourceSize: CGSize,
        rotation: Int = 0
    ) -> CropRect {
        let aspect = sourceAspect(outputRatio: outputRatio, rotation: rotation)
        let rect = pixelRect(crop, sourceSize: sourceSize)

        let anchor: CGPoint
        switch corner {
        case .topLeft: anchor = CGPoint(x: rect.maxX, y: rect.maxY)
        case .topRight: anchor = CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomLeft: anchor = CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomRight: anchor = CGPoint(x: rect.minX, y: rect.minY)
        }

        let goingLeft = point.x < anchor.x
        let goingUp = point.y < anchor.y
        let maxWidth = goingLeft ? anchor.x : sourceSize.width - anchor.x
        let maxHeight = goingUp ? anchor.y : sourceSize.height - anchor.y

        var width = min(abs(point.x - anchor.x), maxWidth)
        var height = width / aspect
        if height > maxHeight {
            height = maxHeight
            width = height * aspect
        }

        let minWidth = max(minimumFraction * sourceSize.width, 1)
        if width < minWidth {
            width = min(minWidth, maxWidth)
            height = width / aspect
            if height > maxHeight {
                height = maxHeight
                width = height * aspect
            }
        }

        let result = CGRect(
            x: goingLeft ? anchor.x - width : anchor.x,
            y: goingUp ? anchor.y - height : anchor.y,
            width: width,
            height: height
        )
        return cropRect(result, sourceSize: sourceSize)
    }
}

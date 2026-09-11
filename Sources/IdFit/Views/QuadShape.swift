import SwiftUI

/// Outline of a document's four corners, used by both the crop editor and the
/// straightening editor.
struct QuadShape: Shape {
    let points: [CGPoint]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        path.closeSubpath()
        return path
    }
}

extension CropGeometry.Corner {
    /// The same corner of a quad — the two editors name them alike.
    var quadCorner: DocumentQuad.Corner {
        switch self {
        case .topLeft: .topLeft
        case .topRight: .topRight
        case .bottomLeft: .bottomLeft
        case .bottomRight: .bottomRight
        }
    }
}

/// The picture with the framed part taken out of it, as one even-odd path —
/// the dimming both editors lay over everything that will be cropped away.
///
/// Both outlines are given in the canvas's own coordinates, which is why the
/// rect the shape is handed is ignored. One path rather than a masked
/// rectangle: a mask is composed against the layer's laid-out position while
/// the picture is carried into place by an offset, so the two came apart and
/// most of the scan stayed bright.
struct DimmedArea: Shape {
    let area: [CGPoint]
    let hole: [CGPoint]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addLines(area)
        path.closeSubpath()
        path.addLines(hole)
        path.closeSubpath()
        return path
    }

    /// A rectangle's four corners, in the order an outline is written.
    static func corners(of rect: CGRect) -> [CGPoint] {
        [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY),
        ]
    }
}

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

extension View {
    /// Punches a hole into the receiver — used for the dimmed area around the
    /// framed part of a page.
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

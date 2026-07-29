import SwiftUI

/// A magnifier over the corner being placed, with the edges that meet there
/// drawn across it.
///
/// It sits in the opposite corner of the canvas: under the pointer it would
/// hide the very thing being aimed at.
struct LoupeView: View {
    let image: CGImage
    /// Point under the pointer, normalized in the displayed image.
    let focus: CGPoint
    /// The displayed image's size on screen, which sets the working scale.
    let imageSize: CGSize
    /// Corners sharing an edge with the focus, normalized, so the lines shown
    /// are the real ones rather than a guessed cross.
    let guides: [CGPoint]

    var diameter: CGFloat = 150
    var zoom: CGFloat = 4

    var body: some View {
        let radius = diameter / 2
        let magnified = CGSize(width: imageSize.width * zoom, height: imageSize.height * zoom)

        // A definite square to work in: the magnified image is far larger than
        // the loupe, and as an overlay it cannot drag the layout around with
        // it. Pinning it top-left is what makes the offsets below mean what
        // they say.
        Color.black
            .frame(width: diameter, height: diameter)
            .overlay(alignment: .topLeading) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .frame(width: magnified.width, height: magnified.height)
                    .offset(
                        x: radius - focus.x * magnified.width,
                        y: radius - focus.y * magnified.height
                    )
            }
            .overlay {
                // The edges meeting at this corner, continued to the rim.
                ForEach(Array(guides.enumerated()), id: \.offset) { _, guide in
                    Path { path in
                        let center = CGPoint(x: radius, y: radius)
                        let dx = (guide.x - focus.x) * magnified.width
                        let dy = (guide.y - focus.y) * magnified.height
                        let length = max(hypot(dx, dy), 0.0001)
                        let step = CGPoint(x: dx / length * radius, y: dy / length * radius)
                        // Both ways, so the edge reads as a line and not a spur.
                        path.move(to: CGPoint(x: center.x - step.x, y: center.y - step.y))
                        path.addLine(to: CGPoint(x: center.x + step.x, y: center.y + step.y))
                    }
                    .stroke(.white.opacity(0.9), lineWidth: 1)
                }
            }
            .overlay {
                Circle()
                    .strokeBorder(.white, lineWidth: 1)
                    .frame(width: 7, height: 7)
            }
            .clipShape(Circle())
        .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 2))
        .shadow(color: .black.opacity(0.4), radius: 8, y: 3)
        .allowsHitTesting(false)
    }

    /// Where to sit so the pointer never covers it: the opposite corner of
    /// the image, inset a little.
    static func position(awayFrom corner: DocumentQuad.Corner, in frame: CGRect, diameter: CGFloat = 150) -> CGPoint {
        let inset = diameter / 2 + 12
        let left = frame.minX + inset
        let right = frame.maxX - inset
        let top = frame.minY + inset
        let bottom = frame.maxY - inset
        return switch corner {
        case .topLeft: CGPoint(x: right, y: bottom)
        case .topRight: CGPoint(x: left, y: bottom)
        case .bottomRight: CGPoint(x: left, y: top)
        case .bottomLeft: CGPoint(x: right, y: top)
        }
    }
}

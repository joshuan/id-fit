import SwiftUI

/// The straightening editor: four corners dragged onto the document's own
/// edges. Unlike a crop it is free to be a trapezium — that is exactly what a
/// document photographed at an angle looks like.
struct QuadCanvas: View {
    let image: CGImage
    let displayedSize: CGSize
    let quad: DocumentQuad
    let onChange: (DocumentQuad) -> Void

    @State private var gestureStart: DocumentQuad?

    private let handleSize: CGFloat = 14
    private let hitSize: CGFloat = 32

    var body: some View {
        GeometryReader { geometry in
            let frame = fittedImageFrame(in: geometry.size)
            let points = quad.corners.map { viewPoint($0, in: frame) }

            ZStack(alignment: .topLeading) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)

                // Everything outside the document is dimmed, so the corners
                // can be judged against the real edges.
                Color.black.opacity(0.55)
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
                    .reverseMask {
                        QuadShape(points: points.map {
                            CGPoint(x: $0.x - frame.minX, y: $0.y - frame.minY)
                        })
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                    }
                    .allowsHitTesting(false)

                QuadShape(points: points)
                    .stroke(.white, lineWidth: 1.5)
                    .allowsHitTesting(false)

                ForEach(DocumentQuad.Corner.allCases, id: \.self) { corner in
                    let point = viewPoint(quad[corner], in: frame)
                    Circle()
                        .fill(.white)
                        .overlay(Circle().strokeBorder(.black.opacity(0.4), lineWidth: 1))
                        .frame(width: handleSize, height: handleSize)
                        .frame(width: hitSize, height: hitSize)
                        .contentShape(Rectangle())
                        .pointerStyle(.grabIdle)
                        .offset(x: point.x - hitSize / 2, y: point.y - hitSize / 2)
                        .gesture(dragGesture(corner: corner, frame: frame))
                }
            }
        }
    }

    private func dragGesture(corner: DocumentQuad.Corner, frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let start = gestureStart ?? quad
                if gestureStart == nil { gestureStart = quad }

                var edited = start
                let origin = start[corner]
                edited[corner] = CGPoint(
                    x: origin.x + value.translation.width / frame.width,
                    y: origin.y + value.translation.height / frame.height
                )
                onChange(edited.clampedToUnitSquare())
            }
            .onEnded { _ in gestureStart = nil }
    }

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

    private func viewPoint(_ point: CGPoint, in frame: CGRect) -> CGPoint {
        CGPoint(x: frame.minX + point.x * frame.width, y: frame.minY + point.y * frame.height)
    }
}



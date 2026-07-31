import SwiftUI

/// Draws the page with a dimmed area outside the crop and drag handles on the
/// corners. Editing happens in the page's rotated pixel space, which is the
/// same space the exported image lives in.
struct CropCanvas: View {
    let image: CGImage
    let displayedSize: CGSize
    let crop: CropRect?
    let outputRatio: Double?
    let onChange: (CropRect) -> Void
    /// Called with a freehand rectangle when no ratio has been chosen yet.
    let onDraw: (CropRect) -> Void
    /// Called once, when a corner has been pulled out of square with Command
    /// held — the deliberate gesture that starts perspective correction.
    let onDistort: (DocumentQuad) -> Void

    @State private var gestureStart: CropRect?
    @State private var drawnRect: CGRect?
    @State private var isMovingCrop = false
    /// Shown while a corner is being pulled free; committed on release, so
    /// the page does not switch editors mid-drag.
    @State private var distorting: DocumentQuad?
    @State private var isDistorting = false
    /// The corner the magnifier is following — dragged, or merely pointed at.
    @State private var draggedCorner: CropGeometry.Corner?
    @State private var hoveredCorner: CropGeometry.Corner?

    private let handleSize: CGFloat = 14
    private let hitSize: CGFloat = 32

    var body: some View {
        GeometryReader { geometry in
            let frame = fittedImageFrame(in: geometry.size)

            ZStack(alignment: .topLeading) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .frame(width: frame.width, height: frame.height)
                    .shadow(color: .black.opacity(0.5), radius: 16, y: 6)
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
                    let outline = distorting.map { quad in
                        quad.corners.map { viewPoint($0, in: frame) }
                    }

                    Color.black.opacity(0.55)
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                        .reverseMask {
                            if let outline {
                                QuadShape(points: outline.map {
                                    CGPoint(x: $0.x - frame.minX, y: $0.y - frame.minY)
                                })
                                .frame(width: frame.width, height: frame.height)
                                .offset(x: frame.minX, y: frame.minY)
                            } else {
                                Rectangle()
                                    .frame(width: rect.width, height: rect.height)
                                    .offset(x: rect.minX, y: rect.minY)
                            }
                        }
                        .allowsHitTesting(false)

                    if let outline {
                        QuadShape(points: outline)
                            .stroke(.white, lineWidth: 1.5)
                            .allowsHitTesting(false)
                    } else {
                        // A filled, transparent rectangle: a stroked shape only
                        // hit-tests along its outline, which made the crop feel
                        // undraggable.
                        Color.white.opacity(0.001)
                            .frame(width: rect.width, height: rect.height)
                            .overlay(Rectangle().strokeBorder(.white, lineWidth: 1.5))
                            .offset(x: rect.minX, y: rect.minY)
                            .contentShape(Rectangle())
                            .pointerStyle(isMovingCrop ? .grabActive : .grabIdle)
                            .gesture(moveGesture(crop: crop, frame: frame))

                        // Thirds are how a page gets placed by eye, so they
                        // appear for as long as it is being placed.
                        if gestureStart != nil {
                            ThirdsGuides()
                                .stroke(.white.opacity(0.4), lineWidth: 0.5)
                                .frame(width: rect.width, height: rect.height)
                                .offset(x: rect.minX, y: rect.minY)
                                .allowsHitTesting(false)
                        }
                    }

                    ForEach(CropGeometry.Corner.allCases, id: \.self) { corner in
                        let point = distorting.map { viewPoint($0[corner.quadCorner], in: frame) }
                            ?? handlePosition(corner: corner, in: rect)
                        Circle()
                            .fill(.white)
                            .overlay(Circle().strokeBorder(.black.opacity(0.4), lineWidth: 1))
                            .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                            .frame(width: handleSize, height: handleSize)
                            // A generous invisible target around the dot, so
                            // the corner is easy to grab.
                            .frame(width: hitSize, height: hitSize)
                            .contentShape(Rectangle())
                            .pointerStyle(.frameResize(position: resizePosition(for: corner)))
                            .offset(x: point.x - hitSize / 2, y: point.y - hitSize / 2)
                            .onHover { hoveredCorner = $0 ? corner : (hoveredCorner == corner ? nil : hoveredCorner) }
                            .gesture(resizeGesture(corner: corner, crop: crop, frame: frame))
                    }

                    if let corner = draggedCorner ?? hoveredCorner {
                        let shape = distorting ?? DocumentQuad(crop)
                        let spot = shape[corner.quadCorner]
                        LoupeView(
                            image: image,
                            focus: spot,
                            imageSize: frame.size,
                            guides: shape.neighbours(of: corner.quadCorner)
                        )
                        .position(LoupeView.position(awayFrom: corner.quadCorner, in: frame))
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
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let start = gestureStart ?? crop
                if gestureStart == nil {
                    gestureStart = crop
                    isMovingCrop = true
                }
                let delta = CGSize(
                    width: value.translation.width * (displayedSize.width / frame.width),
                    height: value.translation.height * (displayedSize.height / frame.height)
                )
                onChange(CropGeometry.moved(start, byPixels: delta, sourceSize: displayedSize))
            }
            .onEnded { _ in
                gestureStart = nil
                isMovingCrop = false
            }
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
                if gestureStart == nil {
                    gestureStart = crop
                    draggedCorner = corner
                    // Decided once, at the grab: the shape must not change
                    // its mind halfway through a drag.
                    isDistorting = NSEvent.modifierFlags.contains(.command)
                }

                if isDistorting {
                    var quad = distorting ?? DocumentQuad(start)
                    let origin = DocumentQuad(start)[corner.quadCorner]
                    quad[corner.quadCorner] = CGPoint(
                        x: origin.x + value.translation.width / frame.width,
                        y: origin.y + value.translation.height / frame.height
                    )
                    distorting = quad.clampedToUnitSquare()
                    return
                }

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
            .onEnded { _ in
                gestureStart = nil
                draggedCorner = nil
                if let quad = distorting {
                    distorting = nil
                    onDistort(quad)
                }
                isDistorting = false
            }
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

    private func viewPoint(_ point: CGPoint, in frame: CGRect) -> CGPoint {
        CGPoint(x: frame.minX + point.x * frame.width, y: frame.minY + point.y * frame.height)
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

/// The rule-of-thirds lines drawn inside the crop while it is being placed.
private struct ThirdsGuides: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for step in 1...2 {
            let x = rect.minX + rect.width * CGFloat(step) / 3
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
            let y = rect.minY + rect.height * CGFloat(step) / 3
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        return path
    }
}

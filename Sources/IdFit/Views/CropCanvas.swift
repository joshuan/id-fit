import SwiftUI

/// Draws the page with a dimmed area outside the crop and drag handles on its
/// corners and edges. Editing happens in the page's rotated pixel space, which
/// is the same space the exported image lives in.
///
/// Every layer here is placed with `.offset`, which moves what is drawn but
/// leaves the layout frame at the container's origin. `.contentShape` and
/// `.pointerStyle` describe a region in the frame they are attached to, so
/// they have to come *before* the offset carries that region into place —
/// after it, the region stays behind at the origin and the layer answers to
/// the pointer somewhere it is not.
struct CropCanvas: View {
    let image: CGImage
    let displayedSize: CGSize
    let crop: CropRect?
    /// Clockwise degrees the page is turned by. The crop frame stays upright
    /// and still while the image turns beneath it, which is exactly what the
    /// export does with the region the frame ends up over.
    let tilt: Double
    let outputRatio: Double?
    let onChange: (CropRect) -> Void
    /// Called with a freehand rectangle drawn on a page that has no crop yet.
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
    private let edgeHitSize: CGFloat = 24

    var body: some View {
        GeometryReader { geometry in
            let frame = fittedImageFrame(in: geometry.size)

            ZStack(alignment: .topLeading) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .frame(width: frame.width, height: frame.height)
                    // About the crop's own centre, so the crop keeps covering
                    // the same corner of the document as the page turns.
                    .rotationEffect(.degrees(tilt), anchor: tiltAnchor)
                    .shadow(color: .black.opacity(0.5), radius: 16, y: 6)
                    .offset(x: frame.minX, y: frame.minY)

                if crop == nil {
                    // Nothing framed yet: let the user draw this page's crop.
                    Color.white.opacity(0.001)
                        .frame(width: frame.width, height: frame.height)
                        .contentShape(Rectangle())
                        .pointerStyle(.rectSelection)
                        .offset(x: frame.minX, y: frame.minY)
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

                if let crop {
                    let rect = viewRect(for: crop, in: frame)
                    let outline = distorting.map { quad in
                        quad.corners.map { viewPoint($0, in: frame) }
                    }
                    // One even-odd path rather than a masked rectangle: the
                    // dimming and the hole are then stated in the same
                    // coordinates as every other layer here, and a turned
                    // picture is covered as exactly as an upright one.
                    DimmedArea(
                        area: pictureCorners(in: frame),
                        hole: outline ?? cornerPoints(of: rect)
                    )
                    .fill(.black.opacity(0.55), style: FillStyle(eoFill: true))
                    .frame(width: geometry.size.width, height: geometry.size.height)
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
                            .contentShape(Rectangle())
                            .pointerStyle(isMovingCrop ? .grabActive : .grabIdle)
                            .offset(x: rect.minX, y: rect.minY)
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

                        ForEach(CropGeometry.Edge.allCases, id: \.self) { edge in
                            let strip = stripFrame(edge: edge, in: rect)
                            Color.clear
                                .frame(width: strip.width, height: strip.height)
                                .contentShape(Rectangle())
                                .pointerStyle(.frameResize(position: resizePosition(for: edge)))
                                .offset(x: strip.minX, y: strip.minY)
                                .gesture(resizeGesture(edge: edge, crop: crop, frame: frame))
                        }
                    }

                    ForEach(CropGeometry.Corner.allCases, id: \.self) { corner in
                        let point = distorting.map { viewPoint($0[corner.quadCorner], in: frame) }
                            ?? handlePosition(corner: corner, in: rect)
                        let hit = hitSpan(hitSize, in: rect)
                        Circle()
                            .fill(.white)
                            .overlay(Circle().strokeBorder(.black.opacity(0.4), lineWidth: 1))
                            .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                            .frame(width: handleSize, height: handleSize)
                            // A generous invisible target around the dot, so
                            // the corner is easy to grab.
                            .frame(width: hit, height: hit)
                            .contentShape(Rectangle())
                            .pointerStyle(.frameResize(position: resizePosition(for: corner)))
                            .offset(x: point.x - hit / 2, y: point.y - hit / 2)
                            .onHover { hoveredCorner = $0 ? corner : (hoveredCorner == corner ? nil : hoveredCorner) }
                            .gesture(resizeGesture(corner: corner, crop: crop, frame: frame))
                    }

                    if let corner = draggedCorner ?? hoveredCorner {
                        // The magnifier looks at the untilted scan, so it has
                        // to be pointed at where the handle's corner actually
                        // falls on it.
                        let shape = distorting ?? turnedQuad(crop)
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

    /// A drag reports its locations in the space of the layer it is attached
    /// to — and that layer is laid out at the canvas's origin however far the
    /// offset then carries it, so the image's own origin comes off every
    /// location before it is measured against the image.
    private func drawGesture(frame: CGRect) -> some Gesture {
        let bounds = CGRect(origin: .zero, size: frame.size)
        return DragGesture(minimumDistance: 4)
            .onChanged { value in
                drawnRect = rectangle(
                    from: imagePoint(value.startLocation, in: frame),
                    to: imagePoint(value.location, in: frame),
                    clampedTo: bounds
                )
            }
            .onEnded { value in
                let rect = rectangle(
                    from: imagePoint(value.startLocation, in: frame),
                    to: imagePoint(value.location, in: frame),
                    clampedTo: bounds
                )
                drawnRect = nil
                // Ignore stray clicks that would produce a degenerate crop.
                guard rect.width > frame.width * 0.05, rect.height > frame.height * 0.05 else { return }
                onDraw(drawnCrop(rect, in: frame))
            }
    }

    /// The crop a rectangle drawn on the page stands for.
    ///
    /// On a tilted page the drawing was made while the image turned about the
    /// canvas's centre, and the crop that comes out of it will turn the image
    /// about itself instead — so its centre has to be carried back through that
    /// same turn for the new frame to cover what was drawn over.
    private func drawnCrop(_ rect: CGRect, in frame: CGRect) -> CropRect {
        var centre = CGPoint(x: rect.midX, y: rect.midY)
        if tilt != 0 {
            let anchor = CGPoint(x: tiltAnchor.x * frame.width, y: tiltAnchor.y * frame.height)
            centre = turned(centre, about: anchor, by: -tilt)
        }
        return CropRect(
            x: (centre.x - rect.width / 2) / frame.width,
            y: (centre.y - rect.height / 2) / frame.height,
            width: rect.width / frame.width,
            height: rect.height / frame.height
        ).clampedToUnitSquare()
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
                    // The pointer is demonstrably not on a corner, so a
                    // magnifier left over from one has nothing to show.
                    hoveredCorner = nil
                }
                let delta = CGSize(
                    width: value.translation.width * (displayedSize.width / frame.width),
                    height: value.translation.height * (displayedSize.height / frame.height)
                )
                onChange(TiltGeometry.moved(
                    start, byPixels: delta, tilt: tilt, sourceSize: displayedSize
                ))
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
                let start = gestureStart ?? crop
                if gestureStart == nil {
                    gestureStart = crop
                    draggedCorner = corner
                    // Decided once, at the grab: the shape must not change
                    // its mind halfway through a drag.
                    isDistorting = NSEvent.modifierFlags.contains(.command)
                }

                if isDistorting {
                    // Pulling a corner out of square on a tilted page starts
                    // from the corners the tilt already implies, so the shape
                    // does not jump upright the moment it is grabbed.
                    var quad = distorting ?? turnedQuad(start)
                    let origin = turnedQuad(start)[corner.quadCorner]
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
                onChange(TiltGeometry.resized(
                    start,
                    corner: corner,
                    toPixelPoint: point,
                    outputRatio: outputRatio,
                    tilt: tilt,
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

    /// Tracked by translation for the same reason the corners are. Command is
    /// ignored here: perspective is pulled out of a corner, and an edge has no
    /// corner to pull.
    private func resizeGesture(edge: CropGeometry.Edge, crop: CropRect, frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let start = gestureStart ?? crop
                if gestureStart == nil {
                    gestureStart = crop
                    hoveredCorner = nil
                }

                let origin = CropGeometry.edgePoint(edge, of: start, sourceSize: displayedSize)
                let point = CGPoint(
                    x: origin.x + value.translation.width * (displayedSize.width / frame.width),
                    y: origin.y + value.translation.height * (displayedSize.height / frame.height)
                )
                onChange(TiltGeometry.resized(
                    start,
                    edge: edge,
                    toPixelPoint: point,
                    outputRatio: outputRatio,
                    tilt: tilt,
                    sourceSize: displayedSize
                ))
            }
            .onEnded { _ in
                gestureStart = nil
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

    /// The point the image turns about: the crop's own centre, or the middle
    /// of the picture while there is nothing framed yet.
    private var tiltAnchor: UnitPoint {
        guard let crop else { return .center }
        return UnitPoint(x: crop.x + crop.width / 2, y: crop.y + crop.height / 2)
    }

    /// The corners of the crop as they fall on the untilted scan.
    private func turnedQuad(_ crop: CropRect) -> DocumentQuad {
        TiltGeometry.derivedQuad(crop: crop, tilt: tilt, sourceSize: displayedSize)
    }

    private func turned(_ point: CGPoint, about anchor: CGPoint, by degrees: Double) -> CGPoint {
        let radians = degrees * .pi / 180
        let dx = point.x - anchor.x
        let dy = point.y - anchor.y
        return CGPoint(
            x: anchor.x + dx * cos(radians) - dy * sin(radians),
            y: anchor.y + dx * sin(radians) + dy * cos(radians)
        )
    }

    /// The picture's own four corners on the canvas — turned with the page, so
    /// the dimming follows it rather than the upright box it started in.
    private func pictureCorners(in frame: CGRect) -> [CGPoint] {
        let corners = cornerPoints(of: frame)
        guard tilt != 0 else { return corners }
        let anchor = CGPoint(
            x: frame.minX + tiltAnchor.x * frame.width,
            y: frame.minY + tiltAnchor.y * frame.height
        )
        return corners.map { turned($0, about: anchor, by: tilt) }
    }

    private func cornerPoints(of rect: CGRect) -> [CGPoint] {
        [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY),
        ]
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

    /// Turns a location reported by a drag into one measured from the image's
    /// top-left corner.
    private func imagePoint(_ point: CGPoint, in frame: CGRect) -> CGPoint {
        CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
    }

    /// Handles sit on top of the area that moves the crop, so on a small crop
    /// they can leave nothing to grab: four 32 pt corner squares alone swallow
    /// a crop 64 pt across. None of them may claim more than a third of the
    /// crop's shorter side, which always leaves the middle third free to move.
    private func hitSpan(_ full: CGFloat, in rect: CGRect) -> CGFloat {
        min(full, min(rect.width, rect.height) / 3)
    }

    /// An invisible strip along one edge, stopping short of the corner squares
    /// so that the ends of an edge still resize in two directions.
    private func stripFrame(edge: CropGeometry.Edge, in rect: CGRect) -> CGRect {
        let thickness = hitSpan(edgeHitSize, in: rect)
        let inset = hitSpan(hitSize, in: rect) / 2
        return switch edge {
        case .top:
            CGRect(x: rect.minX + inset, y: rect.minY - thickness / 2,
                   width: rect.width - inset * 2, height: thickness)
        case .bottom:
            CGRect(x: rect.minX + inset, y: rect.maxY - thickness / 2,
                   width: rect.width - inset * 2, height: thickness)
        case .left:
            CGRect(x: rect.minX - thickness / 2, y: rect.minY + inset,
                   width: thickness, height: rect.height - inset * 2)
        case .right:
            CGRect(x: rect.maxX - thickness / 2, y: rect.minY + inset,
                   width: thickness, height: rect.height - inset * 2)
        }
    }

    private func resizePosition(for corner: CropGeometry.Corner) -> FrameResizePosition {
        switch corner {
        case .topLeft: .topLeading
        case .topRight: .topTrailing
        case .bottomLeft: .bottomLeading
        case .bottomRight: .bottomTrailing
        }
    }

    private func resizePosition(for edge: CropGeometry.Edge) -> FrameResizePosition {
        switch edge {
        case .top: .top
        case .bottom: .bottom
        case .left: .leading
        case .right: .trailing
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

/// The picture with the framed part taken out of it, as one even-odd path.
/// Both outlines are given in the canvas's own coordinates, which is why the
/// rect the shape is handed is ignored.
private struct DimmedArea: Shape {
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

import CoreGraphics
import Foundation

/// Pure tilt math: a page turned by a fine angle under an upright crop frame.
///
/// The crop stays an upright rectangle — the tilt says how far the *source*
/// under it is turned. So a tilted crop selects a turned rectangle of the scan,
/// which is what `derivedQuad` produces and what the export straightens back.
/// Everything here works in source pixels: rotation does not commute with
/// normalized coordinates unless the source happens to be square.
enum TiltGeometry {
    /// The finest adjustment offered. A scan is off true by a fraction of a
    /// degree, so degrees alone would be too coarse to correct it.
    static let step: Double = 0.2
    /// Beyond a quarter turn the quarter-turn buttons are the right tool, and
    /// the crop that survives the fit becomes vanishingly small.
    static let limit: Double = 45

    /// The stored form of an angle: inside the limit and on the step grid.
    static func quantized(_ degrees: Double) -> Double {
        let clamped = min(max(degrees, -limit), limit)
        guard clamped.isFinite else { return 0 }
        return (clamped / step).rounded() * step
    }

    // MARK: - The turned rectangle

    /// The region of the source an upright crop covers once the page is tilted.
    ///
    /// In the editor the image turns clockwise by `tilt` beneath a crop frame
    /// that stays put, so what the frame covers is the frame turned by `-tilt`
    /// about its own centre. Corners keep their names, which is what lets
    /// `PerspectiveCorrector` map the quad back upright.
    static func derivedQuad(crop: CropRect, tilt: Double, sourceSize: CGSize) -> DocumentQuad {
        guard tilt != 0, sourceSize.width > 0, sourceSize.height > 0 else { return DocumentQuad(crop) }
        let rect = CropGeometry.pixelRect(crop, sourceSize: sourceSize)
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let radians = tilt * .pi / 180
        let cosine = cos(radians)
        let sine = sin(radians)

        // Turning by -tilt in a y-down space, then back to fractions.
        func turn(_ point: CGPoint) -> CGPoint {
            let dx = point.x - centre.x
            let dy = point.y - centre.y
            return CGPoint(
                x: (centre.x + dx * cosine + dy * sine) / sourceSize.width,
                y: (centre.y - dx * sine + dy * cosine) / sourceSize.height
            )
        }

        return DocumentQuad(
            topLeft: turn(CGPoint(x: rect.minX, y: rect.minY)),
            topRight: turn(CGPoint(x: rect.maxX, y: rect.minY)),
            bottomRight: turn(CGPoint(x: rect.maxX, y: rect.maxY)),
            bottomLeft: turn(CGPoint(x: rect.minX, y: rect.maxY))
        )
    }

    // MARK: - Reading a tilt back off four corners

    /// How a document lies, as its own corners describe it.
    struct Lean: Equatable, Sendable {
        /// Degrees the document leans clockwise. `Page.tilt` turns a page the
        /// other way, so the tilt that counters this lean is it negated.
        var angle: Double
        /// How far the four edges disagree about that angle. A rectangle
        /// merely lying askew keeps them together; a document photographed
        /// from an angle pulls them apart, and no single turn can put that
        /// right.
        var spread: Double
    }

    /// Measures the lean of a quad from all four of its edges.
    ///
    /// In pixels, not fractions: a quad normalized against a source that is
    /// not square is a sheared one, and the angles it appears to have are not
    /// the angles on the scan.
    static func lean(of quad: DocumentQuad, sourceSize: CGSize) -> Lean? {
        guard sourceSize.width > 0, sourceSize.height > 0 else { return nil }
        func pixels(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x * sourceSize.width, y: point.y * sourceSize.height)
        }
        let topLeft = pixels(quad.topLeft)
        let topRight = pixels(quad.topRight)
        let bottomRight = pixels(quad.bottomRight)
        let bottomLeft = pixels(quad.bottomLeft)

        func direction(_ from: CGPoint, _ to: CGPoint) -> Double? {
            let dx = to.x - from.x
            let dy = to.y - from.y
            guard hypot(dx, dy) > 1e-9 else { return nil }
            return atan2(dy, dx) * 180 / .pi
        }

        // All four edges answer the same question once the sides are read for
        // what they are — the top and bottom edges a quarter turn on.
        let readings = [
            direction(topLeft, topRight),
            direction(bottomLeft, bottomRight),
            direction(topLeft, bottomLeft).map { $0 - 90 },
            direction(topRight, bottomRight).map { $0 - 90 },
        ].compactMap { $0 }
        guard readings.count == 4 else { return nil }

        let angle = readings.reduce(0, +) / 4
        return Lean(angle: angle, spread: readings.map { abs($0 - angle) }.max() ?? 0)
    }

    /// The upright rectangle a leaning document occupies: its corners turned
    /// back about their own centre, boxed. For a rectangle that is only lying
    /// askew this is the document itself, which is what makes it a tighter
    /// crop than the box around the corners as they lie.
    static func uprightBox(of quad: DocumentQuad, lean degrees: Double, sourceSize: CGSize) -> CropRect {
        guard degrees != 0, sourceSize.width > 0, sourceSize.height > 0 else { return quad.boundingCrop }
        let corners = quad.corners.map {
            CGPoint(x: $0.x * sourceSize.width, y: $0.y * sourceSize.height)
        }
        let centre = CGPoint(
            x: corners.map(\.x).reduce(0, +) / Double(corners.count),
            y: corners.map(\.y).reduce(0, +) / Double(corners.count)
        )
        let radians = degrees * .pi / 180
        let cosine = cos(radians)
        let sine = sin(radians)

        // The same turn `derivedQuad` makes, which is what keeps the pair
        // consistent: the quad this box derives at `-degrees` is the one it
        // was measured from.
        let turned = corners.map { point in
            let dx = point.x - centre.x
            let dy = point.y - centre.y
            return CGPoint(x: centre.x + dx * cosine + dy * sine, y: centre.y - dx * sine + dy * cosine)
        }
        let xs = turned.map(\.x)
        let ys = turned.map(\.y)
        let minX = xs.min() ?? 0
        let minY = ys.min() ?? 0
        return CropGeometry.cropRect(
            CGRect(x: minX, y: minY, width: (xs.max() ?? 0) - minX, height: (ys.max() ?? 0) - minY),
            sourceSize: sourceSize
        )
    }

    // MARK: - Keeping the turned rectangle inside the scan

    /// Brings a crop back within reach of its tilt: the turned rectangle it
    /// covers has to lie inside the source, and needs more room than the crop
    /// itself does.
    ///
    /// Sliding is preferred to shrinking — a crop pushed against an edge should
    /// step back inside rather than lose the framing the user chose — and the
    /// crop only shrinks, about its own centre and keeping its shape, when no
    /// position would do.
    static func fitted(_ crop: CropRect, tilt: Double, sourceSize: CGSize) -> CropRect {
        guard tilt != 0, sourceSize.width > 0, sourceSize.height > 0 else {
            return crop.clampedToUnitSquare()
        }
        let rect = fittedPixels(
            CropGeometry.pixelRect(crop, sourceSize: sourceSize), tilt: tilt, sourceSize: sourceSize
        )
        return CropGeometry.cropRect(rect, sourceSize: sourceSize)
    }

    /// Moves the crop, stopping where the turned rectangle meets the source's
    /// edge rather than where the crop itself would.
    static func moved(
        _ crop: CropRect,
        byPixels delta: CGSize,
        tilt: Double,
        sourceSize: CGSize
    ) -> CropRect {
        guard tilt != 0 else {
            return CropGeometry.moved(crop, byPixels: delta, sourceSize: sourceSize)
        }
        var rect = CropGeometry.pixelRect(crop, sourceSize: sourceSize)
        rect.origin.x += delta.width
        rect.origin.y += delta.height
        return CropGeometry.cropRect(
            fittedPixels(rect, tilt: tilt, sourceSize: sourceSize), sourceSize: sourceSize
        )
    }

    /// Corner resize, with the turned rectangle deciding where growth stops.
    static func resized(
        _ crop: CropRect,
        corner: CropGeometry.Corner,
        toPixelPoint point: CGPoint,
        outputRatio: Double?,
        tilt: Double,
        sourceSize: CGSize,
        rotation: Int = 0
    ) -> CropRect {
        fitted(
            CropGeometry.resized(
                crop, corner: corner, toPixelPoint: point,
                outputRatio: outputRatio, sourceSize: sourceSize, rotation: rotation
            ),
            tilt: tilt,
            sourceSize: sourceSize
        )
    }

    /// Edge resize, with the turned rectangle deciding where growth stops.
    static func resized(
        _ crop: CropRect,
        edge: CropGeometry.Edge,
        toPixelPoint point: CGPoint,
        outputRatio: Double?,
        tilt: Double,
        sourceSize: CGSize,
        rotation: Int = 0
    ) -> CropRect {
        fitted(
            CropGeometry.resized(
                crop, edge: edge, toPixelPoint: point,
                outputRatio: outputRatio, sourceSize: sourceSize, rotation: rotation
            ),
            tilt: tilt,
            sourceSize: sourceSize
        )
    }

    /// The one place the clamping is written. A w×h crop turned by θ needs a
    /// box of `w·cos|θ| + h·sin|θ|` by `w·sin|θ| + h·cos|θ|`, centred on the
    /// crop — so fitting is that box shrunk to size and slid inside.
    private static func fittedPixels(_ rect: CGRect, tilt: Double, sourceSize: CGSize) -> CGRect {
        let radians = abs(tilt) * .pi / 180
        let cosine = cos(radians)
        let sine = sin(radians)

        var width = rect.width
        var height = rect.height
        let boxWidth = width * cosine + height * sine
        let boxHeight = width * sine + height * cosine
        guard boxWidth > 0, boxHeight > 0 else { return rect }

        let fit = min(1, min(sourceSize.width / boxWidth, sourceSize.height / boxHeight))
        width *= fit
        height *= fit

        let marginX = (width * cosine + height * sine) / 2
        let marginY = (width * sine + height * cosine) / 2
        let centre = CGPoint(
            x: min(max(rect.midX, marginX), sourceSize.width - marginX),
            y: min(max(rect.midY, marginY), sourceSize.height - marginY)
        )
        return CGRect(
            x: centre.x - width / 2,
            y: centre.y - height / 2,
            width: width,
            height: height
        )
    }

    // MARK: - The slider

    /// How hard the slider's middle is stretched. Scans are off by a degree or
    /// two, so most of the travel is spent there; the ends still reach ±45.
    private static let sliderCurve: Double = 2.5

    /// The angle a slider position stands for, on the step grid.
    static func angle(atSliderPosition position: Double) -> Double {
        let clamped = min(max(position, -1), 1)
        return quantized(limit * (clamped < 0 ? -1 : 1) * pow(abs(clamped), sliderCurve))
    }

    /// Where the slider's knob sits for a given angle — the inverse of
    /// `angle(atSliderPosition:)`, so a knob dragged and released stays put.
    static func sliderPosition(forAngle degrees: Double) -> Double {
        let clamped = min(max(degrees, -limit), limit)
        return (clamped < 0 ? -1 : 1) * pow(abs(clamped) / limit, 1 / sliderCurve)
    }
}

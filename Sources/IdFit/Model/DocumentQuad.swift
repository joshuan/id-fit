import CoreGraphics
import Foundation

/// The four corners of a document as it lies in a photograph.
///
/// Points are normalized against the unrotated source and measured from its
/// top-left corner, like `CropRect`. Unlike a crop, the shape need not be a
/// rectangle — that is the whole point: a document shot at an angle is a
/// trapezium on the sensor, and straightening it means mapping these corners
/// back onto a true rectangle.
struct DocumentQuad: Codable, Equatable, Hashable, Sendable {
    var topLeft: CGPoint
    var topRight: CGPoint
    var bottomRight: CGPoint
    var bottomLeft: CGPoint

    var corners: [CGPoint] { [topLeft, topRight, bottomRight, bottomLeft] }

    init(topLeft: CGPoint, topRight: CGPoint, bottomRight: CGPoint, bottomLeft: CGPoint) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomRight = bottomRight
        self.bottomLeft = bottomLeft
    }

    /// The upright rectangle a straight-on shot would have produced.
    init(_ crop: CropRect) {
        self.init(
            topLeft: CGPoint(x: crop.x, y: crop.y),
            topRight: CGPoint(x: crop.x + crop.width, y: crop.y),
            bottomRight: CGPoint(x: crop.x + crop.width, y: crop.y + crop.height),
            bottomLeft: CGPoint(x: crop.x, y: crop.y + crop.height)
        )
    }

    enum Corner: Int, CaseIterable, Hashable {
        case topLeft, topRight, bottomRight, bottomLeft
    }

    subscript(corner: Corner) -> CGPoint {
        get {
            switch corner {
            case .topLeft: topLeft
            case .topRight: topRight
            case .bottomRight: bottomRight
            case .bottomLeft: bottomLeft
            }
        }
        set {
            switch corner {
            case .topLeft: topLeft = newValue
            case .topRight: topRight = newValue
            case .bottomRight: bottomRight = newValue
            case .bottomLeft: bottomLeft = newValue
            }
        }
    }

    func clampedToUnitSquare() -> DocumentQuad {
        func clamp(_ point: CGPoint) -> CGPoint {
            CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
        }
        return DocumentQuad(
            topLeft: clamp(topLeft),
            topRight: clamp(topRight),
            bottomRight: clamp(bottomRight),
            bottomLeft: clamp(bottomLeft)
        )
    }

    /// The upright box enclosing the quad — what the crop falls back to when
    /// straightening is off.
    var boundingCrop: CropRect {
        let xs = corners.map(\.x)
        let ys = corners.map(\.y)
        let minX = xs.min() ?? 0
        let minY = ys.min() ?? 0
        return CropRect(
            x: minX,
            y: minY,
            width: (xs.max() ?? 1) - minX,
            height: (ys.max() ?? 1) - minY
        ).clampedToUnitSquare()
    }

    /// How far from a true rectangle this shape is, as a fraction of the
    /// source. Used to leave already-straight scans alone.
    var skew: Double {
        let box = boundingCrop
        let square = DocumentQuad(box)
        return zip(corners, square.corners)
            .map { hypot($0.x - $1.x, $0.y - $1.y) }
            .max() ?? 0
    }

    /// Rough pixel size of the straightened result, taken from the longest
    /// opposing edges so nothing is downsampled.
    func rectifiedSize(sourceSize: CGSize) -> CGSize {
        func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
            hypot((a.x - b.x) * sourceSize.width, (a.y - b.y) * sourceSize.height)
        }
        return CGSize(
            width: max(distance(topLeft, topRight), distance(bottomLeft, bottomRight)),
            height: max(distance(topLeft, bottomLeft), distance(topRight, bottomRight))
        )
    }
}

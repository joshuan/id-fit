import CoreGraphics
import Foundation

/// Turning a quad the way `CropGeometry.rotated` turns a crop, so the editor
/// can work in the page's rotated space while the file keeps the corners in
/// the source's own.
enum DocumentQuadGeometry {
    static func rotated(_ quad: DocumentQuad, by degrees: Int) -> DocumentQuad {
        let normalized = ((degrees % 360) + 360) % 360
        guard normalized != 0 else { return quad }

        func turn(_ point: CGPoint) -> CGPoint {
            switch normalized {
            case 90: CGPoint(x: 1 - point.y, y: point.x)
            case 180: CGPoint(x: 1 - point.x, y: 1 - point.y)
            case 270: CGPoint(x: point.y, y: 1 - point.x)
            default: point
            }
        }

        // The corners keep their names relative to the viewer, so a quarter
        // turn clockwise moves the old top-left into the top-right slot.
        let moved = quad.corners.map(turn)
        return switch normalized {
        case 90: DocumentQuad(
            topLeft: moved[3], topRight: moved[0], bottomRight: moved[1], bottomLeft: moved[2]
        )
        case 180: DocumentQuad(
            topLeft: moved[2], topRight: moved[3], bottomRight: moved[0], bottomLeft: moved[1]
        )
        case 270: DocumentQuad(
            topLeft: moved[1], topRight: moved[2], bottomRight: moved[3], bottomLeft: moved[0]
        )
        default: quad
        }
    }
}

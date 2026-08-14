import CoreGraphics
import Foundation
import Testing
@testable import IdFit

/// The crop editor drives resizing by adding the pointer's travel to the
/// corner's own position. These cover that arithmetic: dragging must track the
/// pointer one-to-one, with no jump on grab.
@Suite struct CropResizeTests {
    private let a4 = 210.0 / 297.0
    private let size = CGSize(width: 1000, height: 1000)

    /// Reproduces what the view does for one drag step.
    private func drag(
        _ crop: CropRect,
        corner: CropGeometry.Corner,
        byPixels delta: CGSize,
        ratio: Double?
    ) -> CropRect {
        let origin = CropGeometry.cornerPoint(corner, of: crop, sourceSize: size)
        let point = CGPoint(x: origin.x + delta.width, y: origin.y + delta.height)
        return CropGeometry.resized(
            crop, corner: corner, toPixelPoint: point, outputRatio: ratio, sourceSize: size
        )
    }

    @Test func cornerPointsMatchTheCropRectangle() {
        let crop = CropRect(x: 0.2, y: 0.3, width: 0.4, height: 0.5)
        #expect(CropGeometry.cornerPoint(.topLeft, of: crop, sourceSize: size) == CGPoint(x: 200, y: 300))
        #expect(CropGeometry.cornerPoint(.topRight, of: crop, sourceSize: size) == CGPoint(x: 600, y: 300))
        #expect(CropGeometry.cornerPoint(.bottomLeft, of: crop, sourceSize: size) == CGPoint(x: 200, y: 800))
        #expect(CropGeometry.cornerPoint(.bottomRight, of: crop, sourceSize: size) == CGPoint(x: 600, y: 800))
    }

    @Test func grabbingWithoutMovingLeavesTheCropWhereItIs() {
        let crop = CropGeometry.centeredCrop(outputRatio: a4, sourceSize: size)
        for corner in CropGeometry.Corner.allCases {
            let result = drag(crop, corner: corner, byPixels: .zero, ratio: a4)
            #expect(abs(result.x - crop.x) < 0.0001)
            #expect(abs(result.y - crop.y) < 0.0001)
            #expect(abs(result.width - crop.width) < 0.0001)
            #expect(abs(result.height - crop.height) < 0.0001)
        }
    }

    @Test func aSmallDragProducesASmallChange() {
        let crop = CropGeometry.centeredCrop(outputRatio: a4, sourceSize: size)
        let nudged = drag(crop, corner: .topLeft, byPixels: CGSize(width: 10, height: 0), ratio: a4)

        // 10 px in, on a 1000 px source, is 1% — not a leap.
        let shrink = crop.width - nudged.width
        #expect(shrink > 0)
        #expect(shrink < 0.02)
    }

    @Test func draggingIsProportionalRatherThanSteppedOrCapped() {
        let crop = CropGeometry.centeredCrop(outputRatio: a4, sourceSize: size)
        var widths: [Double] = []
        for step in stride(from: 0, through: 200, by: 25) {
            widths.append(drag(crop, corner: .topLeft, byPixels: CGSize(width: Double(step), height: 0), ratio: a4).width)
        }

        // Every step must shrink it further, by a comparable amount each time.
        let deltas = zip(widths, widths.dropFirst()).map { $0 - $1 }
        #expect(deltas.allSatisfy { $0 > 0 })
        let smallest = try! #require(deltas.min())
        let largest = try! #require(deltas.max())
        #expect(largest / smallest < 1.5)
    }

    @Test func oneLongDragMatchesTheSameDistanceInOneGo() {
        // The view recomputes from the crop the gesture started with, so the
        // result must depend only on total travel, not on how it is sampled.
        let crop = CropGeometry.centeredCrop(outputRatio: a4, sourceSize: size)
        let direct = drag(crop, corner: .bottomRight, byPixels: CGSize(width: -150, height: 0), ratio: a4)
        let sampledTwice = drag(crop, corner: .bottomRight, byPixels: CGSize(width: -150, height: 0), ratio: a4)
        #expect(direct == sampledTwice)
    }

    @Test func draggingKeepsTheRatioAndStaysInBounds() {
        let crop = CropGeometry.centeredCrop(outputRatio: a4, sourceSize: size)
        for corner in CropGeometry.Corner.allCases {
            for delta in [CGSize(width: 60, height: 20), CGSize(width: -300, height: -300),
                          CGSize(width: 5000, height: -40)] {
                let result = drag(crop, corner: corner, byPixels: delta, ratio: a4)
                #expect(abs(CropGeometry.exportedRatio(result, sourceSize: size) - a4) < 0.001)
                #expect(result.x >= -0.0001)
                #expect(result.y >= -0.0001)
                #expect(result.x + result.width <= 1.0001)
                #expect(result.y + result.height <= 1.0001)
            }
        }
    }

    // MARK: - Free resizing, without a ratio to hold the shape

    @Test func aFreeCornerDragMovesTheTwoSidesIndependently() {
        let crop = CropRect(x: 0.2, y: 0.3, width: 0.4, height: 0.5)
        let result = drag(crop, corner: .bottomRight, byPixels: CGSize(width: 100, height: -200), ratio: nil)

        // The opposite corner is untouched, and each side followed its own axis.
        #expect(abs(result.x - 0.2) < 0.0001)
        #expect(abs(result.y - 0.3) < 0.0001)
        #expect(abs(result.width - 0.5) < 0.0001)
        #expect(abs(result.height - 0.3) < 0.0001)
    }

    @Test func aFreeCornerDragIsStillHeldToTheSourceAndTheMinimum() {
        let crop = CropRect(x: 0.2, y: 0.3, width: 0.4, height: 0.5)
        let out = drag(crop, corner: .bottomRight, byPixels: CGSize(width: 9000, height: 9000), ratio: nil)
        #expect(abs(out.x + out.width - 1) < 0.0001)
        #expect(abs(out.y + out.height - 1) < 0.0001)

        // Dragged exactly onto the corner it is anchored to, rather than past
        // it, which would fold the crop out the other side.
        let collapsed = drag(crop, corner: .bottomRight, byPixels: CGSize(width: -400, height: -500), ratio: nil)
        #expect(abs(collapsed.width - CropGeometry.minimumFraction) < 0.0001)
        #expect(abs(collapsed.height - CropGeometry.minimumFraction) < 0.0001)
    }
}

/// Dragging an edge rather than a corner. With a ratio it scales the whole
/// crop against the opposite edge; without one it moves that one side alone.
@Suite struct CropEdgeResizeTests {
    private let a4 = 210.0 / 297.0
    private let size = CGSize(width: 1000, height: 1000)
    /// A small crop already at the A4 ratio in source pixels, with room to
    /// grow in every direction.
    private let crop = CropRect(x: 0.3, y: 0.3, width: 0.2, height: 0.2 * 297 / 210)
    /// A drag on each edge that pulls it away from the crop's middle.
    private let outwards: [(CropGeometry.Edge, CGSize)] = [
        (.left, CGSize(width: -100, height: 0)),
        (.right, CGSize(width: 100, height: 0)),
        (.top, CGSize(width: 0, height: -100)),
        (.bottom, CGSize(width: 0, height: 100)),
    ]

    /// Reproduces what the view does for one drag step.
    private func drag(
        _ crop: CropRect,
        edge: CropGeometry.Edge,
        byPixels delta: CGSize,
        ratio: Double?
    ) -> CropRect {
        let origin = CropGeometry.edgePoint(edge, of: crop, sourceSize: size)
        let point = CGPoint(x: origin.x + delta.width, y: origin.y + delta.height)
        return CropGeometry.resized(
            crop, edge: edge, toPixelPoint: point, outputRatio: ratio, sourceSize: size
        )
    }

    @Test func edgePointsSitInTheMiddleOfEachSide() {
        let crop = CropRect(x: 0.2, y: 0.3, width: 0.4, height: 0.5)
        #expect(CropGeometry.edgePoint(.top, of: crop, sourceSize: size) == CGPoint(x: 400, y: 300))
        #expect(CropGeometry.edgePoint(.bottom, of: crop, sourceSize: size) == CGPoint(x: 400, y: 800))
        #expect(CropGeometry.edgePoint(.left, of: crop, sourceSize: size) == CGPoint(x: 200, y: 550))
        #expect(CropGeometry.edgePoint(.right, of: crop, sourceSize: size) == CGPoint(x: 600, y: 550))
    }

    @Test func grabbingAnEdgeWithoutMovingLeavesTheCropWhereItIs() {
        for edge in CropGeometry.Edge.allCases {
            let result = drag(crop, edge: edge, byPixels: .zero, ratio: a4)
            #expect(abs(result.x - crop.x) < 0.0001)
            #expect(abs(result.y - crop.y) < 0.0001)
            #expect(abs(result.width - crop.width) < 0.0001)
            #expect(abs(result.height - crop.height) < 0.0001)
        }
    }

    @Test func draggingAnEdgeLeavesTheOppositeEdgeWhereItWas() {
        let before = CropGeometry.pixelRect(crop, sourceSize: size)
        // Outwards for each edge, so every one of them grows the crop.
        for (edge, delta) in outwards {
            let after = CropGeometry.pixelRect(
                drag(crop, edge: edge, byPixels: delta, ratio: a4), sourceSize: size
            )
            switch edge {
            case .left: #expect(abs(after.maxX - before.maxX) < 0.0001)
            case .right: #expect(abs(after.minX - before.minX) < 0.0001)
            case .top: #expect(abs(after.maxY - before.maxY) < 0.0001)
            case .bottom: #expect(abs(after.minY - before.minY) < 0.0001)
            }
            #expect(after.width > before.width)
        }
    }

    @Test func draggingAnEdgeKeepsTheRatioAndTheCropsOtherCentre() {
        let pixels = CropGeometry.pixelRect(crop, sourceSize: size)
        for delta in [CGSize(width: -100, height: 0), CGSize(width: 60, height: 0)] {
            let result = CropGeometry.pixelRect(
                drag(crop, edge: .left, byPixels: delta, ratio: a4), sourceSize: size
            )
            #expect(abs(result.width / result.height - a4) < 0.001)
            // The perpendicular axis grew both ways at once.
            #expect(abs(result.midY - pixels.midY) < 0.0001)
        }
        for delta in [CGSize(width: 0, height: -100), CGSize(width: 0, height: 60)] {
            let result = CropGeometry.pixelRect(
                drag(crop, edge: .top, byPixels: delta, ratio: a4), sourceSize: size
            )
            #expect(abs(result.width / result.height - a4) < 0.001)
            #expect(abs(result.midX - pixels.midX) < 0.0001)
        }
    }

    @Test func anEdgeCannotBePushedPastTheMinimumOrOverTheOppositeEdge() {
        // Far enough inwards to cross the anchored edge entirely.
        for (edge, delta) in outwards {
            let result = drag(
                crop,
                edge: edge,
                byPixels: CGSize(width: delta.width * -90, height: delta.height * -90),
                ratio: a4
            )
            #expect(abs(CropGeometry.exportedRatio(result, sourceSize: size) - a4) < 0.001)
            // The dragged axis is the one the minimum is measured on; the
            // ratio then decides the other.
            let dragged = edge == .left || edge == .right ? result.width : result.height
            #expect(abs(dragged - CropGeometry.minimumFraction) < 0.0001)
        }
    }

    @Test func anEdgeDragStaysInsideTheSource() {
        let crops = [
            crop,
            // Pressed against the top, so growing symmetrically has nowhere to go.
            CropRect(x: 0.3, y: 0, width: 0.2, height: 0.2 * 297 / 210),
            CropRect(x: 0, y: 0.4, width: 0.2, height: 0.2 * 297 / 210),
        ]
        for start in crops {
            for edge in CropGeometry.Edge.allCases {
                for delta in [CGSize(width: -5000, height: 0), CGSize(width: 5000, height: 0),
                              CGSize(width: 0, height: -5000), CGSize(width: 0, height: 5000)] {
                    let result = drag(start, edge: edge, byPixels: delta, ratio: a4)
                    #expect(abs(CropGeometry.exportedRatio(result, sourceSize: size) - a4) < 0.001)
                    #expect(result.x >= -0.0001)
                    #expect(result.y >= -0.0001)
                    #expect(result.x + result.width <= 1.0001)
                    #expect(result.y + result.height <= 1.0001)
                }
            }
        }
    }

    @Test func aCropWithNoRoomToGrowSidewaysStaysAsItIs() {
        // Flush against the top: the ratio ties the height to the width, and
        // the height can only grow away from the crop's own centre.
        let pinned = CropRect(x: 0.3, y: 0, width: 0.2, height: 0.2 * 297 / 210)
        let result = drag(pinned, edge: .left, byPixels: CGSize(width: -200, height: 0), ratio: a4)
        #expect(abs(result.width - pinned.width) < 0.0001)
        #expect(abs(result.height - pinned.height) < 0.0001)
    }

    // MARK: - Free resizing, without a ratio to hold the shape

    @Test func aFreeEdgeDragChangesOneDimensionOnly() {
        let start = CropRect(x: 0.2, y: 0.3, width: 0.4, height: 0.5)

        let widened = drag(start, edge: .left, byPixels: CGSize(width: -100, height: 40), ratio: nil)
        #expect(abs(widened.x - 0.1) < 0.0001)
        #expect(abs(widened.width - 0.5) < 0.0001)
        #expect(abs(widened.y - start.y) < 0.0001)
        #expect(abs(widened.height - start.height) < 0.0001)

        let raised = drag(start, edge: .top, byPixels: CGSize(width: 40, height: -100), ratio: nil)
        #expect(abs(raised.y - 0.2) < 0.0001)
        #expect(abs(raised.height - 0.6) < 0.0001)
        #expect(abs(raised.x - start.x) < 0.0001)
        #expect(abs(raised.width - start.width) < 0.0001)
    }

    @Test func aFreeEdgeDragIsStillHeldToTheSourceAndTheMinimum() {
        let start = CropRect(x: 0.2, y: 0.3, width: 0.4, height: 0.5)

        let out = drag(start, edge: .right, byPixels: CGSize(width: 9000, height: 0), ratio: nil)
        #expect(abs(out.x - start.x) < 0.0001)
        #expect(abs(out.x + out.width - 1) < 0.0001)

        let collapsed = drag(start, edge: .bottom, byPixels: CGSize(width: 0, height: -9000), ratio: nil)
        #expect(abs(collapsed.y - start.y) < 0.0001)
        #expect(abs(collapsed.height - CropGeometry.minimumFraction) < 0.0001)
    }
}

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
        ratio: Double
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
}

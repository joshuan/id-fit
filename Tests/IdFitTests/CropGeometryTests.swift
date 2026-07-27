import CoreGraphics
import Foundation
import Testing
@testable import IdFit

@Suite struct CropGeometryTests {
    private let a4 = 210.0 / 297.0

    /// The ratio the crop actually produces once applied to the source, which
    /// is what ends up in the PDF.
    private func exportedRatio(_ crop: CropRect, sourceSize: CGSize) -> Double {
        (crop.width * sourceSize.width) / (crop.height * sourceSize.height)
    }

    @Test func centeredCropMatchesRequestedRatio() {
        let size = CGSize(width: 2000, height: 1000)
        let crop = CropGeometry.centeredCrop(outputRatio: a4, sourceSize: size)
        #expect(abs(exportedRatio(crop, sourceSize: size) - a4) < 0.0001)
    }

    @Test func centeredCropIsMaximalAndCentered() {
        // A source wider than A4: the crop should span the full height.
        let size = CGSize(width: 2000, height: 1000)
        let crop = CropGeometry.centeredCrop(outputRatio: a4, sourceSize: size)
        #expect(abs(crop.height - 1.0) < 0.0001)
        #expect(abs(crop.x + crop.width / 2 - 0.5) < 0.0001)
        #expect(abs(crop.y + crop.height / 2 - 0.5) < 0.0001)
    }

    @Test func centeredCropStaysInsideSource() {
        for size in [CGSize(width: 100, height: 4000), CGSize(width: 4000, height: 100), CGSize(width: 800, height: 800)] {
            let crop = CropGeometry.centeredCrop(outputRatio: a4, sourceSize: size)
            #expect(crop.x >= -0.0001)
            #expect(crop.y >= -0.0001)
            #expect(crop.x + crop.width <= 1.0001)
            #expect(crop.y + crop.height <= 1.0001)
        }
    }

    @Test func differentSourceSizesExportTheSameRatio() {
        // The core promise: mixed scan sizes and DPIs must still export
        // uniformly.
        let sizes = [
            CGSize(width: 2480, height: 3508),  // A4 at 300 dpi
            CGSize(width: 1240, height: 1754),  // A4 at 150 dpi
            CGSize(width: 3000, height: 2000),  // landscape photo
            CGSize(width: 1000, height: 1000),  // square
        ]
        for size in sizes {
            let crop = CropGeometry.centeredCrop(outputRatio: a4, sourceSize: size)
            #expect(abs(exportedRatio(crop, sourceSize: size) - a4) < 0.0001)
        }
    }

    @Test func rotationSwapsRequiredSourceAspect() {
        #expect(CropGeometry.sourceAspect(outputRatio: a4, rotation: 0) == a4)
        #expect(CropGeometry.sourceAspect(outputRatio: a4, rotation: 180) == a4)
        #expect(abs(CropGeometry.sourceAspect(outputRatio: a4, rotation: 90) - 1 / a4) < 0.0001)
        #expect(abs(CropGeometry.sourceAspect(outputRatio: a4, rotation: 270) - 1 / a4) < 0.0001)
        #expect(abs(CropGeometry.sourceAspect(outputRatio: a4, rotation: -90) - 1 / a4) < 0.0001)
    }

    @Test func rotatedPageCropExportsRequestedRatio() {
        let size = CGSize(width: 3000, height: 2000)
        let crop = CropGeometry.centeredCrop(outputRatio: a4, sourceSize: size, rotation: 90)
        // In source space the crop is landscape; after the 90° turn it is A4.
        let afterRotation = 1 / exportedRatio(crop, sourceSize: size)
        #expect(abs(afterRotation - a4) < 0.0001)
    }

    @Test func refitChangesShapeButKeepsCenter() {
        let size = CGSize(width: 2000, height: 2000)
        let original = CropRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)
        let refitted = CropGeometry.refit(original, outputRatio: a4, sourceSize: size)

        #expect(abs(exportedRatio(refitted, sourceSize: size) - a4) < 0.0001)
        #expect(abs(refitted.x + refitted.width / 2 - 0.5) < 0.0001)
        #expect(abs(refitted.y + refitted.height / 2 - 0.5) < 0.0001)
    }

    @Test func refitNearEdgeStaysInsideSource() {
        let size = CGSize(width: 2000, height: 1000)
        let corner = CropRect(x: 0.75, y: 0.0, width: 0.25, height: 0.3)
        let refitted = CropGeometry.refit(corner, outputRatio: a4, sourceSize: size)

        #expect(abs(exportedRatio(refitted, sourceSize: size) - a4) < 0.0001)
        #expect(refitted.x >= -0.0001)
        #expect(refitted.y >= -0.0001)
        #expect(refitted.x + refitted.width <= 1.0001)
        #expect(refitted.y + refitted.height <= 1.0001)
    }

    @Test func moveIsClampedToSource() {
        let size = CGSize(width: 1000, height: 1000)
        let crop = CropRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)

        let moved = CropGeometry.moved(crop, byPixels: CGSize(width: 100, height: -100), sourceSize: size)
        #expect(abs(moved.x - 0.5) < 0.0001)
        #expect(abs(moved.y - 0.3) < 0.0001)

        let pushedOut = CropGeometry.moved(crop, byPixels: CGSize(width: 9999, height: 9999), sourceSize: size)
        #expect(abs(pushedOut.x - 0.8) < 0.0001)
        #expect(abs(pushedOut.y - 0.8) < 0.0001)
        #expect(abs(pushedOut.width - 0.2) < 0.0001)
    }

    @Test func resizeKeepsRatioAndAnchorsOppositeCorner() {
        let size = CGSize(width: 1000, height: 1000)
        let crop = CropRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4)

        let resized = CropGeometry.resized(
            crop, corner: .topLeft, toPixelPoint: CGPoint(x: 100, y: 100),
            outputRatio: a4, sourceSize: size
        )

        #expect(abs(exportedRatio(resized, sourceSize: size) - a4) < 0.0001)
        // Bottom-right corner must not move.
        #expect(abs((resized.x + resized.width) - 0.6) < 0.0001)
        #expect(abs((resized.y + resized.height) - 0.6) < 0.0001)
    }

    @Test func resizeIsClampedToSourceBounds() {
        let size = CGSize(width: 1000, height: 1000)
        let crop = CropRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)

        let resized = CropGeometry.resized(
            crop, corner: .bottomRight, toPixelPoint: CGPoint(x: 5000, y: 5000),
            outputRatio: a4, sourceSize: size
        )

        #expect(abs(exportedRatio(resized, sourceSize: size) - a4) < 0.0001)
        #expect(resized.x + resized.width <= 1.0001)
        #expect(resized.y + resized.height <= 1.0001)
    }

    @Test func resizeEnforcesMinimumSize() {
        let size = CGSize(width: 1000, height: 1000)
        let crop = CropRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)

        // Dragging the top-left handle onto the opposite corner.
        let resized = CropGeometry.resized(
            crop, corner: .topLeft, toPixelPoint: CGPoint(x: 800, y: 800),
            outputRatio: a4, sourceSize: size
        )

        #expect(resized.width >= CropGeometry.minimumFraction - 0.0001)
        #expect(resized.height > 0)
        #expect(abs(exportedRatio(resized, sourceSize: size) - a4) < 0.0001)
    }

    @Test func pixelAndNormalizedConversionsRoundTrip() {
        let size = CGSize(width: 1600, height: 900)
        let crop = CropRect(x: 0.125, y: 0.25, width: 0.5, height: 0.5)
        let pixels = CropGeometry.pixelRect(crop, sourceSize: size)
        #expect(pixels == CGRect(x: 200, y: 225, width: 800, height: 450))
        #expect(CropGeometry.cropRect(pixels, sourceSize: size) == crop)
    }
}

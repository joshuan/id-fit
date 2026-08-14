import CoreGraphics
import Foundation
import Testing
@testable import IdFit

/// Tilt is checked against hand-computed angles: 30° has exact sine and
/// cosine, so every expectation below can be worked out on paper.
@Suite struct TiltGeometryTests {
    private let cos30 = 0.8660254037844387
    private let sin30 = 0.5
    private let tolerance = 1e-9

    private func isInside(_ quad: DocumentQuad) -> Bool {
        quad.corners.allSatisfy {
            $0.x >= -1e-6 && $0.x <= 1 + 1e-6 && $0.y >= -1e-6 && $0.y <= 1 + 1e-6
        }
    }

    // MARK: - The turned rectangle

    @Test func anUntiltedCropIsItsOwnQuad() {
        let crop = CropRect(x: 0.2, y: 0.3, width: 0.5, height: 0.4)
        let quad = TiltGeometry.derivedQuad(crop: crop, tilt: 0, sourceSize: CGSize(width: 800, height: 600))
        #expect(quad == DocumentQuad(crop))
    }

    @Test func theQuadIsTheCropTurnedBackwardsAboutItsOwnCentre() {
        let size = CGSize(width: 1000, height: 1000)
        let crop = CropRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let quad = TiltGeometry.derivedQuad(crop: crop, tilt: 30, sourceSize: size)

        // Centre (500, 500), half-extent 250: turning -30° sends the top-left
        // corner to (500 - 250·cos30 - 250·sin30, 500 + 250·sin30 - 250·cos30).
        let near = (500 - 250 * cos30 - 250 * sin30) / 1000
        let far = (500 + 250 * cos30 + 250 * sin30) / 1000
        let low = (500 + 250 * sin30 - 250 * cos30) / 1000
        let high = (500 - 250 * sin30 + 250 * cos30) / 1000

        #expect(abs(quad.topLeft.x - near) < tolerance)
        #expect(abs(quad.topLeft.y - low) < tolerance)
        #expect(abs(quad.topRight.x - high) < tolerance)
        #expect(abs(quad.topRight.y - near) < tolerance)
        #expect(abs(quad.bottomRight.x - far) < tolerance)
        #expect(abs(quad.bottomRight.y - high) < tolerance)
        #expect(abs(quad.bottomLeft.x - low) < tolerance)
        #expect(abs(quad.bottomLeft.y - far) < tolerance)
    }

    /// The corner names have to follow the corners, or the perspective
    /// correction would map the page back at a quarter turn.
    @Test func theQuadKeepsTheCropsCornerNames() {
        let quad = TiltGeometry.derivedQuad(
            crop: CropRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6),
            tilt: 10,
            sourceSize: CGSize(width: 1000, height: 1000)
        )
        // A clockwise page means a counter-clockwise region: the top edge
        // rises to the right, the left edge leans right as it goes down.
        #expect(quad.topLeft.y > quad.topRight.y)
        #expect(quad.topLeft.x < quad.bottomLeft.x)
    }

    @Test func theQuadIsTurnedInPixelsNotInFractions() {
        // A source twice as wide as it is tall: turning the fractions instead
        // of the pixels would put the corner at 0.1585, 0.4085.
        let quad = TiltGeometry.derivedQuad(
            crop: CropRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
            tilt: 30,
            sourceSize: CGSize(width: 1000, height: 500)
        )
        #expect(abs(quad.topLeft.x - (500 - 250 * cos30 - 125 * sin30) / 1000) < tolerance)
        #expect(abs(quad.topLeft.y - (250 + 250 * sin30 - 125 * cos30) / 500) < tolerance)
    }

    // MARK: - Reading a tilt back off four corners

    /// A rectangle of the source lying over by `degrees` clockwise — what a
    /// scan pushed askew on the glass leaves behind. Written out the long way,
    /// with the turn spelled in the other direction from `derivedQuad`, so the
    /// two cannot agree by sharing a mistake.
    private func askew(_ rect: CGRect, by degrees: Double, sourceSize: CGSize) -> DocumentQuad {
        let radians = degrees * .pi / 180
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        func turn(_ point: CGPoint) -> CGPoint {
            let dx = point.x - centre.x
            let dy = point.y - centre.y
            return CGPoint(
                x: (centre.x + dx * cos(radians) - dy * sin(radians)) / sourceSize.width,
                y: (centre.y + dx * sin(radians) + dy * cos(radians)) / sourceSize.height
            )
        }
        return DocumentQuad(
            topLeft: turn(CGPoint(x: rect.minX, y: rect.minY)),
            topRight: turn(CGPoint(x: rect.maxX, y: rect.minY)),
            bottomRight: turn(CGPoint(x: rect.maxX, y: rect.maxY)),
            bottomLeft: turn(CGPoint(x: rect.minX, y: rect.maxY))
        )
    }

    @Test func aRectangleLyingAskewIsMeasuredAtTheAngleItLiesAt() throws {
        let size = CGSize(width: 1000, height: 1000)
        // A 400×600 document on the centre of a square scan, over by 30°: the
        // corner offsets (±200, ±300) turned clockwise.
        let quad = DocumentQuad(
            topLeft: CGPoint(x: (500 - 200 * cos30 + 300 * sin30) / 1000,
                             y: (500 - 200 * sin30 - 300 * cos30) / 1000),
            topRight: CGPoint(x: (500 + 200 * cos30 + 300 * sin30) / 1000,
                              y: (500 + 200 * sin30 - 300 * cos30) / 1000),
            bottomRight: CGPoint(x: (500 + 200 * cos30 - 300 * sin30) / 1000,
                                 y: (500 + 200 * sin30 + 300 * cos30) / 1000),
            bottomLeft: CGPoint(x: (500 - 200 * cos30 - 300 * sin30) / 1000,
                                y: (500 - 200 * sin30 + 300 * cos30) / 1000)
        )
        let made = askew(CGRect(x: 300, y: 200, width: 400, height: 600), by: 30, sourceSize: size)
        for (hand, built) in zip(quad.corners, made.corners) {
            #expect(abs(hand.x - built.x) < 1e-12)
            #expect(abs(hand.y - built.y) < 1e-12)
        }

        let lean = try #require(TiltGeometry.lean(of: quad, sourceSize: size))
        #expect(abs(lean.angle - 30) < 1e-9)
        // All four edges say the same thing: this is a rectangle, only turned.
        #expect(lean.spread < 1e-9)
    }

    @Test func theAngleIsMeasuredInPixelsNotInFractions() throws {
        let size = CGSize(width: 2000, height: 1000)
        let quad = askew(CGRect(x: 600, y: 200, width: 800, height: 600), by: 30, sourceSize: size)
        let lean = try #require(TiltGeometry.lean(of: quad, sourceSize: size))
        #expect(abs(lean.angle - 30) < 1e-9)
        #expect(lean.spread < 1e-9)

        // The same fractions read as if the source were square are a sheared
        // shape, whose edges no longer agree with each other: its top edge
        // comes out at 49° and its left edge at 16°, and a page that is
        // plainly only lying askew would be refused a tilt altogether.
        let square = CGSize(width: 1000, height: 1000)
        let sheared = try #require(TiltGeometry.lean(of: quad, sourceSize: square))
        #expect(sheared.spread > DocumentEdgeDetector.maximumEdgeSpread)
        #expect(DocumentEdgeDetector.tiltProposal(for: quad, sourceSize: square) == nil)
    }

    /// The sign is the one thing this cannot get wrong: a tilt measured back
    /// as itself rather than as its opposite is what makes detection able to
    /// propose one.
    @Test func aDerivedQuadMeasuresBackAsTheTiltItCameFrom() throws {
        let size = CGSize(width: 1600, height: 900)
        let crop = CropRect(x: 0.2, y: 0.15, width: 0.5, height: 0.6)
        for tilt in [-30.0, -12.4, -0.6, 0.2, 7.4, 30.0] {
            let quad = TiltGeometry.derivedQuad(crop: crop, tilt: tilt, sourceSize: size)
            let lean = try #require(TiltGeometry.lean(of: quad, sourceSize: size))
            // A page turned clockwise covers a region leaning the other way,
            // so the turn that counters the lean is the tilt it came from.
            #expect(abs(-lean.angle - tilt) < 1e-9, "\(tilt) came back as \(-lean.angle)")
            #expect(lean.spread < 1e-9)

            // And taking the lean back out returns the crop itself.
            let box = TiltGeometry.uprightBox(of: quad, lean: -tilt, sourceSize: size)
            #expect(abs(box.x - crop.x) < 1e-9)
            #expect(abs(box.y - crop.y) < 1e-9)
            #expect(abs(box.width - crop.width) < 1e-9)
            #expect(abs(box.height - crop.height) < 1e-9)
        }
    }

    @Test func theBoxAroundAnUprightedDocumentIsTheDocumentItself() {
        let size = CGSize(width: 1000, height: 1000)
        let quad = askew(CGRect(x: 300, y: 200, width: 400, height: 600), by: 30, sourceSize: size)
        let box = TiltGeometry.uprightBox(of: quad, lean: 30, sourceSize: size)

        #expect(abs(box.x - 0.3) < 1e-9)
        #expect(abs(box.y - 0.2) < 1e-9)
        #expect(abs(box.width - 0.4) < 1e-9)
        #expect(abs(box.height - 0.6) < 1e-9)
        // Which is a good deal tighter than the box around the corners as
        // they lie — the slivers beside a turned sheet are what it leaves out.
        #expect(quad.boundingCrop.width > box.width + 0.2)
        #expect(quad.boundingCrop.height > box.height + 0.1)
    }

    // MARK: - What detection makes of it

    @Test func aRectangleLyingAskewIsOfferedTheTurnThatUprightsIt() throws {
        let size = CGSize(width: 1200, height: 1600)
        let quad = askew(CGRect(x: 240, y: 240, width: 720, height: 1120), by: 3, sourceSize: size)
        let proposal = try #require(DocumentEdgeDetector.tiltProposal(for: quad, sourceSize: size))

        #expect(abs(proposal.tilt - -3) < 1e-9)
        // And the crop is the document's own rectangle, where it sits once the
        // lean is out of it.
        #expect(abs(proposal.crop.x - 0.2) < 1e-9)
        #expect(abs(proposal.crop.y - 0.15) < 1e-9)
        #expect(abs(proposal.crop.width - 0.6) < 1e-9)
        #expect(abs(proposal.crop.height - 0.7) < 1e-9)
    }

    /// Perspective is not a tilt: the four edges disagree about which way the
    /// page lies, and no single turn can put that right.
    @Test func aDocumentSeenFromAnAngleIsOfferedNoTilt() throws {
        let size = CGSize(width: 1000, height: 1200)
        let quad = DocumentQuad(
            topLeft: CGPoint(x: 0.30, y: 0.18),
            topRight: CGPoint(x: 0.74, y: 0.12),
            bottomRight: CGPoint(x: 0.82, y: 0.86),
            bottomLeft: CGPoint(x: 0.22, y: 0.80)
        )
        #expect(
            try #require(TiltGeometry.lean(of: quad, sourceSize: size)).spread
                > DocumentEdgeDetector.maximumEdgeSpread
        )
        #expect(DocumentEdgeDetector.tiltProposal(for: quad, sourceSize: size) == nil)

        // A page lying askew is well inside the threshold, so the two cases
        // are told apart with room to spare.
        let crooked = askew(CGRect(x: 200, y: 200, width: 600, height: 800), by: 4, sourceSize: size)
        #expect(try #require(TiltGeometry.lean(of: crooked, sourceSize: size)).spread < 1e-9)
    }

    @Test func aLeanTooFineToStoreIsLeftAsItIs() {
        let size = CGSize(width: 1000, height: 1200)
        let rect = CGRect(x: 200, y: 200, width: 600, height: 800)
        #expect(DocumentEdgeDetector.tiltProposal(
            for: askew(rect, by: 0.1, sourceSize: size), sourceSize: size
        ) == nil)
        #expect(DocumentEdgeDetector.tiltProposal(
            for: askew(rect, by: 0, sourceSize: size), sourceSize: size
        ) == nil)
        // One step is enough to be worth turning.
        #expect(DocumentEdgeDetector.tiltProposal(
            for: askew(rect, by: 0.25, sourceSize: size), sourceSize: size
        )?.tilt == -0.2)
    }

    /// A quarter turn is the quarter-turn buttons' job, and a lean that far
    /// over is a misdetection rather than a scan sitting crooked.
    @Test func aLeanBeyondTheLimitIsClamped() throws {
        let size = CGSize(width: 1000, height: 1000)
        let quad = askew(CGRect(x: 400, y: 400, width: 200, height: 200), by: 60, sourceSize: size)
        #expect(try #require(DocumentEdgeDetector.tiltProposal(for: quad, sourceSize: size)).tilt == -45)
    }

    // MARK: - Fitting

    @Test func fittingLeavesAnUntiltedCropExactlyAsItWas() {
        let crop = CropRect(x: 0.1, y: 0.2, width: 0.5, height: 0.6)
        #expect(TiltGeometry.fitted(crop, tilt: 0, sourceSize: CGSize(width: 1000, height: 800)) == crop)
    }

    @Test func aTiltedCropInACornerSlidesBackInside() {
        let size = CGSize(width: 1000, height: 1000)
        let corner = CropRect(x: 0, y: 0, width: 0.4, height: 0.4)
        let fitted = TiltGeometry.fitted(corner, tilt: 30, sourceSize: size)

        // A 400×400 crop turned by 30° needs a 546.41 px box, so its centre
        // cannot come closer to an edge than half of that.
        let inset = (400 * cos30 + 400 * sin30) / 2 - 200
        #expect(abs(fitted.x - inset / 1000) < tolerance)
        #expect(abs(fitted.y - inset / 1000) < tolerance)
        // Sliding, not shrinking: the framing the user chose is kept.
        #expect(abs(fitted.width - 0.4) < tolerance)
        #expect(abs(fitted.height - 0.4) < tolerance)
        #expect(isInside(TiltGeometry.derivedQuad(crop: fitted, tilt: 30, sourceSize: size)))
    }

    @Test func aTiltedCropShrinksOnlyWhenNoPositionWouldFit() {
        let size = CGSize(width: 1000, height: 1000)
        let whole = CropRect(x: 0, y: 0, width: 1, height: 1)
        let fitted = TiltGeometry.fitted(whole, tilt: 30, sourceSize: size)

        // The whole scan turned by 30° needs 1366.03 px of room, so it gives
        // up 1/1.366 of itself and stays centred.
        let scale = 1 / (cos30 + sin30)
        #expect(abs(fitted.width - scale) < tolerance)
        #expect(abs(fitted.height - scale) < tolerance)
        #expect(abs(fitted.x + fitted.width / 2 - 0.5) < tolerance)
        #expect(abs(fitted.y + fitted.height / 2 - 0.5) < tolerance)
        #expect(isInside(TiltGeometry.derivedQuad(crop: fitted, tilt: 30, sourceSize: size)))
    }

    @Test func shrinkingKeepsTheCropsShape() {
        let size = CGSize(width: 2000, height: 1000)
        let crop = CropRect(x: 0, y: 0, width: 1, height: 1)
        let fitted = TiltGeometry.fitted(crop, tilt: 20, sourceSize: size)
        let before = (crop.width * size.width) / (crop.height * size.height)
        let after = (fitted.width * size.width) / (fitted.height * size.height)
        #expect(abs(before - after) < 1e-9)
    }

    @Test func aFittedCropAlwaysCoversAPieceOfTheScan() {
        let sizes = [
            CGSize(width: 1000, height: 1000),
            CGSize(width: 2480, height: 3508),
            CGSize(width: 3000, height: 800),
        ]
        let crops = [
            CropRect(x: 0, y: 0, width: 1, height: 1),
            CropRect(x: 0, y: 0, width: 0.3, height: 0.9),
            CropRect(x: 0.85, y: 0.85, width: 0.15, height: 0.15),
            CropRect(x: 0.3, y: 0.1, width: 0.6, height: 0.2),
        ]
        for size in sizes {
            for crop in crops {
                for tilt in [-45.0, -12.4, -0.2, 0.2, 5.0, 30.0, 45.0] {
                    let fitted = TiltGeometry.fitted(crop, tilt: tilt, sourceSize: size)
                    let quad = TiltGeometry.derivedQuad(crop: fitted, tilt: tilt, sourceSize: size)
                    #expect(isInside(quad), "tilt \(tilt), crop \(crop), size \(size)")
                    #expect(fitted.width > 0 && fitted.height > 0)
                }
            }
        }
    }

    // MARK: - Moving and resizing

    @Test func movingAnUntiltedCropIsTheOldBehaviourExactly() {
        let size = CGSize(width: 1000, height: 1000)
        let crop = CropRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        for delta in [CGSize(width: 100, height: -100), CGSize(width: 9999, height: 9999)] {
            #expect(
                TiltGeometry.moved(crop, byPixels: delta, tilt: 0, sourceSize: size)
                    == CropGeometry.moved(crop, byPixels: delta, sourceSize: size)
            )
        }
    }

    @Test func movingATiltedCropStopsShortOfTheEdge() {
        let size = CGSize(width: 1000, height: 1000)
        let crop = CropRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4)
        let moved = TiltGeometry.moved(
            crop, byPixels: CGSize(width: 9999, height: 0), tilt: 30, sourceSize: size
        )

        let margin = (400 * cos30 + 400 * sin30) / 2
        #expect(abs(moved.x - (1000 - margin - 200) / 1000) < tolerance)
        #expect(abs(moved.y - 0.3) < tolerance)
        #expect(isInside(TiltGeometry.derivedQuad(crop: moved, tilt: 30, sourceSize: size)))
    }

    @Test func resizingAnUntiltedCropIsTheOldBehaviourExactly() {
        let size = CGSize(width: 1000, height: 1000)
        let crop = CropRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4)
        let point = CGPoint(x: 100, y: 100)
        #expect(
            TiltGeometry.resized(
                crop, corner: .topLeft, toPixelPoint: point,
                outputRatio: 210.0 / 297.0, tilt: 0, sourceSize: size
            ) == CropGeometry.resized(
                crop, corner: .topLeft, toPixelPoint: point,
                outputRatio: 210.0 / 297.0, sourceSize: size
            )
        )
        #expect(
            TiltGeometry.resized(
                crop, edge: .right, toPixelPoint: CGPoint(x: 950, y: 400),
                outputRatio: nil, tilt: 0, sourceSize: size
            ) == CropGeometry.resized(
                crop, edge: .right, toPixelPoint: CGPoint(x: 950, y: 400),
                outputRatio: nil, sourceSize: size
            )
        )
    }

    @Test func growingATiltedCropStopsWhereTheTurnedRectangleWould() {
        let size = CGSize(width: 1000, height: 1000)
        let crop = CropRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        let grown = TiltGeometry.resized(
            crop, corner: .bottomRight, toPixelPoint: CGPoint(x: 5000, y: 5000),
            outputRatio: nil, tilt: 12, sourceSize: size
        )
        #expect(isInside(TiltGeometry.derivedQuad(crop: grown, tilt: 12, sourceSize: size)))
        // Still a real crop: stopping short must not collapse it.
        #expect(grown.width > 0.2)

        let widened = TiltGeometry.resized(
            crop, edge: .right, toPixelPoint: CGPoint(x: 5000, y: 500),
            outputRatio: nil, tilt: 12, sourceSize: size
        )
        #expect(isInside(TiltGeometry.derivedQuad(crop: widened, tilt: 12, sourceSize: size)))
    }

    // MARK: - Angles and the slider

    @Test func anglesAreSnappedToTheStepAndKeptWithinTheLimit() {
        #expect(TiltGeometry.quantized(0.31) == 0.4)
        #expect(abs(TiltGeometry.quantized(0.29) - 0.2) < 1e-12)
        #expect(TiltGeometry.quantized(0.09) == 0)
        #expect(abs(TiltGeometry.quantized(-1.74) - -1.8) < 1e-12)
        #expect(abs(TiltGeometry.quantized(90) - 45) < 1e-12)
        #expect(abs(TiltGeometry.quantized(-90) - -45) < 1e-12)
        #expect(TiltGeometry.quantized(.nan) == 0)
    }

    @Test func theSliderReachesBothEndsAndRestsAtZero() {
        #expect(abs(TiltGeometry.angle(atSliderPosition: 1) - 45) < 1e-12)
        #expect(abs(TiltGeometry.angle(atSliderPosition: -1) - -45) < 1e-12)
        #expect(TiltGeometry.angle(atSliderPosition: 0) == 0)
        #expect(TiltGeometry.sliderPosition(forAngle: 0) == 0)
        #expect(abs(TiltGeometry.sliderPosition(forAngle: 45) - 1) < 1e-12)
        #expect(abs(TiltGeometry.sliderPosition(forAngle: -45) - -1) < 1e-12)
    }

    /// A knob dragged to an angle and let go must not creep.
    @Test func theSliderRoundTripsEveryAngleItCanProduce() {
        for degrees in stride(from: -45.0, through: 45.0, by: 0.2) {
            let angle = TiltGeometry.quantized(degrees)
            let back = TiltGeometry.angle(
                atSliderPosition: TiltGeometry.sliderPosition(forAngle: angle)
            )
            #expect(abs(back - angle) < 1e-9, "\(angle) came back as \(back)")
        }
    }

    /// The middle of the travel is stretched, so a fraction of a degree is
    /// reachable rather than a whole one being the smallest step.
    @Test func theSliderIsFinestNearTheMiddle() {
        let nearZero = TiltGeometry.angle(atSliderPosition: 0.2)
        let nearTheEnd = TiltGeometry.angle(atSliderPosition: 1) - TiltGeometry.angle(atSliderPosition: 0.8)
        #expect(nearZero < 1)
        #expect(nearTheEnd > 10)
        // And there is a band around the middle that means exactly upright.
        #expect(TiltGeometry.angle(atSliderPosition: 0.05) == 0)
        #expect(TiltGeometry.angle(atSliderPosition: 0.15) != 0)
    }
}

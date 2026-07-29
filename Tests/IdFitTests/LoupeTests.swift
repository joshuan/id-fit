import CoreGraphics
import Foundation
import Testing
@testable import IdFit

@Suite struct LoupeTests {
    private let frame = CGRect(x: 100, y: 50, width: 600, height: 400)

    @Test func theMagnifierSitsOppositeTheCornerBeingPlaced() {
        // Otherwise the pointer would cover the very thing being aimed at.
        let topLeft = LoupeView.position(awayFrom: .topLeft, in: frame)
        #expect(topLeft.x > frame.midX)
        #expect(topLeft.y > frame.midY)

        let bottomRight = LoupeView.position(awayFrom: .bottomRight, in: frame)
        #expect(bottomRight.x < frame.midX)
        #expect(bottomRight.y < frame.midY)

        let topRight = LoupeView.position(awayFrom: .topRight, in: frame)
        #expect(topRight.x < frame.midX)
        #expect(topRight.y > frame.midY)

        let bottomLeft = LoupeView.position(awayFrom: .bottomLeft, in: frame)
        #expect(bottomLeft.x > frame.midX)
        #expect(bottomLeft.y < frame.midY)
    }

    @Test func theMagnifierStaysInsideThePage() {
        let diameter: CGFloat = 150
        for corner in DocumentQuad.Corner.allCases {
            let centre = LoupeView.position(awayFrom: corner, in: frame, diameter: diameter)
            #expect(centre.x - diameter / 2 >= frame.minX)
            #expect(centre.y - diameter / 2 >= frame.minY)
            #expect(centre.x + diameter / 2 <= frame.maxX)
            #expect(centre.y + diameter / 2 <= frame.maxY)
        }
    }

    @Test func theLinesShownAreTheEdgesThatActuallyMeetThere() {
        let quad = DocumentQuad(
            topLeft: CGPoint(x: 0.1, y: 0.2),
            topRight: CGPoint(x: 0.8, y: 0.15),
            bottomRight: CGPoint(x: 0.85, y: 0.9),
            bottomLeft: CGPoint(x: 0.15, y: 0.85)
        )

        // Each corner's neighbours are the two it shares an edge with.
        #expect(quad.neighbours(of: .topLeft) == [quad.bottomLeft, quad.topRight])
        #expect(quad.neighbours(of: .topRight) == [quad.topLeft, quad.bottomRight])
        #expect(quad.neighbours(of: .bottomRight) == [quad.topRight, quad.bottomLeft])
        #expect(quad.neighbours(of: .bottomLeft) == [quad.bottomRight, quad.topLeft])

        // Never the corner diagonally across, which shares no edge.
        for corner in DocumentQuad.Corner.allCases {
            #expect(!quad.neighbours(of: corner).contains(quad[corner]))
        }
    }

    @Test func anUprightCropGivesSquareGuides() {
        let crop = CropRect(x: 0.2, y: 0.3, width: 0.5, height: 0.4)
        let quad = DocumentQuad(crop)
        let guides = quad.neighbours(of: .topLeft)

        // One neighbour straight down, the other straight across.
        #expect(guides.contains { abs($0.x - quad.topLeft.x) < 0.0001 })
        #expect(guides.contains { abs($0.y - quad.topLeft.y) < 0.0001 })
    }
}

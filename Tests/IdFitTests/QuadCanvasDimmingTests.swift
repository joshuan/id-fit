import CoreGraphics
import SwiftUI
import Testing
@testable import IdFit

/// The straightening editor dims what will be cropped away just as the crop
/// editor does, and for the same reason it is checked by rendering and
/// sampling: the masked rectangle it used to draw composed against the layer's
/// laid-out position while the picture was carried into place by an offset, so
/// most of the scan stayed bright and only pixels would have said so.
@MainActor
@Suite struct QuadCanvasDimmingTests {
    /// Container 600×300 with a 200×250 picture: the fitted frame is 240×300
    /// at x = 180, so nothing lines up with the canvas's own origin.
    private let container = CGSize(width: 600, height: 300)
    private let picture = CGSize(width: 200, height: 250)

    /// Deliberately not a rectangle — the bottom edge is wider than the top,
    /// which is what a document photographed at an angle looks like.
    private let quad = DocumentQuad(
        topLeft: CGPoint(x: 0.25, y: 0.25),
        topRight: CGPoint(x: 0.75, y: 0.25),
        bottomRight: CGPoint(x: 0.8, y: 0.75),
        bottomLeft: CGPoint(x: 0.2, y: 0.75)
    )

    private func white() -> CGImage {
        let context = CGContext(
            data: nil, width: Int(picture.width), height: Int(picture.height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: picture))
        return context.makeImage()!
    }

    /// Renders the canvas over a green background, so three states are
    /// tellable apart: bright picture, dimmed picture, and no picture at all.
    private func render() throws -> (Int, Int) -> Int {
        let canvas = QuadCanvas(
            image: white(),
            displayedSize: picture,
            quad: quad,
            onChange: { _ in }
        )
        let renderer = ImageRenderer(
            content: canvas.frame(width: container.width, height: container.height)
        )
        renderer.scale = 1
        let image = try #require(renderer.cgImage)

        let width = Int(container.width)
        let height = Int(container.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.setFillColor(CGColor(red: 0, green: 0.6, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return { x, y in
            let offset = (y * width + x) * 4
            return Int(pixels[offset]) + Int(pixels[offset + 1]) + Int(pixels[offset + 2])
        }
    }

    private let bright = 700
    private let dim = 250...550

    @Test func everythingOutsideTheDocumentIsDimmedAcrossTheWholePicture() throws {
        let sample = try render()
        // The picture spans x 180…420; at half height the document spans
        // x 234…366.
        #expect(dim.contains(sample(200, 150)), "left of the document")
        #expect(dim.contains(sample(400, 150)), "right of the document")
        #expect(dim.contains(sample(300, 30)), "above the document")
        #expect(dim.contains(sample(300, 270)), "below the document")
        #expect(sample(300, 150) > bright, "the document itself stays bright")
        // Beyond the picture there is nothing to dim.
        #expect(sample(50, 150) < 250)
    }

    @Test func theDimmingFollowsTheSlantedEdgeRatherThanTheBoxAroundIt() throws {
        let sample = try render()
        // x = 232 sits inside the box the four corners fit in — it starts at
        // x = 228 — but outside the leaning left edge, which at y = 100 has
        // only reached x = 238.
        #expect(dim.contains(sample(232, 100)), "the sliver the lean leaves out")
        #expect(sample(250, 100) > bright, "just inside the same edge")
    }
}

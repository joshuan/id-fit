import CoreGraphics
import SwiftUI
import Testing
@testable import IdFit

/// What the editor dims is checked by rendering the canvas and sampling it —
/// the same reason exports are checked that way. A masked rectangle used to
/// leave part of the picture bright, because a mask is composed against the
/// layer's laid-out position and the picture is carried into place by an
/// offset; nothing but pixels would have caught that.
@MainActor
@Suite struct CropCanvasDimmingTests {
    /// Container 600×300 with a 200×250 picture: the fitted frame is 240×300
    /// at x = 180, so nothing lines up with the canvas's own origin.
    private let container = CGSize(width: 600, height: 300)
    private let picture = CGSize(width: 200, height: 250)
    private let crop = CropRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)

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
    private func render(tilt: Double) throws -> (Int, Int) -> Int {
        let canvas = CropCanvas(
            image: white(),
            displayedSize: picture,
            crop: crop,
            tilt: tilt,
            outputRatio: nil,
            onChange: { _ in }, onDraw: { _ in }, onDistort: { _ in }
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

    @Test func everythingOutsideTheCropIsDimmedAcrossTheWholePicture() throws {
        let sample = try render(tilt: 0)
        // The picture spans x 180…420 and the crop x 240…360.
        #expect(dim.contains(sample(200, 150)), "left of the crop")
        #expect(dim.contains(sample(400, 150)), "right of the crop")
        #expect(dim.contains(sample(300, 30)), "above the crop")
        #expect(dim.contains(sample(300, 270)), "below the crop")
        #expect(sample(300, 150) > bright, "the crop itself stays bright")
        // Beyond the picture there is nothing to dim.
        #expect(sample(50, 150) < 250)
    }

    @Test func theDimmingFollowsATiltedPicture() throws {
        let sample = try render(tilt: 20)
        // Turned 20° about the crop's centre (300, 150), the picture reaches
        // out to x = 160 at y = 200 and pulls away from x = 410 at y = 290.
        #expect(dim.contains(sample(160, 200)), "the sliver the turn brought in")
        #expect(sample(410, 290) < 250, "the corner the turn took away")
        #expect(sample(300, 150) > bright, "the crop itself stays bright")
        #expect(dim.contains(sample(300, 30)), "above the crop")
    }
}

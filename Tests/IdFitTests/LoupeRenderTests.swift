import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import IdFit

/// Renders the magnifier to pixels and looks at them. Its whole job is to
/// show the right part of the page, and a layout slip leaves it showing
/// nothing but its own backing — which asserting on views cannot catch.
@MainActor
@Suite struct LoupeRenderTests {
    /// Left half red, right half blue, with a green band across the top.
    private func testPage(size: CGSize) -> CGImage {
        let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size.width / 2, height: size.height))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height))
        // CoreGraphics draws bottom-up, so this band is the visual top.
        context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: size.height * 0.9, width: size.width, height: size.height * 0.1))
        return context.makeImage()!
    }

    private struct Rendered {
        let pixels: [UInt8]
        let width: Int
        let height: Int

        /// Sampled as a fraction of the rendered square, from the top-left.
        func colour(x: Double, y: Double) -> (r: Int, g: Int, b: Int) {
            let px = min(max(Int(x * Double(width)), 0), width - 1)
            let py = min(max(Int(y * Double(height)), 0), height - 1)
            let offset = (py * width + px) * 4
            return (Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2]))
        }
    }

    private func render(_ loupe: LoupeView) throws -> Rendered {
        let renderer = ImageRenderer(content: loupe)
        renderer.scale = 1
        let image = try #require(renderer.cgImage)

        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return Rendered(pixels: pixels, width: image.width, height: image.height)
    }

    private func isBlack(_ colour: (r: Int, g: Int, b: Int)) -> Bool {
        colour.r < 30 && colour.g < 30 && colour.b < 30
    }

    @Test func theMagnifierShowsThePageAndNotJustItsBacking() throws {
        let size = CGSize(width: 400, height: 400)
        let loupe = LoupeView(
            image: testPage(size: size),
            focus: CGPoint(x: 0.5, y: 0.5),
            imageSize: size,
            guides: [CGPoint(x: 0.5, y: 0.9), CGPoint(x: 0.9, y: 0.5)],
            diameter: 120,
            zoom: 3
        )

        let rendered = try render(loupe)
        // Around the middle, where the page certainly covers the glass.
        for point in [(0.5, 0.42), (0.42, 0.5), (0.58, 0.5), (0.5, 0.58)] {
            #expect(!isBlack(rendered.colour(x: point.0, y: point.1)))
        }
    }

    @Test func theFocusPointLandsInTheMiddleOfTheGlass() throws {
        let size = CGSize(width: 400, height: 400)
        // Aim at the boundary between the halves: red must fall to the left of
        // the centre and blue to the right.
        let loupe = LoupeView(
            image: testPage(size: size),
            focus: CGPoint(x: 0.5, y: 0.5),
            imageSize: size,
            guides: [CGPoint(x: 0.5, y: 0.9)],
            diameter: 120,
            zoom: 3
        )

        let rendered = try render(loupe)
        let left = rendered.colour(x: 0.36, y: 0.5)
        let right = rendered.colour(x: 0.64, y: 0.5)
        #expect(left.r > 150 && left.b < 90)
        #expect(right.b > 150 && right.r < 90)
    }

    @Test func anEdgeUnderTheCornerAppearsAcrossTheMiddle() throws {
        let size = CGSize(width: 400, height: 400)
        // Aim exactly at the lower edge of the green band, 10% down the page:
        // green must sit above the centre and red below it.
        let loupe = LoupeView(
            image: testPage(size: size),
            focus: CGPoint(x: 0.25, y: 0.10),
            imageSize: size,
            guides: [CGPoint(x: 0.25, y: 0.5), CGPoint(x: 0.75, y: 0.10)],
            diameter: 120,
            zoom: 3
        )

        let rendered = try render(loupe)
        // Sampled off to one side, clear of the white guide lines themselves.
        let above = rendered.colour(x: 0.62, y: 0.35)
        let below = rendered.colour(x: 0.62, y: 0.65)
        #expect(above.g > 140 && above.r < 120)
        #expect(below.r > 150 && below.g < 120)
    }

    @Test func zoomingInReallyMagnifies() throws {
        let size = CGSize(width: 400, height: 400)
        func glass(zoom: CGFloat) throws -> Rendered {
            try render(LoupeView(
                image: testPage(size: size),
                // A hair to the left of where red meets blue.
                focus: CGPoint(x: 0.49, y: 0.5),
                imageSize: size,
                guides: [CGPoint(x: 0.49, y: 0.9)],
                diameter: 120,
                zoom: zoom
            ))
        }

        // That boundary is 0.01 of the page away, so it lands further from the
        // centre the deeper the zoom. Sampled a fixed 6pt to the right, it
        // shows blue at 1× — past the boundary — and red at 4×, where the
        // boundary has moved out beyond the sample.
        let gentle = try glass(zoom: 1).colour(x: 0.55, y: 0.5)
        let deep = try glass(zoom: 4).colour(x: 0.55, y: 0.5)
        #expect(gentle.b > 150 && gentle.r < 90)
        #expect(deep.r > 150 && deep.b < 90)
    }
}

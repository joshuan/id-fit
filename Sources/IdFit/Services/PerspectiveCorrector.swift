import CoreGraphics
import CoreImage
import Foundation

/// Maps a document photographed at an angle back onto a true rectangle.
///
/// Uses Core Image's perspective correction, which is part of the system. The
/// result is snapped to the proportions the document is supposed to have: a
/// passport page really is 88 × 125, so once the corners are known, the exact
/// shape is knowledge rather than distortion.
enum PerspectiveCorrector {
    /// Shared because building a CIContext is expensive and it is thread-safe.
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    /// A quad this close to a rectangle is left alone — straightening a scan
    /// that is already square only risks blurring it through resampling.
    static let negligibleSkew: Double = 0.002

    static func straighten(
        _ image: CGImage,
        quad: DocumentQuad,
        targetAspect: Double
    ) -> CGImage? {
        let size = CGSize(width: image.width, height: image.height)
        let clamped = quad.clampedToUnitSquare()

        let input = CIImage(cgImage: image)
        let filter = CIFilter(name: "CIPerspectiveCorrection")
        filter?.setValue(input, forKey: kCIInputImageKey)
        // Core Image counts from the bottom-left corner, the stored quad from
        // the top-left one.
        func point(_ corner: CGPoint) -> CIVector {
            CIVector(
                x: corner.x * size.width,
                y: (1 - corner.y) * size.height
            )
        }
        filter?.setValue(point(clamped.topLeft), forKey: "inputTopLeft")
        filter?.setValue(point(clamped.topRight), forKey: "inputTopRight")
        filter?.setValue(point(clamped.bottomRight), forKey: "inputBottomRight")
        filter?.setValue(point(clamped.bottomLeft), forKey: "inputBottomLeft")

        guard let output = filter?.outputImage, !output.extent.isInfinite,
              output.extent.width >= 1, output.extent.height >= 1,
              let corrected = context.createCGImage(output, from: output.extent)
        else { return nil }

        return resized(corrected, toAspect: targetAspect, reference: clamped.rectifiedSize(sourceSize: size))
    }

    /// Stretches the rectified image onto the exact proportions the document
    /// has, keeping enough pixels that nothing is thrown away.
    private static func resized(_ image: CGImage, toAspect aspect: Double, reference: CGSize) -> CGImage? {
        guard aspect > 0 else { return image }
        let width = max(Double(image.width), Double(reference.width), Double(reference.height) * aspect)
        let height = width / aspect
        let outputWidth = Int(width.rounded())
        let outputHeight = Int(height.rounded())
        guard outputWidth > 0, outputHeight > 0 else { return image }

        guard let context = CGContext(
            data: nil,
            width: outputWidth,
            height: outputHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return image }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))
        return context.makeImage() ?? image
    }
}

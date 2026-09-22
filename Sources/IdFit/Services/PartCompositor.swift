import CoreGraphics
import Foundation

enum PartCompositor {
    static let gap = 2

    /// Rectify independently, then place at native resolution on an opaque
    /// white canvas, in the chosen order from top to bottom or left to right.
    static func render(_ source: CGImage, composition: PartComposition, rotation: Int) -> CGImage? {
        guard composition.isComplete else { return nil }
        let sourceSize = CGSize(width: source.width, height: source.height)
        var parts: [CGImage] = []
        for region in composition.regions {
            guard region.isConvex,
                  let aspect = region.naturalAspect(sourceSize: sourceSize),
                  let corrected = PerspectiveCorrector.straighten(source, quad: region, targetAspect: aspect)
            else { return nil }
            parts.append(PageRenderer.rotate(corrected, by: rotation))
        }

        let margin = max(1, Int((Double(parts.map { max($0.width, $0.height) }.max()!) * 0.025).rounded()))
        let vertical = composition.layout == .vertical
        let gaps = gap * (parts.count - 1)
        let width = (vertical ? parts.map(\.width).max()! : parts.map(\.width).reduce(0, +) + gaps) + 2 * margin
        let height = (vertical ? parts.map(\.height).reduce(0, +) + gaps : parts.map(\.height).max()!) + 2 * margin
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var offset = margin
        for part in parts {
            let x = vertical ? (width - part.width) / 2 : offset
            let y = vertical ? height - offset - part.height : (height - part.height) / 2
            context.draw(part, in: CGRect(x: x, y: y, width: part.width, height: part.height))
            offset += (vertical ? part.height : part.width) + gap
        }
        return context.makeImage()
    }
}

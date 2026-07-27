import CoreGraphics
import Foundation
import Vision

/// Finds where the document sits inside a scan, so the app can propose a crop
/// instead of making the user draw every one by hand.
///
/// Uses Vision's document segmentation model, which ships with macOS — no
/// third-party code involved. It returns a quadrilateral that follows the
/// document's tilt; the app's crops are upright rectangles, so what is used
/// here is the box enclosing that quadrilateral.
enum DocumentEdgeDetector {
    /// Detection runs on a downscaled render: the model does not need the
    /// full resolution, and the result is normalized, so it maps back to the
    /// original pixels for free.
    static let analysisSize: CGFloat = 1024

    /// Below this the model is guessing, and a wrong suggestion is worse than
    /// none.
    static let minimumConfidence: Float = 0.5

    /// Blocking; call from a background task.
    static func detect(for ref: SourceRef, in folder: URL) -> CropRect? {
        guard let image = ThumbnailProvider.shared.renderedImage(
            for: ref, in: folder, maxPixel: analysisSize
        ) else { return nil }
        return detect(in: image)
    }

    static func detect(in image: CGImage) -> CropRect? {
        let request = VNDetectDocumentSegmentationRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        guard let observation = request.results?.first,
              observation.confidence >= minimumConfidence else { return nil }

        let box = observation.boundingBox
        // Vision measures from the bottom-left corner upwards; crops are
        // measured from the top-left corner downwards.
        let crop = CropRect(
            x: box.minX,
            y: 1 - box.maxY,
            width: box.width,
            height: box.height
        ).clampedToUnitSquare()

        guard isUseful(crop) else { return nil }
        return crop
    }

    /// Largest share of the scan a suggestion may cover. On a featureless
    /// image the model reports the entire frame as the document; acting on
    /// that would shave a sliver off a scan that needed no cropping at all.
    static let maximumCoverage: Double = 0.92

    /// A sliver is a misdetection, and a box covering nearly everything is
    /// the model saying it found nothing in particular.
    private static func isUseful(_ crop: CropRect) -> Bool {
        guard crop.width > 0.1, crop.height > 0.1 else { return false }
        return crop.width * crop.height < maximumCoverage
    }
}

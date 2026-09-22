import CoreGraphics
import Foundation
import Vision

/// Finds where the document sits inside a scan, so the app can propose a crop
/// instead of making the user draw every one by hand.
///
/// Uses Vision's document segmentation model, which ships with macOS — no
/// third-party code involved. It returns a quadrilateral that follows the
/// document's tilt; the app's crops are upright rectangles, so what is used
/// here is the box enclosing that quadrilateral — either as it lies, or, when
/// the corners turn out to be a rectangle merely lying askew, turned back
/// upright first and offered together with the angle (`tiltProposal`).
enum DocumentEdgeDetector {
    /// Detection runs on a downscaled render: the model does not need the
    /// full resolution, and the result is normalized, so it maps back to the
    /// original pixels for free.
    static let analysisSize: CGFloat = 1024

    /// Below this the model is guessing, and a wrong suggestion is worse than
    /// none.
    static let minimumConfidence: Float = 0.5

    struct Detection: Sendable {
        /// The document's outline, following its tilt.
        var quad: DocumentQuad
        /// The upright box around it, used when straightening is off.
        var crop: CropRect
        /// Separate documents, in reading order. Empty for a single document.
        var regions: [DocumentQuad] = []
    }

    /// Blocking; call from a background task.
    static func detect(for ref: SourceRef, in folder: URL) -> Detection? {
        guard let image = ThumbnailProvider.shared.renderedImage(
            for: ref, in: folder, maxPixel: analysisSize
        ) else { return nil }
        return detect(in: image)
    }

    static func detect(in image: CGImage) -> Detection? {
        let rectangles = VNDetectRectanglesRequest()
        rectangles.maximumObservations = 24
        rectangles.minimumConfidence = 0.7
        rectangles.minimumSize = 0.1
        rectangles.minimumAspectRatio = 0.15
        rectangles.quadratureTolerance = 25
        let rectangleHandler = VNImageRequestHandler(cgImage: image, options: [:])
        if (try? rectangleHandler.perform([rectangles])) != nil {
            let regions = separateRegions(from: (rectangles.results ?? []).map { Self.quad(from: $0) })
            if regions.count > 1 {
                return Detection(quad: regions[0], crop: regions[0].boundingCrop, regions: regions)
            }
        }

        let request = VNDetectDocumentSegmentationRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        guard let observation = request.results?.first,
              observation.confidence >= minimumConfidence else { return nil }

        let quad = Self.quad(from: observation)
        let crop = quad.boundingCrop
        guard isUseful(crop) else { return nil }
        return Detection(quad: quad, crop: crop)
    }

    private static func quad(from observation: VNRectangleObservation) -> DocumentQuad {
        // Vision measures from the bottom-left corner upwards; crops and quads
        // are measured from the top-left corner downwards.
        func flipped(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x, y: 1 - point.y)
        }
        return DocumentQuad(
            topLeft: flipped(observation.topLeft),
            topRight: flipped(observation.topRight),
            bottomRight: flipped(observation.bottomRight),
            bottomLeft: flipped(observation.bottomLeft)
        ).clampedToUnitSquare()

    }

    /// Keep outer document edges rather than their photos, borders or text
    /// boxes. Overlapping alternatives from Vision describe the same part.
    static func separateRegions(from candidates: [DocumentQuad]) -> [DocumentQuad] {
        func box(_ quad: DocumentQuad) -> CGRect {
            let crop = quad.boundingCrop
            return CGRect(x: crop.x, y: crop.y, width: crop.width, height: crop.height)
        }
        let candidates = candidates.filter {
            $0.isConvex && isUseful($0.boundingCrop)
        }.sorted { box($0).width * box($0).height > box($1).width * box($1).height }
        var regions: [DocumentQuad] = []
        for candidate in candidates {
            let bounds = box(candidate)
            let overlaps = regions.contains { region in
                let intersection = bounds.intersection(box(region))
                return !intersection.isNull
                    && intersection.width * intersection.height > bounds.width * bounds.height * 0.2
            }
            if !overlaps { regions.append(candidate) }
        }

        // Group by rows before sorting within a row. A fuzzy pairwise sort
        // would not be transitive for three or more staggered documents.
        var ordered: [DocumentQuad] = []
        while let top = regions.min(by: { box($0).midY < box($1).midY }) {
            let row = regions.filter {
                abs(box($0).midY - box(top).midY) < min(box($0).height, box(top).height) * 0.5
            }.sorted { box($0).midX < box($1).midX }
            ordered.append(contentsOf: row)
            regions.removeAll { row.contains($0) }
        }
        return Array(ordered.prefix(PartComposition.supportedCounts.upperBound))
    }

    // MARK: - Reading a lean out of the corners

    /// What a detection says when the document is not photographed from an
    /// angle but simply lying askew on the glass.
    struct TiltProposal: Equatable, Sendable {
        /// Ready for `Page.tilt`: the turn that puts the document back
        /// upright, which is the lean it was measured at, negated.
        var tilt: Double
        /// The document's own rectangle — the crop the tilt goes with, rather
        /// than the box holding the corners and the slivers beside them.
        var crop: CropRect
    }

    /// Widest the four edges may disagree about the lean before the shape is
    /// taken for a document seen from an angle. A tilt turns the page and
    /// nothing more, so proposing one for a trapezium would leave it just as
    /// far out of square, only pointing a different way; those go to
    /// straightening or to the box around them.
    static let maximumEdgeSpread: Double = 1.5

    /// The tilt a detected quad is worth, if any: nil when the corners are not
    /// a rotated rectangle, and nil when the lean is finer than the app can
    /// store, where the box around the corners is already the document.
    static func tiltProposal(for quad: DocumentQuad, sourceSize: CGSize) -> TiltProposal? {
        guard let lean = TiltGeometry.lean(of: quad, sourceSize: sourceSize),
              lean.spread <= maximumEdgeSpread,
              abs(lean.angle) >= TiltGeometry.step else { return nil }

        // Quantized before the crop is taken, so the crop and the tilt that is
        // stored describe the same rectangle rather than one a rounding apart.
        let angle = TiltGeometry.quantized(lean.angle)
        return TiltProposal(
            tilt: -angle,
            crop: TiltGeometry.uprightBox(of: quad, lean: angle, sourceSize: sourceSize)
        )
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

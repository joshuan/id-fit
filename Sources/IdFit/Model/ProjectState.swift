import Foundation

/// A reference to page content inside the working folder: either a whole image
/// file, or a single page of a PDF file.
struct SourceRef: Hashable, Codable, Sendable {
    /// Path relative to the working folder, always using `/` separators, so
    /// the state file stays valid when the folder moves between machines.
    var file: String
    /// 0-based page index when `file` is a PDF; nil for plain images.
    var pdfPage: Int?

    init(file: String, pdfPage: Int? = nil) {
        self.file = file
        self.pdfPage = pdfPage
    }
}

/// Normalized crop rectangle: all values are fractions of the source
/// width/height (0...1), so the crop survives copies of the same scan with a
/// different resolution or DPI.
struct CropRect: Codable, Equatable, Hashable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    /// Whether two crops describe the same rectangle, give or take the
    /// rounding a trip through pixels and back leaves behind.
    func isClose(to other: CropRect, tolerance: Double = 0.001) -> Bool {
        abs(x - other.x) <= tolerance
            && abs(y - other.y) <= tolerance
            && abs(width - other.width) <= tolerance
            && abs(height - other.height) <= tolerance
    }

    /// Clamps the rect into the unit square, shrinking it only when it cannot
    /// fit by moving.
    func clampedToUnitSquare() -> CropRect {
        let w = min(max(width, 0), 1)
        let h = min(max(height, 0), 1)
        let nx = min(max(x, 0), 1 - w)
        let ny = min(max(y, 0), 1 - h)
        return CropRect(x: nx, y: ny, width: w, height: h)
    }
}

/// The aspect ratio shared by every page's crop, e.g. 210×297 for A4.
struct AspectRatio: Codable, Equatable, Sendable {
    var width: Double
    var height: Double

    var ratio: Double { width / height }
}

struct Page: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var source: SourceRef
    /// Clockwise degrees: 0, 90, 180 or 270.
    var rotation: Int
    var crop: CropRect?
    /// Whether edge detection has already been requested or dismissed for this page.
    var autoDetected: Bool
    /// A reset page stays outside the common format until framing is explicitly
    /// requested again. Reopening must not restore a crop the user rejected.
    var ignoresSharedRatio: Bool
    /// Opt-in, per-page composition. Nil is the ordinary single-region editor.
    var composition: TwoPartComposition?
    /// Turns the document's aspect ratio on its side for this page.
    ///
    /// A passport photographed partly upright and partly sideways cannot be
    /// framed by one fixed orientation, but every page can still share one
    /// *shape* — only which way round it lies differs.
    var transposedRatio: Bool
    /// Set when this page is straightened: the document's four corners in the
    /// photograph, mapped back onto a true rectangle on export. Nil means the
    /// page is taken as-is and only the upright `crop` applies.
    var quad: DocumentQuad?
    /// Fine rotation in clockwise degrees, for a scan that is off true by a
    /// degree or two.
    ///
    /// Mutually exclusive with `quad`, which already carries any tilt in its
    /// corners: while a page is straightened this stays 0.
    var tilt: Double

    init(
        id: UUID = UUID(),
        source: SourceRef,
        rotation: Int = 0,
        crop: CropRect? = nil,
        autoDetected: Bool = false,
        transposedRatio: Bool = false,
        quad: DocumentQuad? = nil,
        tilt: Double = 0,
        ignoresSharedRatio: Bool = false,
        composition: TwoPartComposition? = nil
    ) {
        self.id = id
        self.source = source
        self.rotation = rotation
        self.crop = crop
        self.autoDetected = autoDetected
        self.transposedRatio = transposedRatio
        self.quad = quad
        self.tilt = tilt
        self.ignoresSharedRatio = ignoresSharedRatio
        self.composition = composition
    }

    // Spelled out because writing both halves of Codable by hand stops the
    // compiler from working them out.
    private enum CodingKeys: String, CodingKey {
        case id, source, rotation, crop, autoDetected, transposedRatio, quad, tilt, ignoresSharedRatio, composition
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.source = try container.decode(SourceRef.self, forKey: .source)
        self.rotation = try container.decodeIfPresent(Int.self, forKey: .rotation) ?? 0
        self.crop = try container.decodeIfPresent(CropRect.self, forKey: .crop)
        self.autoDetected = try container.decodeIfPresent(Bool.self, forKey: .autoDetected) ?? false
        self.transposedRatio = try container.decodeIfPresent(Bool.self, forKey: .transposedRatio) ?? false
        self.quad = try container.decodeIfPresent(DocumentQuad.self, forKey: .quad)
        self.tilt = try container.decodeIfPresent(Double.self, forKey: .tilt) ?? 0
        self.ignoresSharedRatio = try container.decodeIfPresent(Bool.self, forKey: .ignoresSharedRatio) ?? false
        self.composition = try container.decodeIfPresent(TwoPartComposition.self, forKey: .composition)
    }

    /// Written by hand only so that an untilted page — which is nearly every
    /// page — does not gain a field saying so. The document is read by people.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(source, forKey: .source)
        try container.encode(rotation, forKey: .rotation)
        try container.encodeIfPresent(crop, forKey: .crop)
        try container.encode(autoDetected, forKey: .autoDetected)
        try container.encode(transposedRatio, forKey: .transposedRatio)
        try container.encodeIfPresent(quad, forKey: .quad)
        if tilt != 0 { try container.encode(tilt, forKey: .tilt) }
        if ignoresSharedRatio { try container.encode(true, forKey: .ignoresSharedRatio) }
        try container.encodeIfPresent(composition, forKey: .composition)
    }
}

extension Page {
    /// The document's shape as this page must hold it.
    func outputRatio(sharedRatio: AspectRatio?) -> Double? {
        guard composition == nil, !ignoresSharedRatio, let ratio = sharedRatio?.ratio, ratio > 0 else { return nil }
        return transposedRatio ? 1 / ratio : ratio
    }
}

/// The whole persisted state of one working folder — the content of its
/// `.idfit` document. Everything the user does (order, crops, ratio) lives
/// here; source files are never modified implicitly.
struct ProjectState: Codable, Equatable, Sendable {
    /// 2 repairs page orientations recorded by an earlier, unreliable guess.
    static let currentVersion = 2

    var version: Int
    var cropAspectRatio: AspectRatio?
    var pages: [Page]
    /// Files this app wrote into the working folder — exported PDFs. They are
    /// skipped when scanning, so an export saved next to the scans does not
    /// come back as a stack of new pages.
    var exportedFiles: [String]
    /// Sources kept on disk after a page was replaced by its combined JPG.
    /// They must not reappear as new pages when the folder is scanned again.
    var retainedSources: [SourceRef]
    /// Whether newly analysed pages are straightened.
    ///
    /// On by default: a document photographed at an angle is a trapezium on
    /// the sensor, and the box around it holds the slivers of desk beside it.
    /// Offering the corners is the answer that needs no undoing — the crop it
    /// would otherwise propose has to be taken apart by hand before the page
    /// can be squared up at all. Turning it off leaves every page taken as it
    /// lies.
    var straightenByDefault: Bool

    init(
        version: Int = Self.currentVersion,
        cropAspectRatio: AspectRatio? = nil,
        pages: [Page] = [],
        exportedFiles: [String] = [],
        straightenByDefault: Bool = true,
        retainedSources: [SourceRef] = []
    ) {
        self.version = version
        self.cropAspectRatio = cropAspectRatio
        self.pages = pages
        self.exportedFiles = exportedFiles
        self.straightenByDefault = straightenByDefault
        self.retainedSources = retainedSources
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        self.cropAspectRatio = try container.decodeIfPresent(AspectRatio.self, forKey: .cropAspectRatio)
        self.pages = try container.decodeIfPresent([Page].self, forKey: .pages) ?? []
        self.exportedFiles = try container.decodeIfPresent([String].self, forKey: .exportedFiles) ?? []
        self.retainedSources = try container.decodeIfPresent([SourceRef].self, forKey: .retainedSources) ?? []
        // A document written before there was a choice to record never said
        // no, so it is read the way a fresh folder is.
        self.straightenByDefault =
            try container.decodeIfPresent(Bool.self, forKey: .straightenByDefault) ?? true
    }

    /// Merges the state with the sources currently present in the folder:
    /// newly discovered sources are appended as fresh pages in the given
    /// order; existing pages are kept untouched — including pages whose source
    /// is currently absent, so edits survive a partially-synced folder.
    func reconciled(with discovered: [SourceRef]) -> ProjectState {
        let known = Set(pages.map(\.source))
            .union(retainedSources)
        var result = self
        for ref in discovered where !known.contains(ref) {
            result.pages.append(Page(source: ref))
        }
        return result
    }

    /// The proportions this page must export at: the document's shared ratio,
    /// laid on its side when the page calls for it. Nil when the document has
    /// no common format and this page is free to be whatever shape it likes.
    func outputRatio(for page: Page) -> Double? {
        page.outputRatio(sharedRatio: cropAspectRatio)
    }

    /// Sources referenced by pages but absent from the folder right now.
    func missingSources(given discovered: [SourceRef]) -> Set<SourceRef> {
        Set(pages.map(\.source)).subtracting(discovered)
    }

    /// Moves the page with the given id so that it ends up at `targetIndex`.
    /// Out-of-range targets are clamped; unknown ids are ignored.
    mutating func movePage(id: UUID, toIndex targetIndex: Int) {
        guard let from = pages.firstIndex(where: { $0.id == id }) else { return }
        let target = min(max(targetIndex, 0), pages.count - 1)
        guard from != target else { return }
        let page = pages.remove(at: from)
        pages.insert(page, at: target)
    }
}

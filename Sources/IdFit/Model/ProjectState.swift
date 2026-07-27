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
struct CropRect: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

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

    init(id: UUID = UUID(), source: SourceRef, rotation: Int = 0, crop: CropRect? = nil) {
        self.id = id
        self.source = source
        self.rotation = rotation
        self.crop = crop
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.source = try container.decode(SourceRef.self, forKey: .source)
        self.rotation = try container.decodeIfPresent(Int.self, forKey: .rotation) ?? 0
        self.crop = try container.decodeIfPresent(CropRect.self, forKey: .crop)
    }
}

/// The whole persisted state of one working folder — the content of
/// `.id-fit.json`. Everything the user does in the app (order, crops, ratio)
/// lives here; source files are never modified implicitly.
struct ProjectState: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int
    var cropAspectRatio: AspectRatio?
    var pages: [Page]
    /// Files this app wrote into the working folder — exported PDFs. They are
    /// skipped when scanning, so an export saved next to the scans does not
    /// come back as a stack of new pages.
    var exportedFiles: [String]

    init(
        version: Int = Self.currentVersion,
        cropAspectRatio: AspectRatio? = nil,
        pages: [Page] = [],
        exportedFiles: [String] = []
    ) {
        self.version = version
        self.cropAspectRatio = cropAspectRatio
        self.pages = pages
        self.exportedFiles = exportedFiles
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        self.cropAspectRatio = try container.decodeIfPresent(AspectRatio.self, forKey: .cropAspectRatio)
        self.pages = try container.decodeIfPresent([Page].self, forKey: .pages) ?? []
        self.exportedFiles = try container.decodeIfPresent([String].self, forKey: .exportedFiles) ?? []
    }

    /// Merges the state with the sources currently present in the folder:
    /// newly discovered sources are appended as fresh pages in the given
    /// order; existing pages are kept untouched — including pages whose source
    /// is currently absent, so edits survive a partially-synced folder.
    func reconciled(with discovered: [SourceRef]) -> ProjectState {
        let known = Set(pages.map(\.source))
        var result = self
        for ref in discovered where !known.contains(ref) {
            result.pages.append(Page(source: ref))
        }
        return result
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

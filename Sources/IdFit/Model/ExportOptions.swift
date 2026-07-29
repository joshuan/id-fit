import Foundation

/// What the user asked for when exporting.
struct ExportOptions: Equatable, Sendable {
    enum Format: String, CaseIterable, Identifiable, Sendable {
        /// One document, every page in order.
        case pdf
        /// One JPEG per page.
        case jpeg
        /// One file per page, each keeping the format it came in.
        case originalFormat

        var id: String { rawValue }

        var title: String {
            switch self {
            case .pdf: "PDF"
            case .jpeg: "JPEG images"
            case .originalFormat: "Images in their original formats"
            }
        }

        var writesSeparateFiles: Bool { self != .pdf }
    }

    enum Naming: String, CaseIterable, Identifiable, Sendable {
        /// 001, 002, 003 — page order, plainly.
        case sequential
        /// The name the scan already has, so a page can still be recognised.
        case original

        var id: String { rawValue }

        var title: String {
            switch self {
            case .sequential: "Numbered in page order"
            case .original: "Named after the original scans"
            }
        }

        var detail: String {
            switch self {
            case .sequential: "001, 002, 003 …"
            case .original: "A page used twice gets “(2)” added, so nothing is overwritten."
            }
        }
    }

    var format: Format = .pdf
    var paper: PDFExporter.Paper = .fitContent
    var naming: Naming = .sequential
}

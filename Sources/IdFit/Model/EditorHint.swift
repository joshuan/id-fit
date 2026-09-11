import Foundation

/// The one line of guidance the page editor shows under a page, named after the
/// gesture that page is waiting for.
///
/// Each kind is said once. Guidance that comes back on every page stops being
/// read and turns into something to look past, so a hint that has been shown —
/// or waved away — is remembered as read and stays quiet until somebody asks
/// for it again.
enum EditorHint: String, CaseIterable, Sendable {
    /// Straightening: the four handles go onto the document's own corners.
    case straighten
    /// Nothing framed yet, so the crop is drawn on the page.
    case drawCrop
    /// There is a crop, and a corner can be pulled out of square with ⌘.
    case perspective

    var text: String {
        switch self {
        case .straighten:
            "Drag each corner onto the document's own corners"
        case .drawCrop:
            "Drag on the page to crop this page — one format for all of them is in the toolbar"
        case .perspective:
            "Hold ⌘ while dragging a corner to correct perspective"
        }
    }

    var icon: String {
        switch self {
        case .straighten: "skew"
        case .drawCrop: "hand.draw"
        case .perspective: "command"
        }
    }

    /// One defaults key for all of them, so a second window sees the same hint
    /// go quiet as the first.
    static let storageKey = "readEditorHints"

    static func read(from stored: String) -> Set<EditorHint> {
        Set(stored.split(separator: " ").compactMap { EditorHint(rawValue: String($0)) })
    }

    /// Sorted, so the same set is always written the same way and a stored
    /// value only changes when what it says changes.
    static func storing(_ hints: Set<EditorHint>) -> String {
        hints.map(\.rawValue).sorted().joined(separator: " ")
    }

    static func marking(_ hint: EditorHint, readIn stored: String) -> String {
        storing(read(from: stored).union([hint]))
    }
}

import Foundation

/// Formats the whole document can be cropped to, plus the mixed mode where it
/// is cropped to none. Values are physical sizes in millimetres; only their
/// proportion matters.
///
/// There is no landscape twin of each entry: a page that lies the other way
/// round holds the same shape sideways instead.
enum AspectRatioPreset: String, CaseIterable, Identifiable {
    case mixed
    case a4
    case passport
    case idCard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mixed: "Mixed (each page its own)"
        case .a4: "A4 (210 × 297)"
        case .passport: "Passport Page (88 × 125)"
        case .idCard: "ID Card (85.6 × 54)"
        }
    }

    var aspectRatio: AspectRatio? {
        switch self {
        case .mixed: nil
        case .a4: AspectRatio(width: 210, height: 297)
        case .passport: AspectRatio(width: 88, height: 125)
        case .idCard: AspectRatio(width: 85.6, height: 54)
        }
    }

    /// The preset matching a stored ratio, if any — used to show the current
    /// selection when a folder is reopened. A ratio held sideways still
    /// counts, since that is the same shape.
    static func matching(_ ratio: AspectRatio?) -> AspectRatioPreset? {
        guard let ratio else { return .mixed }
        return allCases.first { preset in
            guard let candidate = preset.aspectRatio else { return false }
            return abs(candidate.ratio - ratio.ratio) < 0.0001
                || abs(1 / candidate.ratio - ratio.ratio) < 0.0001
        }
    }
}

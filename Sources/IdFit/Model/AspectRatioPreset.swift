import Foundation

/// Ready-made aspect ratios for the shared crop. Values are physical sizes in
/// millimetres or inches; only their ratio matters.
enum AspectRatioPreset: String, CaseIterable, Identifiable {
    case original
    case a4Portrait
    case a4Landscape
    case letterPortrait
    case letterLandscape
    case idCard
    case passportPhoto
    case square

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: "Original (no crop)"
        case .a4Portrait: "A4 Portrait"
        case .a4Landscape: "A4 Landscape"
        case .letterPortrait: "US Letter Portrait"
        case .letterLandscape: "US Letter Landscape"
        case .idCard: "ID Card (85.6 × 54)"
        case .passportPhoto: "Passport Photo (35 × 45)"
        case .square: "Square"
        }
    }

    var aspectRatio: AspectRatio? {
        switch self {
        case .original: nil
        case .a4Portrait: AspectRatio(width: 210, height: 297)
        case .a4Landscape: AspectRatio(width: 297, height: 210)
        case .letterPortrait: AspectRatio(width: 8.5, height: 11)
        case .letterLandscape: AspectRatio(width: 11, height: 8.5)
        case .idCard: AspectRatio(width: 85.6, height: 54)
        case .passportPhoto: AspectRatio(width: 35, height: 45)
        case .square: AspectRatio(width: 1, height: 1)
        }
    }

    /// The preset matching a stored ratio, if any — used to show the current
    /// selection when a folder is reopened.
    static func matching(_ ratio: AspectRatio?) -> AspectRatioPreset? {
        guard let ratio else { return .original }
        return allCases.first { preset in
            guard let candidate = preset.aspectRatio else { return false }
            return abs(candidate.ratio - ratio.ratio) < 0.0001
        }
    }
}

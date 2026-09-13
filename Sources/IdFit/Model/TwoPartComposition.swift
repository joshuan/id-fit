import Foundation

/// Parts stay in the order they were drawn. Each holds its own perspective
/// corners, measured on the unrotated source, and keeps its natural shape.
struct TwoPartComposition: Codable, Equatable, Hashable, Sendable {
    enum Layout: String, Codable, CaseIterable, Sendable {
        case vertical
        case horizontal

        var title: String {
            switch self {
            case .vertical: "Vertical"
            case .horizontal: "Horizontal"
            }
        }
    }

    var regions: [DocumentQuad] = []
    var layout: Layout = .vertical

    var isComplete: Bool { regions.count == 2 }
}

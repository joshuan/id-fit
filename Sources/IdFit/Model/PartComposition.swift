import Foundation

/// Parts stay in the chosen order. Each holds its own perspective
/// corners, measured on the unrotated source, and keeps its natural shape.
struct PartComposition: Codable, Equatable, Hashable, Sendable {
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

    static let supportedCounts = 2...4

    var regions: [DocumentQuad]
    var layout: Layout
    let partCount: Int

    init(regions: [DocumentQuad] = [], layout: Layout = .vertical, partCount: Int = 2) {
        self.partCount = min(max(partCount, 2), 4)
        self.regions = Array(regions.prefix(self.partCount))
        self.layout = layout
    }

    private enum CodingKeys: String, CodingKey { case regions, layout, partCount }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let count = try values.decodeIfPresent(Int.self, forKey: .partCount) ?? 2
        guard Self.supportedCounts.contains(count) else {
            throw DecodingError.dataCorruptedError(forKey: .partCount, in: values,
                                                   debugDescription: "Expected 2 to 4 parts")
        }
        self.init(regions: try values.decode([DocumentQuad].self, forKey: .regions),
                  layout: try values.decode(Layout.self, forKey: .layout), partCount: count)
    }

    var isComplete: Bool { regions.count == partCount }

    mutating func cycleOrder() {
        guard regions.count > 1 else { return }
        regions.append(regions.removeFirst())
    }

    /// A click fixes the next slot; all unchosen parts keep their relative order.
    mutating func movePart(at index: Int, to slot: Int) {
        guard regions.indices.contains(index), regions.indices.contains(slot), index != slot else { return }
        regions.insert(regions.remove(at: index), at: slot)
    }
}

import Foundation

/// The human-readable buckets used to browse image captures. These are kept
/// deliberately broad: an album named "Travel" remains useful whether the
/// classifier saw a boarding pass, a hotel, or a map.
nonisolated enum ShelfImageCategory: String, CaseIterable, Codable, Identifiable, Sendable {
    case food
    case clothing
    case travel
    case events
    case work
    case home
    case nature
    case people
    case inspiration
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .food: "Food"
        case .clothing: "Clothing"
        case .travel: "Travel"
        case .events: "Events"
        case .work: "Work"
        case .home: "Home"
        case .nature: "Nature"
        case .people: "People"
        case .inspiration: "Inspiration"
        case .other: "Other finds"
        }
    }

    var systemImage: String {
        switch self {
        case .food: "fork.knife"
        case .clothing: "tshirt"
        case .travel: "suitcase.rolling"
        case .events: "calendar"
        case .work: "laptopcomputer"
        case .home: "house"
        case .nature: "leaf"
        case .people: "person.2"
        case .inspiration: "sparkles"
        case .other: "square.stack.3d.up"
        }
    }

}

extension ShelfItem {
    /// Category produced by the on-device semantic pass. Older captures
    /// gracefully fall into Other finds until the next refresh classifies them.
    var imageCategory: ShelfImageCategory {
        guard let rawValue = extraction?.visualCategory,
              let category = ShelfImageCategory(rawValue: rawValue) else {
            return .other
        }
        return category
    }
}

import AppKit
import Foundation
import Vision

/// Turns Vision's on-device image semantics into the small set of albums Cove
/// exposes. Vision supplies a rich visual representation; this layer maps its
/// labels, together with OCR, to stable names such as Food and Travel rather
/// than exposing hundreds of low-level classifier labels in the shelf.
enum ImageSemanticClassifier {
    nonisolated static let categoryVersion = 1

    nonisolated static func category(for image: NSImage, recognizedText: String?) -> ShelfImageCategory {
        let labels = visionLabels(for: image)
        return category(labels: labels, recognizedText: recognizedText ?? "")
    }

    nonisolated private static func visionLabels(for image: NSImage) -> [(identifier: String, confidence: Float)] {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return []
        }

        let request = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        do {
            try handler.perform([request])
        } catch {
            return []
        }

        return (request.results ?? []).map { observation in
            (identifier: observation.identifier, confidence: observation.confidence)
        }
    }

    nonisolated private static func category(
        labels: [(identifier: String, confidence: Float)],
        recognizedText: String
    ) -> ShelfImageCategory {
        let text = normalizedText(recognizedText)
        if let directTextCategory = directTextCategory(in: text) {
            return directTextCategory
        }

        var scores = Dictionary(uniqueKeysWithValues: ShelfImageCategory.allCases.map { ($0, 0.0) })

        for label in labels where label.confidence >= 0.08 {
            let normalized = normalizedText(label.identifier)
            for (category, cues) in cuesByCategory where cues.contains(where: normalized.contains) {
                // Vision labels are the image's semantic signal, so they carry
                // more weight than OCR words that may merely be visible in a
                // screenshot of an unrelated page.
                scores[category, default: 0] += 2 + Double(label.confidence) * 6
            }
        }

        for (category, cues) in cuesByCategory where cues.contains(where: text.contains) {
            scores[category, default: 0] += 1.25
        }

        guard let best = scores
            .filter({ $0.key != .other && $0.value > 0 })
            .max(by: { $0.value < $1.value }) else {
            return .other
        }

        return best.key
    }

    nonisolated private static func normalizedText(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
    }

    /// Terms that name a real-world intent are more reliable than a generic
    /// Vision label such as "website" on a screenshot of a boarding pass.
    nonisolated private static func directTextCategory(in text: String) -> ShelfImageCategory? {
        for (category, cues) in directTextCues where cues.contains(where: text.contains) {
            return category
        }
        return nil
    }

    nonisolated private static let directTextCues: [(ShelfImageCategory, [String])] = [
        (.travel, ["boarding pass", "flight", "airport", "passport", "coach", "train", "hotel", "itinerary"]),
        (.events, ["meetup", "conference", "concert", "festival", "workshop", "rsvp"]),
        (.food, ["restaurant", "recipe", "menu", "dessert", "coffee shop"]),
        (.clothing, ["outfit", "clothing", "fashion", "apparel", "sneaker"]),
        (.home, ["interior design", "living room", "bedroom", "kitchen"]),
        (.nature, ["national park", "mountain", "sunset", "wildlife"])
    ]

    nonisolated private static let cuesByCategory: [ShelfImageCategory: [String]] = [
        .food: [
            "food", "meal", "dish", "restaurant", "cuisine", "pizza", "burger", "pasta",
            "cake", "dessert", "coffee", "tea", "drink", "beverage", "menu"
        ],
        .clothing: [
            "clothing", "fashion", "apparel", "garment", "dress", "shirt", "tshirt", "shoe",
            "sneaker", "handbag", "jewelry", "jewellery", "outfit", "style"
        ],
        .travel: [
            "travel", "flight", "airplane", "aircraft", "airport", "boarding", "passport",
            "luggage", "suitcase", "train", "railway", "coach", "hotel", "map", "beach",
            "landmark", "tourism", "vacation", "journey"
        ],
        .events: [
            "event", "meetup", "conference", "concert", "festival", "calendar", "workshop",
            "exhibition", "invitation", "rsvp", "ticket"
        ],
        .work: [
            "work", "office", "laptop", "computer", "keyboard", "document", "spreadsheet",
            "presentation", "diagram", "code", "design system", "dashboard", "desk"
        ],
        .home: [
            "home", "house", "interior", "furniture", "sofa", "kitchen", "bedroom", "room",
            "apartment", "architecture"
        ],
        .nature: [
            "nature", "landscape", "mountain", "forest", "tree", "flower", "plant", "garden",
            "animal", "bird", "outdoor", "sunset", "ocean"
        ],
        .people: [
            "person", "people", "portrait", "face", "selfie", "group", "family", "baby",
            "human"
        ],
        .inspiration: [
            "art", "illustration", "painting", "poster", "typography", "graphic", "logo", "meme",
            "moodboard", "inspiration", "abstract"
        ]
    ]
}

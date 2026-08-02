import AppKit
import Foundation

/// Decides which album a captured image belongs in, using the best classifier
/// that is actually available.
///
/// With MobileCLIP installed this is real zero-shot classification: the image's
/// embedding is compared against embeddings of short phrases describing each
/// album, in the shared space the two towers were trained into. Without it, the
/// older Vision label-and-keyword pass still runs — an unclassified shelf is
/// worse than a roughly classified one.
nonisolated enum ShelfImageCategorizer {
    /// Names the classifier that produced a stored category, so a capture sorted
    /// by the weaker pass can be found and re-sorted once the encoders arrive.
    static var currentID: String {
        MobileCLIPEmbeddingService.isInstalled()
            ? "clip.\(MobileCLIPModelDescriptor.current.id)"
            : visionID
    }

    static let visionID = "vision.\(ImageSemanticClassifier.categoryVersion)"

    /// Whether a stored category is worth recomputing.
    ///
    /// Deliberately one-directional: a capture sorted by CLIP is left alone when
    /// the encoders are missing. Re-running it would replace a good category
    /// with a worse one, which is not what "refresh" should ever mean.
    static func needsReclassification(_ storedID: String?) -> Bool {
        guard let storedID else { return true }
        guard MobileCLIPEmbeddingService.isInstalled() else {
            // No encoders: only a capture that never ran through anything is
            // worth queueing.
            return storedID.isEmpty
        }
        return storedID != currentID
    }

    /// The album for one image. `embedding` is the image's own vector when the
    /// pipeline already computed one — it always has, if the encoders are there,
    /// so this never re-runs the image tower.
    static func category(
        for image: NSImage,
        embedding: [Float]?,
        recognizedText: String?
    ) async -> (category: ShelfImageCategory, classifierID: String) {
        if let embedding,
           let category = await MobileCLIPAlbumClassifier.shared.category(for: embedding) {
            return (category, currentID)
        }
        return (
            ImageSemanticClassifier.category(for: image, recognizedText: recognizedText),
            visionID
        )
    }
}

/// Zero-shot album classification against CLIP text prototypes.
///
/// Each album is described by several short phrases rather than one, and their
/// embeddings are averaged into a single prototype vector. One phrase carries
/// its own quirks — "food" alone drags in anything on a table — while an
/// average of several sits nearer the middle of what the album actually means.
/// This is standard CLIP prompt ensembling and it is the difference between
/// usable albums and a coin flip.
actor MobileCLIPAlbumClassifier {
    nonisolated static let shared = MobileCLIPAlbumClassifier()

    /// Bump when the prompts below change: cached prototypes are keyed by it, so
    /// an edit here invalidates them rather than silently keeping the old text.
    nonisolated private static let promptVersion = 1

    /// Below this, the winning album isn't winning by enough to be worth
    /// asserting, and the capture goes to Other finds. CLIP is confidently wrong
    /// on out-of-vocabulary images, so this floor is what stops a diagram
    /// landing in Food because Food was the nearest of ten wrong answers.
    nonisolated private static let minimumConfidence: Float = 0.32

    /// CLIP's own trained temperature. Similarities live in a narrow band around
    /// 0.2–0.35, so a softmax over the raw cosines would be almost uniform and
    /// the threshold above would mean nothing.
    nonisolated private static let logitScale: Float = 100

    private let embeddings = MobileCLIPEmbeddingService.shared
    private var prototypes: [ShelfImageCategory: [Float]]?

    /// The album for an image vector, or `nil` when the text tower is
    /// unavailable or nothing scores well enough to claim it.
    func category(for embedding: [Float]) async -> ShelfImageCategory? {
        guard let prototypes = await resolvedPrototypes(), !prototypes.isEmpty else {
            return nil
        }

        let scores = prototypes.mapValues { prototype in
            zip(embedding, prototype).reduce(Float.zero) { $0 + $1.0 * $1.1 }
        }
        guard let best = scores.max(by: { $0.value < $1.value }) else { return nil }

        // Softmax over every album, so the answer accounts for how close the
        // runners-up were rather than only how high the winner scored.
        let exponentials = scores.values.map { exp(Self.logitScale * ($0 - best.value)) }
        let confidence = 1 / exponentials.reduce(0, +)

        return confidence >= Self.minimumConfidence ? best.key : .other
    }

    /// Throws away the prototypes, in memory and on disk.
    ///
    /// Prototype vectors belong to the weights that produced them. Keeping them
    /// across a model change would compare new image vectors against album
    /// vectors from the old text tower — different spaces, so every album would
    /// score like noise without anything looking broken.
    func reset() {
        prototypes = nil
        if let cacheURL {
            try? FileManager.default.removeItem(at: cacheURL)
        }
    }

    /// Builds the prototypes now rather than on the first capture, so the cost
    /// of encoding ~45 prompts lands while the user is still looking at a
    /// progress line in Settings.
    func warm() async {
        _ = await resolvedPrototypes()
    }

    // MARK: - Prototypes

    private func resolvedPrototypes() async -> [ShelfImageCategory: [Float]]? {
        if let prototypes { return prototypes }

        if let cached = loadCachedPrototypes() {
            prototypes = cached
            return cached
        }

        var built: [ShelfImageCategory: [Float]] = [:]
        for (category, prompts) in Self.prompts {
            var sum = [Float](repeating: 0, count: MobileCLIPModelDescriptor.current.embeddingDimension)
            var counted = 0

            for prompt in prompts {
                guard let vector = try? await embeddings.embed(text: prompt),
                      vector.count == sum.count else {
                    continue
                }
                for index in vector.indices { sum[index] += vector[index] }
                counted += 1
            }

            // A partially built prototype is a quietly wrong one; drop the album
            // rather than compare against an average of two prompts out of five.
            guard counted == prompts.count else { return nil }
            built[category] = MobileCLIPEmbeddingService.normalized(sum)
        }

        guard !built.isEmpty else { return nil }
        prototypes = built
        cachePrototypes(built)
        return built
    }

    /// Encoding ~50 prompts takes a moment and the result never changes for a
    /// given model and prompt set, so it is written beside the models rather
    /// than recomputed on every launch.
    private var cacheURL: URL? {
        MobileCLIPModelStore.installedModelsDirectory?
            .deletingLastPathComponent()
            .appending(path: "album-prototypes-\(MobileCLIPModelDescriptor.current.id)-v\(Self.promptVersion).json")
    }

    private func loadCachedPrototypes() -> [ShelfImageCategory: [Float]]? {
        guard let cacheURL,
              let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode([String: [Float]].self, from: data) else {
            return nil
        }

        var prototypes: [ShelfImageCategory: [Float]] = [:]
        for (key, vector) in decoded {
            guard let category = ShelfImageCategory(rawValue: key),
                  vector.count == MobileCLIPModelDescriptor.current.embeddingDimension else {
                return nil
            }
            prototypes[category] = vector
        }
        // A cache missing an album would silently stop that album from ever
        // being chosen.
        guard prototypes.count == Self.prompts.count else { return nil }
        return prototypes
    }

    private func cachePrototypes(_ prototypes: [ShelfImageCategory: [Float]]) {
        guard let cacheURL,
              let data = try? JSONEncoder().encode(
                  Dictionary(uniqueKeysWithValues: prototypes.map { ($0.key.rawValue, $0.value) })
              ) else {
            return
        }
        try? FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: cacheURL, options: .atomic)
    }

    /// Written the way CLIP's training captions were: "a photo of …", plainly,
    /// with a couple of variants covering the screenshot case. Cove's captures
    /// are as often a screenshot of a thing as a photograph of it, and the two
    /// look nothing alike to the image tower.
    ///
    /// `.other` has no prompts on purpose — it is where a capture goes when no
    /// album is convincing, not something to match against.
    nonisolated private static let prompts: [ShelfImageCategory: [String]] = [
        .food: [
            "a photo of food",
            "a photo of a meal on a plate",
            "a photo of a restaurant dish",
            "a screenshot of a recipe",
            "a photo of coffee or a drink"
        ],
        .clothing: [
            "a photo of clothing",
            "a photo of an outfit someone is wearing",
            "a product photo of a shoe or a bag",
            "a screenshot of an online clothing shop",
            "a photo of jewellery"
        ],
        .travel: [
            "a photo taken while travelling",
            "a photo of an airport or an aeroplane",
            "a screenshot of a boarding pass or a ticket",
            "a photo of a hotel room",
            "a screenshot of a map or an itinerary"
        ],
        .events: [
            "a photo of a concert or a festival",
            "a poster for an event",
            "a screenshot of an event invitation",
            "a photo of a conference or a meetup",
            "a screenshot of a calendar"
        ],
        .work: [
            "a screenshot of a computer application",
            "a screenshot of source code",
            "a screenshot of a document or a spreadsheet",
            "a photo of a desk with a laptop",
            "a screenshot of a chart or a dashboard"
        ],
        .home: [
            "a photo of a room in a house",
            "a photo of furniture",
            "a photo of interior design",
            "a photo of a kitchen",
            "a photo of a building's architecture"
        ],
        .nature: [
            "a photo of a landscape",
            "a photo of plants or flowers",
            "a photo of an animal",
            "a photo of the sea or a mountain",
            "a photo of a garden"
        ],
        .people: [
            "a photo of a person",
            "a portrait of someone's face",
            "a photo of a group of people",
            "a selfie",
            "a photo of a family"
        ],
        .inspiration: [
            "a piece of art or an illustration",
            "a graphic design or a poster",
            "a photo of typography",
            "a meme image",
            "an abstract image saved for inspiration"
        ]
    ]
}

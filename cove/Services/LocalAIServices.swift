import AppKit
import Foundation
import Vision

/// Text recognition through Vision's on-device engine. Nothing leaves the Mac,
/// and no model file ships with the app — the recogniser is part of the OS.
///
/// `.accurate` rather than `.fast`: this runs once per capture on a background
/// actor, where a few hundred milliseconds cost nothing, and the text it finds
/// is what the item is searchable by for the rest of its life.
nonisolated struct VisionOCRService: OCRService {
    func recognizeText(in image: NSImage) async throws -> String {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw OCRError.undecodableImage
        }

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                // Vision returns observations in reading order; one line each,
                // joined so a paragraph in a screenshot stays a paragraph.
                let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines.joined(separator: "\n"))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            do {
                try VNImageRequestHandler(cgImage: cgImage).perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    enum OCRError: LocalizedError {
        case undecodableImage

        var errorDescription: String? {
            switch self {
            case .undecodableImage: "The image could not be read for text recognition."
            }
        }
    }
}

/// Enrichment without a model: tags and a short title read straight off what
/// the capture already told us — the kind, the host, the file extension, the
/// first line of a note.
///
/// It deliberately invents nothing. No merchant, no total, no date: those are
/// fields a reader has to be able to trust, and a plausible guess in a receipt
/// total is worse than a blank. Everything typed stays empty until a real
/// extraction fills it in.
nonisolated struct LocalEnrichmentService: EnrichmentService {
    func enrich(text: String, kind: ShelfItemKind) async throws -> ItemEnrichment {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let shortTitle = Self.shortTitle(from: cleaned)

        var tags = [kind.label.lowercased()]
        tags.append(contentsOf: Self.keywords(in: cleaned).prefix(4))

        return ItemEnrichment(
            // A "summary" that is the first line restated is noise; the detail
            // panel already shows the note itself.
            summary: nil,
            tags: Array(NSOrderedSet(array: tags).compactMap { $0 as? String }),
            extraction: ItemExtraction(
                category: Self.category(for: kind),
                shortTitle: shortTitle
            )
        )
    }

    private static func category(for kind: ShelfItemKind) -> String {
        switch kind {
        case .link: "link"
        case .text: "note"
        case .file: "file"
        case .image, .screenshot: "image"
        }
    }

    private static func shortTitle(from text: String) -> String? {
        guard let firstLine = text.split(separator: "\n").first else { return nil }
        let words = firstLine.split(whereSeparator: \.isWhitespace).prefix(8)
        guard !words.isEmpty else { return nil }
        return words.joined(separator: " ")
    }

    /// Longest distinct words, lowercased. Crude on purpose — it exists so a
    /// capture is never tagless, not to be clever.
    private static func keywords(in text: String) -> [String] {
        var seen = Set<String>()
        return text
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 4 && !Self.stopWords.contains($0) }
            .filter { seen.insert($0).inserted }
            .sorted { $0.count > $1.count }
    }

    private static let stopWords: Set<String> = [
        "this", "that", "with", "from", "have", "your", "about", "into", "then",
        "them", "they", "there", "here", "what", "when", "will", "would", "http",
        "https", "www", "com"
    ]
}

/// Literal keyword matching over everything an item carries, ranked by where
/// the hit landed.
///
/// Still the whole search when the encoders are not installed, and still half
/// of it when they are: this is what a semantic search cannot do, which is find
/// an exact order number. See `SemanticSearchService` for the other half.
nonisolated struct KeywordSearchService: SearchService {
    @MainActor
    func search(_ query: String, in items: [ShelfItem]) async throws -> [ShelfItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return items }

        let terms = Self.terms(in: trimmed)
        guard !terms.isEmpty else { return items }

        return items
            .compactMap { item -> (item: ShelfItem, score: Int)? in
                let score = Self.score(item, terms: terms)
                return score > 0 ? (item, score) : nil
            }
            // Ties break on recency, so a page of equal matches still reads
            // newest-first like the rest of the shelf.
            .sorted {
                $0.score == $1.score
                    ? $0.item.createdAt > $1.item.createdAt
                    : $0.score > $1.score
            }
            .map(\.item)
    }

    /// How well one item answers the query. Zero means "not a match".
    ///
    /// Terms are scored independently and an item needs *one* of them, not all.
    /// Requiring all of them was a quiet recall bug with a very ordinary
    /// trigger: a saved YouTube link matches "youtube" on its host and nothing
    /// on "video", so asking about "the youtube video" scored it zero and the
    /// shelf swore it had no such thing. Anyone typing a phrase rather than a
    /// keyword hit this, and it got worse the more precisely they described
    /// what they wanted.
    ///
    /// Precision is kept by the ranking instead of by exclusion: the count of
    /// matched terms is worth more than any combination of field weights — the
    /// heaviest a single term can score is 30 — so an item matching every word
    /// always sorts above one matching some of them, and the partial matches
    /// sit below rather than being thrown away.
    private static func score(_ item: ShelfItem, terms: [String]) -> Int {
        // Split once per item rather than once per (item, term): the words are
        // the same whichever term is being asked about.
        let fields = Fields(item)
        var total = 0
        var matched = 0

        for term in terms {
            let termScore = fields.weight(for: term)
            guard termScore > 0 else { continue }
            matched += 1
            total += termScore
        }

        guard matched > 0 else { return 0 }
        return matched * 100 + total
    }

    /// The words of the query worth searching for.
    ///
    /// Stop words are dropped, and this is not tidiness — it was the difference
    /// between a search and a shuffle. Every term used to be scored, and
    /// `matched * 100` rewards *how many* of them an item hits, so "somewhere to
    /// walk at the weekend" ranked by how many of "to", "at" and "the" a capture
    /// contained. On a 25-capture shelf that query returned 24 of them.
    ///
    /// The fallback matters as much as the filter: if everything typed was a
    /// stop word, they are put back. Someone searching for "the" on a shelf of
    /// film titles means it.
    static func terms(in query: String) -> [String] {
        let all = query
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)

        let meaningful = all.filter { $0.count > 2 && !stopWords.contains($0) }
        return meaningful.isEmpty ? all : meaningful
    }

    /// One item's searchable text, split into words.
    ///
    /// Words, and that is the fix. Matching used to be
    /// `localizedCaseInsensitiveContains`, which is substring-anywhere: "in"
    /// matched "hiking", "migrations", "confirmation" and "Nilgiris", so short
    /// terms hit nearly the whole shelf and the ranking was driven by noise.
    /// This costs the same and asks the question that was meant.
    ///
    /// Prefix rather than equality, so "hill" still finds "hills" and "youtub"
    /// still finds "youtube" — a term has to start a word, not merely occur
    /// somewhere inside one.
    private struct Fields {
        let title: [String]
        let tags: [String]
        let note: [String]
        let host: [String]
        let summary: [String]
        let extracted: [String]
        let sourceApp: [String]
        let address: [String]

        init(_ item: ShelfItem) {
            title = Self.words(item.title)
            tags = item.tags.flatMap(Self.words)
            note = Self.words(item.userNote)
            host = Self.words(item.linkHost)
            summary = Self.words(item.summary)
            extracted = Self.words(item.extractedText)
            sourceApp = Self.words(item.sourceApp)
            address = Self.words(item.linkURL?.absoluteString)
        }

        /// Where the hit landed. A title hit is what the user named the thing,
        /// an extracted-text hit is a word that happened to be inside a
        /// screenshot.
        func weight(for term: String) -> Int {
            var score = 0
            if Self.hit(term, title) { score += 8 }
            if Self.hit(term, tags) { score += 5 }
            if Self.hit(term, note) { score += 4 }
            if Self.hit(term, host) { score += 4 }
            if Self.hit(term, summary) { score += 3 }
            if Self.hit(term, extracted) { score += 2 }
            if Self.hit(term, sourceApp) { score += 2 }
            // The address itself. The weakest signal — it is full of slugs and
            // ids nobody types — but also the only place a word like "watch" or
            // a video id lives.
            if Self.hit(term, address) { score += 2 }
            return score
        }

        private static func hit(_ term: String, _ words: [String]) -> Bool {
            words.contains { $0.hasPrefix(term) }
        }

        private static func words(_ value: String?) -> [String] {
            guard let value else { return [] }
            return value
                .lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
        }
    }

    /// Words too common to tell two captures apart. Kept short on purpose: this
    /// only has to cover what people pad a spoken-sounding query with.
    private static let stopWords: Set<String> = [
        "the", "and", "for", "was", "were", "are", "any", "all", "can", "did",
        "does", "have", "has", "had", "how", "into", "its", "it's", "not", "our",
        "out", "own", "she", "that", "them", "then", "there", "these", "they",
        "this", "those", "was", "what", "when", "where", "which", "who", "will",
        "with", "would", "you", "your", "about", "from", "some", "something",
        "somewhere", "anything", "there's", "get", "got", "let", "put", "see",
        "want", "need", "make", "made", "just", "like", "know", "http", "https",
        "www", "com"
    ]
}

/// Keyword search and the stored vectors, fused.
///
/// The vectors were being computed, versioned, re-indexed on a model change and
/// then never read by anything except the album classifier. This is what reads
/// them.
///
/// Three ranked lists go in and one comes out:
///
///   1. **Keyword.** Exact, high precision, and the only one that can find an
///      order number or a filename.
///   2. **Query text against each item's text vector.** Finds the capture that
///      says "invoice" when the word typed was "receipt".
///   3. **Query text against each item's *image* vector.** MobileCLIP puts both
///      towers in one space, so this finds a photo of a dog for the word "dog"
///      on an item that carries no text at all. It is the one result the shelf
///      could not previously produce by any means.
///
/// Lists 2 and 3 are kept apart rather than merged into a best-of, because they
/// are not on the same scale: text-to-text similarities sit well above
/// text-to-image ones, so one shared cut-off would let a strong text match
/// silently suppress every cross-modal result.
nonisolated struct SemanticSearchService: SearchService {
    let embeddings: any EmbeddingService

    private let keyword = KeywordSearchService()

    /// The most a single semantic list may contribute. Keyword results are
    /// never capped — an exact match is an exact match — but "things that feel
    /// related" is a long tail, and past a dozen it stops being a search result
    /// and starts being the shelf again.
    private static let maxSemanticMatches = 12

    /// How far above the crowd a similarity has to stand, in standard
    /// deviations.
    ///
    /// Deliberately *not* an absolute cosine. `MobileCLIPAlbumClassifier` already
    /// records why: raw similarities live in a narrow band around 0.2–0.35, they
    /// are not comparable across queries, and any fixed number here is a
    /// invented constant that returns the whole shelf for one query and nothing
    /// for the next.
    ///
    /// What separates a real query from gibberish is not the height of the best
    /// score, it is whether anything stands out at all. A word the shelf knows
    /// produces a few outliers; a word it does not produces a flat distribution
    /// with a meaningless maximum. Cutting at two deviations above the mean
    /// asks that question directly and calibrates itself to each query.
    private static let outlierDeviations: Float = 2

    /// Below this many scored items the mean and deviation are not describing a
    /// distribution, they are describing a handful of numbers. Keyword search
    /// alone covers a shelf this small perfectly well.
    ///
    /// Twelve rather than five, and the reason is arithmetic rather than taste.
    /// The largest z-score `n` samples can produce is `(n - 1) / √n`: one item
    /// alone at the top with everything else tied beneath it. That ceiling is
    /// 1.79 at n = 5 — *below* the 2σ cut above — so on a five-capture shelf the
    /// test was not strict, it was unsatisfiable, and the vector half returned
    /// nothing no matter how well something matched. It stays under 2.5 until
    /// about n = 8.
    ///
    /// Lowering the cut instead was the obvious alternative and it is worse.
    /// Measured on a seven-capture shelf, a clean semantic hit ("bread" → a
    /// sourdough note) scored z = 1.55 while pure gibberish scored z = 1.60:
    /// there is no threshold down there that admits the first and rejects the
    /// second, because at that size the distribution genuinely cannot tell them
    /// apart. Being honestly keyword-only until the shelf is big enough beats
    /// answering from noise.
    private static let minimumSampleSize = 12

    @MainActor
    func search(_ query: String, in items: [ShelfItem]) async throws -> [ShelfItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return items }

        let byKeyword = try await keyword.search(trimmed, in: items)

        // A query the text tower cannot encode is not a failed search — it is a
        // keyword search, which is what Cove did before any of this.
        guard let vector = try? await embeddings.embed(text: trimmed) else {
            return byKeyword
        }

        let byText = Self.outliers(near: vector, in: items) { $0.textEmbedding }
        let byImage = Self.outliers(near: vector, in: items) { $0.embedding }
        guard !byText.isEmpty || !byImage.isEmpty else { return byKeyword }

        return Self.fused([byKeyword, byText, byImage])
    }

    // MARK: - The vector half

    /// Items whose stored vector stands out from the rest for this query.
    ///
    /// Only vectors written by the model currently installed are considered.
    /// Two encoders produce two different spaces, and a dot product across them
    /// is a number with no meaning — which would not look like a bug, it would
    /// look like search having become bad.
    private static func outliers(
        near query: [Float],
        in items: [ShelfItem],
        using vector: (ShelfItem) -> [Float]?
    ) -> [ShelfItem] {
        let version = AIServices.currentEmbeddingModelVersion
        var scored: [(item: ShelfItem, similarity: Float)] = []

        for item in items where item.embeddingModelVersion == version {
            // Length equality is the cheap guard against a vector written by a
            // model with the same version string and a different shape.
            guard let stored = vector(item), stored.count == query.count else { continue }
            scored.append((item, dot(query, stored)))
        }

        guard scored.count >= minimumSampleSize else { return [] }

        let similarities = scored.map(\.similarity)
        let mean = similarities.reduce(0, +) / Float(similarities.count)
        let variance = similarities
            .reduce(Float.zero) { $0 + ($1 - mean) * ($1 - mean) } / Float(similarities.count)
        let deviation = variance.squareRoot()

        // Every item equally similar means nothing was found, however high the
        // numbers are. Without this, a shelf of near-identical screenshots would
        // return all of them for any word at all.
        guard deviation > 0 else { return [] }

        let floor = mean + outlierDeviations * deviation
        return scored
            .filter { $0.similarity >= floor }
            .sorted { $0.similarity > $1.similarity }
            .prefix(maxSemanticMatches)
            .map(\.item)
    }

    /// Both towers L2-normalise on the way out, so this is a cosine.
    private static func dot(_ a: [Float], _ b: [Float]) -> Float {
        var total = Float.zero
        for index in a.indices { total += a[index] * b[index] }
        return total
    }

    // MARK: - Fusion

    /// Reciprocal rank fusion.
    ///
    /// Rank-based rather than score-based, because the three lists are measured
    /// in different units — an integer keyword weight, a text-to-text cosine and
    /// a text-to-image cosine — and no normalisation of those onto one scale is
    /// honest. What each list can be trusted to say is the order it put things
    /// in, and that is all this reads.
    ///
    /// An item found by two lists outranks one found by either alone, which is
    /// the behaviour worth having: the capture that both says "receipt" and
    /// looks like one is the answer.
    private static func fused(_ lists: [[ShelfItem]]) -> [ShelfItem] {
        // The standard damping constant. Large enough that the gap between rank
        // 1 and rank 2 does not dwarf the agreement of two lists further down.
        let damping = 60.0

        var scores: [UUID: Double] = [:]
        var items: [UUID: ShelfItem] = [:]

        for list in lists {
            for (index, item) in list.enumerated() {
                scores[item.id, default: 0] += 1 / (damping + Double(index + 1))
                items[item.id] = item
            }
        }

        return scores
            .sorted {
                // Ties break on recency, so equal relevance still reads
                // newest-first like the rest of the shelf.
                $0.value == $1.value
                    ? (items[$0.key]?.createdAt ?? .distantPast)
                        > (items[$1.key]?.createdAt ?? .distantPast)
                    : $0.value > $1.value
            }
            .compactMap { items[$0.key] }
    }
}

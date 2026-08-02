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
/// This is the whole search for now. The semantic half — a query vector dotted
/// against stored embeddings, then fused with these results — is the next
/// phase; the ranking below is what keeps the shelf usable meanwhile, and it is
/// also what a semantic search cannot do: find an exact order number.
nonisolated struct KeywordSearchService: SearchService {
    @MainActor
    func search(_ query: String, in items: [ShelfItem]) async throws -> [ShelfItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return items }

        let terms = trimmed.lowercased()
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)

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

    /// Every term must appear somewhere; the weight is about *where*. A title
    /// hit is what the user named the thing, an extracted-text hit is a word
    /// that happened to be inside a screenshot.
    private static func score(_ item: ShelfItem, terms: [String]) -> Int {
        var total = 0
        for term in terms {
            var termScore = 0
            if item.title.localizedCaseInsensitiveContains(term) { termScore += 8 }
            if item.tags.contains(where: { $0.localizedCaseInsensitiveContains(term) }) {
                termScore += 5
            }
            if item.userNote?.localizedCaseInsensitiveContains(term) == true { termScore += 4 }
            if item.linkHost?.localizedCaseInsensitiveContains(term) == true { termScore += 4 }
            if item.summary?.localizedCaseInsensitiveContains(term) == true { termScore += 3 }
            if item.extractedText?.localizedCaseInsensitiveContains(term) == true { termScore += 2 }
            if item.sourceApp?.localizedCaseInsensitiveContains(term) == true { termScore += 2 }
            guard termScore > 0 else { return 0 }
            total += termScore
        }
        return total
    }
}

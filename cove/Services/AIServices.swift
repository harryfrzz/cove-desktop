import AppKit
import SwiftUI

/// The on-device stack, as protocols.
///
/// OCR runs through Vision and embeddings through MobileCLIP's Core ML encoders;
/// `enrichment` still derives what it can from the text a capture already
/// carries. Everything that needs a model goes through these protocols so
/// switching one on is a change to `AIServices.current` and nothing else.
protocol EmbeddingService: Sendable {
    func embed(image: NSImage) async throws -> [Float]
    func embed(text: String) async throws -> [Float]
}

protocol OCRService: Sendable {
    func recognizeText(in image: NSImage) async throws -> String
}

/// Summary, tags, and typed fields for one captured item.
protocol EnrichmentService: Sendable {
    func enrich(text: String, kind: ShelfItemKind) async throws -> ItemEnrichment
}

protocol SearchService: Sendable {
    @MainActor
    func search(_ query: String, in items: [ShelfItem]) async throws -> [ShelfItem]
}

nonisolated struct AIServices: Sendable {
    /// `nil` when MobileCLIP's encoders are not installed. The pipeline skips
    /// the embedding steps rather than faking vectors — a random vector would be
    /// indistinguishable from a real one downstream and would quietly poison
    /// every similarity the search eventually runs.
    let embeddings: (any EmbeddingService)?
    let ocr: (any OCRService)?
    let enrichment: any EnrichmentService
    let search: any SearchService

    /// What Cove runs today: Vision OCR, MobileCLIP embeddings, local
    /// heuristics for enrichment, and search that uses those embeddings when
    /// they are installed.
    ///
    /// Resolved on every read rather than cached in a `let`. Encoders can be
    /// installed or removed from Settings while the app is running, and a stack
    /// decided once at launch would keep reporting the state the app started
    /// in — embeddings still off after installing them, or still on after
    /// removing them. The three services below are empty structs; building them
    /// again costs nothing worth caching.
    static var local: AIServices {
        let embeddings: (any EmbeddingService)? = MobileCLIPEmbeddingService.isInstalled()
            ? MobileCLIPEmbeddingService.shared
            : nil

        return AIServices(
            embeddings: embeddings,
            ocr: VisionOCRService(),
            enrichment: LocalEnrichmentService(),
            // Derived from the same answer rather than decided separately: the
            // semantic half is only meaningful when there is a text tower to
            // encode the query with, and a shelf whose vectors were written by
            // an encoder that has since been removed falls back to keyword
            // search on its own — which is what Cove did before.
            search: embeddings.map { SemanticSearchService(embeddings: $0) }
                ?? KeywordSearchService()
        )
    }

    static var current: AIServices { .local }

    /// Version tag persisted with every stored embedding so a model swap can
    /// detect and re-index stale vectors. Vectors from two different encoders
    /// are not comparable, so this is what keeps a mixed shelf from quietly
    /// returning nonsense.
    static var currentEmbeddingModelVersion: String {
        MobileCLIPEmbeddingService.isInstalled()
            ? MobileCLIPModelDescriptor.current.id
            : "none"
    }
}

private struct AIServicesEnvironmentKey: EnvironmentKey {
    static let defaultValue = AIServices.local
}

extension EnvironmentValues {
    var aiServices: AIServices {
        get { self[AIServicesEnvironmentKey.self] }
        set { self[AIServicesEnvironmentKey.self] = newValue }
    }
}

import AppKit
import SwiftUI

/// The on-device stack, as protocols.
///
/// OCR is live and runs through Vision. `embeddings` is still `nil`, and
/// `enrichment` derives what it can from the text a capture already carries.
/// Everything that needs a model goes through these protocols so switching one
/// on is a change to `AIServices.current` and nothing else.
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

struct AIServices: Sendable {
    /// `nil` until the MobileCLIP-style encoders land. The pipeline skips the
    /// embedding steps rather than faking vectors — a random vector would be
    /// indistinguishable from a real one downstream and would quietly poison
    /// every similarity the search eventually runs.
    let embeddings: (any EmbeddingService)?
    let ocr: (any OCRService)?
    let enrichment: any EnrichmentService
    let search: any SearchService

    /// What Cove runs today: Vision OCR, local heuristics, keyword search.
    static let local: AIServices = {
        AIServices(
            embeddings: nil,
            ocr: VisionOCRService(),
            enrichment: LocalEnrichmentService(),
            search: KeywordSearchService()
        )
    }()

    static var current: AIServices { .local }

    /// Version tag persisted with every stored embedding so a future model swap
    /// can detect and re-index stale vectors. Nothing writes vectors yet.
    static var currentEmbeddingModelVersion: String { "none" }
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

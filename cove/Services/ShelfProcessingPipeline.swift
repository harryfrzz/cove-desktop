import AppKit
import Foundation
import SwiftData

/// Where an item is in the pipeline, for the island's activity strip.
enum ShelfProcessingPhase: String, Sendable {
    case queued
    case readingText
    case understanding
    case makingSearchable
    case done
    case failed

    var label: String {
        switch self {
        case .queued: "Queued"
        case .readingText: "Reading text"
        case .understanding: "Understanding"
        case .makingSearchable: "Making searchable"
        case .done: "Saved to Cove"
        case .failed: "Couldn’t process"
        }
    }
}

/// Value snapshot of an item in flight. Model objects never leave the
/// processor's actor, so this is what the island is told about.
struct ShelfActivitySnapshot: Sendable, Identifiable, Equatable {
    let id: UUID
    let title: String
    let kindLabel: String
    var phase: ShelfProcessingPhase
    var progress: Double
}

/// Background ingestion pipeline. Owns its own SwiftData context via
/// `@ModelActor`, so all model reads and writes happen on this actor and only
/// value snapshots cross to the main actor.
///
/// Order per item: decode image → OCR → enrich → embed image → embed enriched
/// text → `.ready`. Progress is persisted after every step, so a kill mid-item
/// loses at most one step, and a failed enrichment still leaves an item that is
/// stored and findable.
///
/// The queue is serial on purpose: several model invocations at once cause
/// memory spikes and thermal throttling, not speedups. OCR and embeddings are
/// absent this phase (`AIServices.current` returns `nil` for both) and their
/// steps are skipped rather than faked.
@ModelActor
actor ShelfProcessor {
    static let shared = ShelfProcessor(modelContainer: CoveStore.shared)

    private var queue: [UUID] = []
    private var reembedQueue: [UUID] = []
    private var isDraining = false

    // MARK: - Public API

    /// Queue an item for background processing and return immediately.
    func enqueue(itemID: UUID) {
        guard !queue.contains(itemID) else { return }
        queue.append(itemID)
        drainSoon()
    }

    /// Reset an item that ended `.failed` and run it again.
    func retry(itemID: UUID) {
        guard let item = fetchItem(itemID) else { return }
        item.processingState = .queued
        item.failureMessage = nil
        saveQuietly()
        enqueue(itemID: itemID)
    }

    /// Put every finished item back through the encoders, without redoing OCR
    /// or enrichment. A no-op until there are encoders; the plumbing is here so
    /// that turning them on is one call from Settings.
    @discardableResult
    func reindexEmbeddings() -> Int {
        guard AIServices.current.embeddings != nil else { return 0 }

        let ready = (try? modelContext.fetch(FetchDescriptor<ShelfItem>()))?.filter {
            $0.processingState == .ready
        } ?? []

        var queued = 0
        for item in ready where !reembedQueue.contains(item.id) {
            reembedQueue.append(item.id)
            queued += 1
        }
        drainSoon()
        return queued
    }

    var isBusy: Bool {
        isDraining || !queue.isEmpty || !reembedQueue.isEmpty
    }

    /// Startup reconciliation: anything left `.processing` by a kill goes back
    /// to `.queued` and is re-run; `.ready` items embedded with an older model
    /// version are re-embedded so vectors stay comparable.
    func reconcileAtLaunch() {
        let stuck = (try? modelContext.fetch(FetchDescriptor<ShelfItem>()))?.filter {
            $0.processingState == .processing || $0.processingState == .queued
        } ?? []
        for item in stuck {
            item.processingState = .queued
            queue.append(item.id)
        }
        saveQuietly()

        if AIServices.current.embeddings != nil {
            let currentVersion = AIServices.currentEmbeddingModelVersion
            let stale = (try? modelContext.fetch(FetchDescriptor<ShelfItem>()))?.filter {
                $0.processingState == .ready && $0.embeddingModelVersion != currentVersion
            } ?? []
            reembedQueue.append(contentsOf: stale.map(\.id))
        }

        drainSoon()
    }

    // MARK: - Queue

    private func drainSoon() {
        guard !isDraining else { return }
        isDraining = true
        Task { await drain() }
    }

    private func drain() async {
        while let next = queue.first {
            queue.removeFirst()
            await process(itemID: next)
        }
        while let next = reembedQueue.first {
            reembedQueue.removeFirst()
            await reembed(itemID: next)
        }
        isDraining = false
    }

    // MARK: - Processing

    private func process(itemID: UUID) async {
        guard let item = fetchItem(itemID) else { return }
        guard item.processingState == .queued || item.processingState == .processing else {
            return
        }

        var snapshot = ShelfActivitySnapshot(
            id: item.id,
            title: item.title,
            kindLabel: item.kind.label,
            phase: .queued,
            progress: 0
        )
        item.processingState = .processing
        item.failureMessage = nil
        saveQuietly()
        await report(snapshot, phase: .readingText, progress: 0.2, into: &snapshot)

        let services = AIServices.current
        var hardFailure: String?

        // 1. Decode once; OCR and the image encoder share the bitmap.
        var decodedImage: NSImage?
        if let imageData = item.imageData {
            decodedImage = NSImage(data: imageData)
            if decodedImage == nil {
                hardFailure = "The saved image data could not be decoded."
            }
        }

        // 2. OCR (images only). Empty text is a normal outcome, not an error.
        if let image = decodedImage, let ocr = services.ocr {
            do {
                let text = try await ocr.recognizeText(in: image)
                item.extractedText = text.isEmpty ? nil : text
                saveQuietly()
            } catch {
                hardFailure = "Text recognition failed: \(error.localizedDescription)"
            }
        }

        // 3. Enrichment. A failure here degrades: the item stays stored and
        // findable, just without tags.
        await report(snapshot, phase: .understanding, progress: 0.55, into: &snapshot)
        let sourceText = enrichmentSource(for: item)
        if !sourceText.isEmpty {
            do {
                let enrichment = try await services.enrichment.enrich(
                    text: sourceText,
                    kind: item.kind
                )
                item.summary = enrichment.summary
                item.tags = enrichment.tags
                // Never overwrite typed fields that are already there with a
                // thinner reading of the same item.
                if item.extraction == nil {
                    item.extraction = enrichment.extraction
                }
                saveQuietly()
            } catch {
                if item.tags.isEmpty {
                    item.tags = [item.kind.label.lowercased()]
                }
                saveQuietly()
            }
        }

        // 4. Embeddings, when there are any. Failure is not fatal — keyword
        // search still works without them.
        await report(snapshot, phase: .makingSearchable, progress: 0.8, into: &snapshot)
        if let embeddings = services.embeddings {
            do {
                if let image = decodedImage {
                    let vector = try await embeddings.embed(image: image)
                    item.embedding = vector
                    item.embeddingDimension = vector.count
                    item.embeddingModelVersion = AIServices.currentEmbeddingModelVersion
                    saveQuietly()
                }
                let enrichedText = item.searchableText
                if !enrichedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let vector = try await embeddings.embed(text: enrichedText)
                    item.textEmbedding = vector
                    item.embeddingDimension = vector.count
                    item.embeddingModelVersion = AIServices.currentEmbeddingModelVersion
                    saveQuietly()
                }
            } catch {
                // Whatever was persisted so far stays searchable.
            }
        }

        // 5. Terminal state. Only an unusable image is a hard failure; any
        // partial result is kept and shown.
        if let hardFailure, item.extractedText == nil, item.imageData == nil {
            item.processingState = .failed
            item.failureMessage = hardFailure
            saveQuietly()
            await report(snapshot, phase: .failed, progress: 1, into: &snapshot)
        } else {
            item.processingState = .ready
            item.failureMessage = nil
            saveQuietly()
            await report(snapshot, phase: .done, progress: 1, into: &snapshot)
        }
    }

    /// Refresh embeddings only (model-version migration), without redoing OCR
    /// or enrichment.
    private func reembed(itemID: UUID) async {
        guard let item = fetchItem(itemID), let embeddings = AIServices.current.embeddings else {
            return
        }
        do {
            if let imageData = item.imageData, let image = NSImage(data: imageData) {
                let vector = try await embeddings.embed(image: image)
                item.embedding = vector
                item.embeddingDimension = vector.count
            }
            let enrichedText = item.searchableText
            if !enrichedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let vector = try await embeddings.embed(text: enrichedText)
                item.textEmbedding = vector
                item.embeddingDimension = vector.count
            }
            item.embeddingModelVersion = AIServices.currentEmbeddingModelVersion
            saveQuietly()
        } catch {
            // Stale vectors stay flagged by their version and are skipped in
            // search; the next launch retries.
        }
    }

    private func report(
        _ snapshot: ShelfActivitySnapshot,
        phase: ShelfProcessingPhase,
        progress: Double,
        into stored: inout ShelfActivitySnapshot
    ) async {
        var updated = snapshot
        updated.phase = phase
        updated.progress = progress
        stored = updated
        await NotchActivityCenter.shared.update(updated)
    }

    private func enrichmentSource(for item: ShelfItem) -> String {
        switch item.kind {
        case .screenshot, .image, .file:
            [item.title, item.userNote, item.extractedText]
                .compactMap { $0 }
                .joined(separator: "\n")
        case .link:
            [item.title, item.userNote, item.linkTitle, item.linkHost, item.linkURL?.absoluteString]
                .compactMap { $0 }
                .joined(separator: "\n")
        case .text:
            [item.title, item.userNote]
                .compactMap { $0 }
                .joined(separator: "\n")
        }
    }

    private func fetchItem(_ id: UUID) -> ShelfItem? {
        var descriptor = FetchDescriptor<ShelfItem>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first
    }

    private func saveQuietly() {
        do {
            try modelContext.save()
        } catch {
            // A failed checkpoint save leaves the previous checkpoint intact;
            // launch reconciliation re-runs anything incomplete.
        }
    }
}

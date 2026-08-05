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

    /// One word each. These are read in the sliver beside the camera housing,
    /// where anything longer arrives clipped.
    var label: String {
        switch self {
        case .queued: "Queued"
        case .readingText: "Reading"
        case .understanding: "Sorting"
        case .makingSearchable: "Indexing"
        case .done: "Saved"
        case .failed: "Failed"
        }
    }
}

/// How far the current encoders have got through the shelf. Counts only, so it
/// crosses out of the processor's actor freely.
nonisolated struct EmbeddingCoverage: Sendable {
    var totalItems = 0
    var totalImages = 0
    /// Images holding a vector from the *current* model. A vector from an older
    /// one is not counted: it cannot be compared against anything new.
    var embeddedImages = 0
    var embeddedTexts = 0
    /// Images whose album was decided by MobileCLIP rather than the fallback.
    var sortedByCLIP = 0
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
/// Order per item: decode image → OCR → embed image → sort into an album →
/// enrich → embed enriched text → `.ready`. Progress is persisted after every
/// step, so a kill mid-item loses at most one step, and a failed enrichment
/// still leaves an item that is stored and findable.
///
/// The image embedding comes before the album step because the album step is
/// built on it: with MobileCLIP installed, sorting a capture is a comparison
/// between the vector already computed here and the album prototypes, so the
/// image tower runs exactly once per capture.
///
/// The queue is serial on purpose: several model invocations at once cause
/// memory spikes and thermal throttling, not speedups. When an encoder is
/// missing its step is skipped rather than faked.
@ModelActor
actor ShelfProcessor {
    static let shared = ShelfProcessor(modelContainer: CoveStore.shared)

    /// One entry of work, and whether the island is allowed to talk about it.
    ///
    /// Housekeeping and captures run through the same stages but are not the
    /// same event to the user. A drop is something they just did and want
    /// confirmed; re-running the shelf at launch is maintenance they never
    /// asked for, and announcing it means the island says "Saved" about items
    /// that were saved days ago.
    private struct QueuedItem {
        let id: UUID
        /// True for housekeeping: process normally, report nothing.
        let isSilent: Bool
    }

    private var queue: [QueuedItem] = []
    private var reembedQueue: [UUID] = []
    private var isDraining = false

    // MARK: - Public API

    /// Queue an item for background processing and return immediately.
    func enqueue(itemID: UUID) {
        // A capture the user just made outranks a silent requeue of the same
        // item: promote it rather than letting the housekeeping entry swallow
        // the one drop that deserved a confirmation.
        if let index = queue.firstIndex(where: { $0.id == itemID }) {
            queue[index] = QueuedItem(id: itemID, isSilent: false)
        } else {
            queue.append(QueuedItem(id: itemID, isSilent: false))
        }
        drainSoon()
    }

    /// Queue without telling the island. Used by the launch sweep and by
    /// Refresh, both of which report progress somewhere the user is already
    /// looking — or not at all.
    private func enqueueSilently(_ itemID: UUID) {
        guard !queue.contains(where: { $0.id == itemID }) else { return }
        queue.append(QueuedItem(id: itemID, isSilent: true))
    }

    /// Reset an item that ended `.failed` and run it again.
    func retry(itemID: UUID) {
        guard let item = fetchItem(itemID) else { return }
        item.processingState = .queued
        item.failureMessage = nil
        saveQuietly()
        enqueue(itemID: itemID)
    }

    /// Refresh every stored capture through the current local stack. This is
    /// intentionally broader than re-indexing: OCR, tags, and any future
    /// embeddings stay derived from the same current source instead of drifting
    /// apart after the services evolve.
    @discardableResult
    func refreshAll() -> Int {
        let items = (try? modelContext.fetch(FetchDescriptor<ShelfItem>())) ?? []
        var refreshed = 0

        for item in items {
            // A capture already being processed will finish its current pass;
            // resetting it mid-flight would make its terminal checkpoint race
            // the refresh state. Everything else is safely requeued.
            guard item.processingState != .processing else { continue }

            item.processingState = .queued
            item.failureMessage = nil
            enqueueSilently(item.id)
            refreshed += 1
        }

        saveQuietly()
        drainSoon()
        return refreshed
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

    /// How much of the shelf the current encoders have actually covered.
    ///
    /// Settings shows this because "embeddings are on" is not the same claim as
    /// "your shelf is embedded": a model installed today has not touched
    /// anything captured before it, and those items stay invisible to any
    /// similarity search until they are re-indexed.
    func embeddingCoverage() -> EmbeddingCoverage {
        let items = (try? modelContext.fetch(FetchDescriptor<ShelfItem>())) ?? []
        let currentVersion = AIServices.currentEmbeddingModelVersion
        let images = items.filter { $0.imageData != nil && $0.kind != .link }

        return EmbeddingCoverage(
            totalItems: items.count,
            totalImages: images.count,
            embeddedImages: images.filter {
                $0.embeddingData != nil && $0.embeddingModelVersion == currentVersion
            }.count,
            embeddedTexts: items.filter {
                $0.textEmbeddingData != nil && $0.embeddingModelVersion == currentVersion
            }.count,
            sortedByCLIP: images.filter {
                $0.extraction?.visualClassifier?.hasPrefix("clip.") ?? false
            }.count
        )
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
            enqueueSilently(item.id)
        }
        saveQuietly()

        // Captures sorted by a weaker classifier than the one available now.
        // That covers images saved before albums existed at all, and images
        // sorted by the Vision fallback on a launch where MobileCLIP's encoders
        // were missing. One normal pass re-sorts them without asking the user to
        // touch every older item.
        let unclassifiedImages = (try? modelContext.fetch(FetchDescriptor<ShelfItem>()))?.filter {
            $0.processingState == .ready
                && $0.imageData != nil
                && ShelfImageCategorizer.needsReclassification($0.extraction?.visualClassifier)
        } ?? []
        for item in unclassifiedImages {
            item.processingState = .queued
            enqueueSilently(item.id)
        }
        saveQuietly()

        // Captures that have pixels but no card-sized copy of them: everything
        // saved before `thumbnailData` existed. Until this has run, those items
        // draw no stamp on the widget at all — the widget will not read the
        // full-size image to cover for a missing thumbnail, because doing that
        // is the bug the thumbnail exists to fix.
        let unthumbnailed = (try? modelContext.fetch(FetchDescriptor<ShelfItem>()))?.filter {
            $0.processingState == .ready && $0.imageData != nil && $0.thumbnailData == nil
        } ?? []
        for item in unthumbnailed {
            item.processingState = .queued
            enqueueSilently(item.id)
        }
        saveQuietly()

        if AIServices.current.embeddings != nil {
            let currentVersion = AIServices.currentEmbeddingModelVersion
            let stale = (try? modelContext.fetch(FetchDescriptor<ShelfItem>()))?.filter {
                $0.processingState == .ready && $0.embeddingModelVersion != currentVersion
            } ?? []
            // Anything already queued above gets a full pass, which embeds it
            // anyway — adding it here too would run both towers over it twice.
            reembedQueue.append(
                contentsOf: stale.map(\.id).filter { id in
                    !queue.contains { $0.id == id }
                }
            )
        }

        drainSoon()
    }

    // MARK: - Queue

    private func drainSoon() {
        guard !isDraining else { return }
        isDraining = true
        Task { await drain() }
    }

    /// Works both queues until both are empty, captures first.
    ///
    /// The order is a priority, not a phase, and that distinction was a bug.
    /// Draining `queue` to exhaustion and *then* `reembedQueue` meant anything
    /// enqueued during the re-embed pass was left sitting: `drainSoon` sees
    /// `isDraining` and returns, the re-embed loop never looks at `queue` again,
    /// and the drain ends with work still in it. The window is not small —
    /// installing the encoders puts the whole shelf into `reembedQueue`, which
    /// is minutes — and a capture dropped inside it stayed `.queued` with no
    /// OCR, no vector and no activity on the island until the next launch.
    ///
    /// Re-checking `queue` on every iteration also gives a capture the user just
    /// made priority over housekeeping, which is the right way round: one is
    /// something they are waiting for, the other is maintenance nobody asked
    /// for.
    private func drain() async {
        while !queue.isEmpty || !reembedQueue.isEmpty {
            if !queue.isEmpty {
                let next = queue.removeFirst()
                await process(itemID: next.id, isSilent: next.isSilent)
                continue
            }
            await reembed(itemID: reembedQueue.removeFirst())
        }
        isDraining = false
    }

    // MARK: - Processing

    private func process(itemID: UUID, isSilent: Bool) async {
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
        await report(snapshot, phase: .readingText, progress: 0.2, into: &snapshot, isSilent: isSilent)

        let services = AIServices.current
        var hardFailure: String?

        // 0. A link describes itself. Everything downstream reads better for it:
        //    the card gets a cover, and enrichment sees the real page title
        //    instead of the last path component.
        await fetchLinkPreviewIfNeeded(for: item)

        // The stages below are about pixels the user captured. A link's cover is
        // the site's artwork, not the user's — running OCR over it would fill
        // the item with the page's own chrome, and classifying it would file the
        // link into an image album, where it isn't a link any more.
        let isVisualCapture = item.kind != .link

        // 1. Decode once; OCR, the image encoder and the thumbnail share the
        //    bitmap.
        var decodedImage: NSImage?
        if isVisualCapture, let imageData = item.imageData {
            decodedImage = NSImage(data: imageData)
            if decodedImage == nil {
                hardFailure = "The saved image data could not be decoded."
            }
        }

        // 1a. The card-sized copy, for captures saved before it existed.
        //
        // Here rather than in its own sweep because the expensive part is the
        // decode, and this pass has already paid for it. `refreshAll` and the
        // launch reconciliation both run every item through here, so the
        // backfill is something the shelf does to itself rather than a
        // migration anyone has to trigger.
        // Deliberately not behind `isVisualCapture`: a link's cover is not the
        // user's pixels and has no business being OCR'd or embedded, but it is
        // still what its card draws, so it still needs the small copy. That is
        // the one case `decodedImage` is nil and there is an image anyway.
        if item.thumbnailData == nil, let imageData = item.imageData {
            item.thumbnailData = (decodedImage ?? NSImage(data: imageData))?.thumbnailJPEGData()
            saveQuietly()
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

        // 3. The image's own vector, in MobileCLIP's shared image/text space.
        // Computed here rather than after enrichment because the album step
        // below is a comparison against it — running the tower once is the whole
        // reason for this ordering.
        // "Sorting" rather than "Indexing": what the island reports should be
        // what the user would call it, and this vector exists first of all to
        // choose the album below. Indexing is the last step, over the enriched
        // text.
        await report(snapshot, phase: .understanding, progress: 0.45, into: &snapshot, isSilent: isSilent)
        var imageVector: [Float]?
        if let image = decodedImage, let embeddings = services.embeddings {
            do {
                let vector = try await embeddings.embed(image: image)
                imageVector = vector
                item.embedding = vector
                item.embeddingDimension = vector.count
                item.embeddingModelVersion = AIServices.currentEmbeddingModelVersion
                saveQuietly()
            } catch {
                // Keyword search still works without it; the album step falls
                // back to Vision on its own.
            }
        }

        // 4. The album. Separate from OCR: the classifier reads the pixels
        // themselves, while OCR supplies helpful context for screenshots such as
        // a boarding pass or an event page.
        var visualCategory: ShelfImageCategory?
        var visualClassifierID: String?
        if let image = decodedImage {
            let sorted = await ShelfImageCategorizer.category(
                for: image,
                embedding: imageVector,
                recognizedText: [item.title, item.userNote, item.extractedText]
                    .compactMap { $0 }
                    .joined(separator: "\n")
            )
            visualCategory = sorted.category
            visualClassifierID = sorted.classifierID
        }

        // 5. Enrichment. A failure here degrades: the item stays stored and
        // findable, just without tags.
        await report(snapshot, phase: .understanding, progress: 0.55, into: &snapshot, isSilent: isSilent)
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

        if let visualCategory {
            // Keep the structured category and fields untouched — they power
            // Wallet — and add the visual album label alongside them.
            var extraction = item.extraction ?? ItemExtraction(category: "image")
            extraction.visualCategory = visualCategory.rawValue
            extraction.visualCategoryVersion = ImageSemanticClassifier.categoryVersion
            extraction.visualClassifier = visualClassifierID
            item.extraction = extraction

            if visualCategory != .other,
               !item.tags.contains(where: { $0.caseInsensitiveCompare(visualCategory.rawValue) == .orderedSame }) {
                item.tags.append(visualCategory.rawValue)
            }
            saveQuietly()
        }

        // 6. The text vector, over everything enrichment has now filled in. It
        // is deliberately last: embedding `searchableText` before the tags and
        // summary exist would index a thinner item than the one that gets saved.
        await report(snapshot, phase: .makingSearchable, progress: 0.85, into: &snapshot, isSilent: isSilent)
        if let embeddings = services.embeddings {
            do {
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

        // 7. Terminal state. Only an unusable image is a hard failure; any
        // partial result is kept and shown.
        if let hardFailure, item.extractedText == nil, item.imageData == nil {
            item.processingState = .failed
            item.failureMessage = hardFailure
            saveQuietly()
            await report(snapshot, phase: .failed, progress: 1, into: &snapshot, isSilent: isSilent)
        } else {
            item.processingState = .ready
            item.failureMessage = nil
            saveQuietly()
            await report(snapshot, phase: .done, progress: 1, into: &snapshot, isSilent: isSilent)
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

    /// Advances the item's phase, and tells the island unless this pass is
    /// housekeeping. The snapshot is still updated either way, so the stages
    /// below read the same in both modes.
    private func report(
        _ snapshot: ShelfActivitySnapshot,
        phase: ShelfProcessingPhase,
        progress: Double,
        into stored: inout ShelfActivitySnapshot,
        isSilent: Bool
    ) async {
        var updated = snapshot
        updated.phase = phase
        updated.progress = progress
        stored = updated
        guard !isSilent else { return }
        await NotchActivityCenter.shared.update(updated)
    }

    /// Reads a link's own title and cover, once.
    ///
    /// `linkPreviewFetchedAt` is stamped whether or not anything came back:
    /// `refreshAll` requeues the entire shelf, and without that stamp every
    /// refresh would re-hit the network for every link ever saved — including
    /// the dead ones, which are the slowest.
    private func fetchLinkPreviewIfNeeded(for item: ShelfItem) async {
        guard item.kind == .link,
              item.linkPreviewFetchedAt == nil,
              let url = item.linkURL,
              LinkPreviewService.isEnabled else {
            return
        }

        let preview = await LinkPreviewService.preview(for: url)

        item.linkPreviewFetchedAt = .now
        if let imageData = preview.imageData {
            item.imageData = imageData
            // A cover arriving here is the one image path that does not come
            // through `CaptureIngest`, so it is also the one that would
            // otherwise leave a link with a full-size image and no thumbnail —
            // which is exactly the case the widget then pays for.
            item.thumbnailData = NSImage(data: imageData)?.thumbnailJPEGData()
        }
        if let title = preview.title {
            item.linkTitle = title
            // The captured title is `url.host()`; a real one is strictly better
            // to read on a card and to search against.
            item.title = title
        }
        saveQuietly()
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

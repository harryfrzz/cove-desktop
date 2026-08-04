import Foundation
import SwiftData

nonisolated enum ShelfItemKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case screenshot
    case image
    case link
    case text
    /// A file that isn't an image: kept as a pointer plus whatever metadata the
    /// drop carried. The bytes stay where the user put them.
    case file

    var id: String { rawValue }

    var label: String {
        switch self {
        case .screenshot: "Screenshot"
        case .image: "Image"
        case .link: "Link"
        case .text: "Note"
        case .file: "File"
        }
    }

    var systemImage: String {
        switch self {
        case .screenshot: "rectangle.inset.filled"
        case .image: "photo"
        case .link: "link"
        case .text: "note.text"
        case .file: "doc"
        }
    }
}

nonisolated enum ShelfProcessingState: String, Codable, CaseIterable, Sendable {
    case queued
    case processing
    case ready
    case failed
}

@Model
final class ShelfItem {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var kindRawValue: String
    var title: String
    var userNote: String?
    @Attribute(.externalStorage) var imageData: Data?
    /// A small copy of `imageData`, for anything that draws the capture at
    /// card size rather than opening it.
    ///
    /// This exists because of the widget. A timeline is built in an extension
    /// with a hard memory ceiling, and the rack shows up to eight captures at
    /// once; reading eight 2048px JPEGs and decoding them to draw a 26pt stamp
    /// is how that extension gets killed mid-render, which on the desktop looks
    /// like the widget going blank for no reason. Nothing on a card needs more
    /// than this, and at ~320px it is roughly a fiftieth of the pixels.
    ///
    /// Separate attribute rather than a derived cache: `.externalStorage` blobs
    /// are only faulted in when the property is actually read, so a fetch that
    /// touches `thumbnailData` and never `imageData` never pays for the
    /// original at all. That is the whole saving, and it is lost the moment
    /// anything on that path reads `imageData` for any reason.
    ///
    /// Optional forever: it is nil for every capture saved before this existed,
    /// until the pipeline backfills it, and nil for items that never had pixels.
    @Attribute(.externalStorage) var thumbnailData: Data?
    var linkURL: URL?
    var linkTitle: String?
    var linkHost: String?
    var extractedText: String?
    var summary: String?
    var tags: [String]
    var embeddingData: Data?
    var textEmbeddingData: Data?
    var embeddingDimension: Int?
    var embeddingModelVersion: String?
    var extractionJSON: String?
    var failureMessage: String?
    /// Stable identity of whatever the item was captured from — a file path, a
    /// URL — so the same drop twice doesn't produce two copies.
    var sourceIdentifier: String?
    /// Which app the capture came from, when the drag told us. Shown on the
    /// card; also the cheapest useful signal a desktop capture carries.
    var sourceApp: String?
    /// Manually pinned to the Wallet page. Receipts and tickets also land there
    /// on their own once a real extraction backs the category up.
    var isInWallet: Bool = false
    /// When Cove last tried to read a link's own title and cover image. Set on
    /// failure too: one attempt per link is the contract, so a dead host isn't
    /// re-fetched on every refresh. Nil for everything that isn't a link.
    var linkPreviewFetchedAt: Date?
    var processingStateRawValue: String

    var kind: ShelfItemKind {
        get { ShelfItemKind(rawValue: kindRawValue) ?? .text }
        set { kindRawValue = newValue.rawValue }
    }

    var processingState: ShelfProcessingState {
        get { ShelfProcessingState(rawValue: processingStateRawValue) ?? .queued }
        set { processingStateRawValue = newValue.rawValue }
    }

    /// Image (or primary) embedding as a compact Float32 blob. Unused until the
    /// embedding stack lands; the storage shape is fixed now so the migration
    /// is a re-index rather than a schema change.
    var embedding: [Float]? {
        get { Self.floats(from: embeddingData) }
        set { embeddingData = Self.blob(from: newValue) }
    }

    /// Embedding of the enriched text (title, note, extracted text, summary).
    var textEmbedding: [Float]? {
        get { Self.floats(from: textEmbeddingData) }
        set { textEmbeddingData = Self.blob(from: newValue) }
    }

    static func floats(from data: Data?) -> [Float]? {
        guard let data, !data.isEmpty, data.count % MemoryLayout<Float32>.size == 0 else {
            return nil
        }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float32.self)) }
    }

    static func blob(from floats: [Float]?) -> Data? {
        guard let floats else { return nil }
        return floats.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    var searchableText: String {
        [
            title,
            userNote,
            linkTitle,
            linkHost,
            extractedText,
            summary,
            sourceApp,
            // The host alone loses which video, which repo, which article. For
            // a link the URL is often the only Latin text the item has — a
            // Korean video's title is Korean, and its address is not.
            linkURL?.absoluteString,
            tags.joined(separator: " ")
        ]
        .compactMap { $0 }
        .joined(separator: "\n")
    }

    init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        kind: ShelfItemKind,
        title: String,
        userNote: String? = nil,
        imageData: Data? = nil,
        thumbnailData: Data? = nil,
        linkURL: URL? = nil,
        linkTitle: String? = nil,
        linkHost: String? = nil,
        extractedText: String? = nil,
        summary: String? = nil,
        tags: [String] = [],
        sourceIdentifier: String? = nil,
        sourceApp: String? = nil,
        processingState: ShelfProcessingState = .queued
    ) {
        self.id = id
        self.createdAt = createdAt
        self.kindRawValue = kind.rawValue
        self.title = title
        self.userNote = userNote
        self.imageData = imageData
        self.thumbnailData = thumbnailData
        self.linkURL = linkURL
        self.linkTitle = linkTitle
        self.linkHost = linkHost
        self.extractedText = extractedText
        self.summary = summary
        self.tags = tags
        self.sourceIdentifier = sourceIdentifier
        self.sourceApp = sourceApp
        self.processingStateRawValue = processingState.rawValue
    }
}

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

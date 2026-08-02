import AppKit
import Foundation
import LinkPresentation

/// What a saved link looks like, according to the page itself.
///
/// Deliberately carries nothing but `String` and `Data`: it crosses from the
/// main actor into `ShelfProcessor`, and an `NSImage` is neither `Sendable` nor
/// safe to touch off the main thread. The bitmap is already downscaled by the
/// time it becomes one of these.
struct LinkPreview: Sendable {
    var title: String?
    var imageData: Data?

    var isEmpty: Bool { title == nil && imageData == nil }
}

/// Fetches the title and cover image for a link.
///
/// This is the one place in Cove that talks to the network. Everything else —
/// OCR, classification, enrichment, search — runs on-device, and the app is
/// sandboxed with only `com.apple.security.network.client` added for this. The
/// user can switch it off entirely; see `isEnabled`.
enum LinkPreviewService {
    /// Defaults key backing the opt-out. Absent means on, so an existing
    /// install picks previews up without needing to be told about them.
    nonisolated static let defaultsKey = "cove.fetchLinkPreviews"

    /// Long enough for a slow site to answer, short enough that one dead host
    /// doesn't hold up the shelf. The processing queue is serial, so this is a
    /// worst-case stall for every item behind it.
    private static let timeout: TimeInterval = 10

    nonisolated static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
    }

    nonisolated static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: defaultsKey)
    }

    /// Best effort by design: a page that won't load, has no cover, or simply
    /// isn't reachable yields an empty preview rather than an error the caller
    /// has to reason about. Failing to describe a link is not a failure to save
    /// one.
    static func preview(for url: URL) async -> LinkPreview {
        guard let metadata = await metadata(for: url) else { return LinkPreview() }

        let title = metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines)

        return LinkPreview(
            title: (title?.isEmpty == false) ? title : nil,
            imageData: await coverData(from: metadata)
        )
    }

    private static func metadata(for url: URL) async -> LPLinkMetadata? {
        let provider = LPMetadataProvider()
        provider.timeout = timeout

        return await withCheckedContinuation { continuation in
            // `LPMetadataProvider` promises one call, but a resumed continuation
            // is a crash rather than a warning, so the flag makes that a fact
            // rather than a hope.
            let box = ResumeGuard()

            provider.startFetchingMetadata(for: url) { metadata, _ in
                guard box.claim() else { return }
                continuation.resume(returning: metadata)
            }
        }
    }

    /// The page's own cover if it has one, else its icon — a favicon-sized card
    /// still reads as "this site" far better than a generated placeholder does.
    private static func coverData(from metadata: LPLinkMetadata) async -> Data? {
        for provider in [metadata.imageProvider, metadata.iconProvider].compactMap({ $0 }) {
            if let data = await imageData(from: provider) {
                return data
            }
        }
        return nil
    }

    private static func imageData(from provider: NSItemProvider) async -> Data? {
        guard provider.canLoadObject(ofClass: NSImage.self) else { return nil }

        let image: NSImage? = await withCheckedContinuation { continuation in
            let box = ResumeGuard()

            provider.loadObject(ofClass: NSImage.self) { object, _ in
                guard box.claim() else { return }
                continuation.resume(returning: object as? NSImage)
            }
        }

        guard let image else { return nil }
        return await MainActor.run {
            image.downscaledJPEGData(maxPixelSize: CaptureIngest.maxPixelSize)
        }
    }
}

/// Lets exactly one caller through. Callbacks from `LinkPresentation` and
/// `NSItemProvider` are not contractually single-shot, and resuming a
/// continuation twice traps.
private final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}

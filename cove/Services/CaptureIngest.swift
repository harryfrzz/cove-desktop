import AppKit
import SwiftData
import UniformTypeIdentifiers

/// Everything that turns something the user handed Cove — a drag, the
/// clipboard, an open panel, a typed note — into shelf items.
///
/// One rule throughout: an image is *copied into the store* at capture time,
/// downscaled once. Cove is sandboxed, and the read access a drop grants ends
/// with the drag, so a path kept instead of bytes would be a shelf full of
/// items that render for one session and then can't be opened. Files that are
/// not images keep their URL knowingly, and say so on the card.
@MainActor
enum CaptureIngest {
    /// Longest side an imported bitmap is kept at. Enough for a Retina card and
    /// for OCR later; a 6000px camera original on a shelf costs 20 MB to store
    /// what a 2048px copy shows identically.
    static let maxPixelSize: CGFloat = 2048

    /// Pasteboard types Cove accepts. Registered by the island's container
    /// view, which is what a drag actually lands on.
    static let acceptedPasteboardTypes: [NSPasteboard.PasteboardType] = [
        .fileURL, .URL, .tiff, .png, .string, .rtf
    ]

    // MARK: - Drops and the clipboard

    /// Everything Cove can make out of one pasteboard, in preference order.
    ///
    /// Read straight off the pasteboard rather than through `NSItemProvider`:
    /// a drag delivers its pasteboard synchronously inside
    /// `performDragOperation`, which is exactly where a sandboxed app's read
    /// access to the dropped files is live. Going async through providers meant
    /// reading the bytes after that window had closed.
    ///
    /// URLs are checked before images because a file drag carries both, and the
    /// URL knows the file's name and kind while the bitmap alongside it does
    /// not.
    static func items(from pasteboard: NSPasteboard, sourceApp: String? = nil) -> [ShelfItem] {
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingContentsConformToTypes: [UTType.item.identifier]]
        ) as? [URL], !urls.isEmpty {
            return urls.compactMap { item(from: $0, sourceApp: sourceApp) }
        }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            return urls.compactMap { item(from: $0, sourceApp: sourceApp) }
        }
        if let images = pasteboard.readObjects(forClasses: [NSImage.self]) as? [NSImage],
           !images.isEmpty {
            return images.compactMap {
                item(from: $0, title: nil, sourceApp: sourceApp)
            }
        }
        if let strings = pasteboard.readObjects(forClasses: [NSString.self]) as? [String],
           !strings.isEmpty {
            return strings.compactMap { item(fromText: $0, sourceApp: sourceApp) }
        }
        return []
    }

    /// Stores everything on a dropped pasteboard. Returns how many landed, so
    /// the island can say so.
    @discardableResult
    static func ingest(
        pasteboard: NSPasteboard,
        into context: ModelContext,
        sourceApp: String? = nil
    ) -> Int {
        let built = items(from: pasteboard, sourceApp: sourceApp)
        for item in built {
            insert(item, into: context)
        }
        return built.count
    }

    /// Captures whatever is on the clipboard right now. `nil` when there is
    /// nothing Cove can hold.
    static func itemFromClipboard() -> ShelfItem? {
        items(from: NSPasteboard.general).first
    }

    // MARK: - Open panel

    /// Sandbox-friendly import: the panel is what grants Cove read access, and
    /// the bytes are copied in before that access lapses.
    static func importFromOpenPanel(into context: ModelContext) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.title = "Add to Cove"
        panel.prompt = "Add"

        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let item = item(from: url, sourceApp: nil) {
                insert(item, into: context)
            }
        }
    }

    // MARK: - Builders

    static func item(from url: URL, sourceApp: String?) -> ShelfItem? {
        guard url.isFileURL else {
            return ShelfItem(
                kind: .link,
                title: url.host() ?? url.absoluteString,
                linkURL: url,
                linkTitle: url.lastPathComponent.isEmpty ? nil : url.lastPathComponent,
                linkHost: url.host(),
                sourceIdentifier: url.absoluteString,
                sourceApp: sourceApp
            )
        }

        let name = url.deletingPathExtension().lastPathComponent
        let type = UTType(filenameExtension: url.pathExtension)

        if type?.conforms(to: .image) == true, let image = NSImage(contentsOf: url) {
            // A screenshot is an image that macOS named like one. Worth telling
            // apart: screenshots are cropped from their top edge on the wall,
            // because that's where their content starts.
            let isScreenshot = name.localizedCaseInsensitiveContains("screenshot")
                || name.localizedCaseInsensitiveContains("screen shot")
            return item(
                from: image,
                title: name,
                sourceApp: sourceApp,
                kind: isScreenshot ? .screenshot : .image,
                sourceIdentifier: url.path
            )
        }

        // Not an image: kept as a pointer. The bytes stay where they are, and
        // the detail panel opens them with the system handler.
        return ShelfItem(
            kind: .file,
            title: url.lastPathComponent,
            linkURL: url,
            linkTitle: type?.localizedDescription,
            sourceIdentifier: url.path,
            sourceApp: sourceApp
        )
    }

    static func item(
        from image: NSImage,
        title: String?,
        sourceApp: String?,
        kind: ShelfItemKind = .image,
        sourceIdentifier: String? = nil
    ) -> ShelfItem? {
        guard let data = image.downscaledJPEGData(maxPixelSize: maxPixelSize) else { return nil }
        return ShelfItem(
            kind: kind,
            title: title ?? "Image · \(Date.now.formatted(date: .abbreviated, time: .shortened))",
            imageData: data,
            sourceIdentifier: sourceIdentifier,
            sourceApp: sourceApp
        )
    }

    static func item(fromText text: String, sourceApp: String?) -> ShelfItem? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // A pasted link is a link, whatever pasteboard type it arrived under.
        if let url = URL(string: trimmed), url.scheme?.hasPrefix("http") == true {
            return item(from: url, sourceApp: sourceApp)
        }

        return ShelfItem(
            kind: .text,
            title: ChatThread.titleText(from: trimmed),
            userNote: trimmed,
            sourceApp: sourceApp
        )
    }

    // MARK: - Insertion

    /// Inserts and queues one item, skipping anything already captured from the
    /// same source. Dropping the same file twice should be a no-op, not a
    /// duplicate.
    static func insert(_ item: ShelfItem, into context: ModelContext) {
        if let source = item.sourceIdentifier, isDuplicate(source, in: context) {
            return
        }
        context.insert(item)
        try? context.save()

        let id = item.id
        Task {
            await ShelfProcessor.shared.enqueue(itemID: id)
        }
    }

    private static func isDuplicate(_ source: String, in context: ModelContext) -> Bool {
        var descriptor = FetchDescriptor<ShelfItem>(
            predicate: #Predicate { $0.sourceIdentifier == source }
        )
        descriptor.fetchLimit = 1
        return ((try? context.fetch(descriptor))?.isEmpty == false)
    }
}

extension NSImage {
    /// JPEG bytes with the longest side capped, drawn once through a bitmap
    /// context so the result is a real downscale rather than a large image with
    /// a small `size`.
    func downscaledJPEGData(maxPixelSize: CGFloat, compression: CGFloat = 0.86) -> Data? {
        guard let source = cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let width = CGFloat(source.width)
        let height = CGFloat(source.height)
        let scale = min(1, maxPixelSize / max(width, height))
        let targetWidth = Int((width * scale).rounded())
        let targetHeight = Int((height * scale).rounded())
        guard targetWidth > 0, targetHeight > 0 else { return nil }

        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: targetWidth,
            pixelsHigh: targetHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }
        representation.size = CGSize(width: targetWidth, height: targetHeight)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
        NSGraphicsContext.current?.imageInterpolation = .high
        NSImage(cgImage: source, size: CGSize(width: width, height: height))
            .draw(in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        NSGraphicsContext.restoreGraphicsState()

        return representation.representation(
            using: .jpeg,
            properties: [.compressionFactor: compression]
        )
    }
}

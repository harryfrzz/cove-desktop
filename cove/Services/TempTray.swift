import AppKit
import Observation
import UniformTypeIdentifiers

/// The holding shelf: things parked on the island to be carried somewhere else,
/// not saved to it.
///
/// This is the other half of a drop. Dragging a file out of one window and into
/// another means keeping both on screen at once; parking it here for the length
/// of the trip means neither has to stay open. Nothing is copied and nothing is
/// written — a parked file is a path plus the icon Finder would draw for it, and
/// the whole tray is gone when Cove quits. That is the promise the drop target
/// makes, so it has to be true: anything that survives a relaunch belongs on the
/// shelf proper, where the user put it deliberately.
@MainActor
@Observable
final class TempTray {
    static let shared = TempTray()

    struct Entry: Identifiable {
        let id = UUID()
        let name: String
        let icon: NSImage
        /// What the thing actually looks like, when it is something that looks
        /// like anything — a held screenshot shows the screenshot. Nil for a
        /// spreadsheet or a URL, which fall back to `icon`.
        ///
        /// Kept apart from `icon` rather than replacing it because they are
        /// different sizes of answer: the strip beside the notch has room for a
        /// glyph, and the tray page has room for a picture.
        var preview: NSImage?
        /// Rebuilt per drag, because a pasteboard item is consumed by the drag
        /// it is handed to.
        ///
        /// A pasteboard writer rather than an `NSItemProvider`: the drag is run
        /// through AppKit so the tray can be told whether anything took what it
        /// was offered, and AppKit's dragging items are written from these.
        let pasteboardItem: () -> any NSPasteboardWriting

        /// The same thing, as something the shelf can keep.
        ///
        /// Read back off the pasteboard writer rather than stored beside it: the
        /// writer *is* the entry's payload, and a second copy of it kept only for
        /// this would be a second thing to get wrong when the two disagree.
        /// `CaptureIngest` does the rest of the reading — including telling a
        /// file from a link, which it already has to do for every other way
        /// something reaches the shelf.
        func shelfItem() -> ShelfItem? {
            switch pasteboardItem() {
            case let url as NSURL:
                CaptureIngest.item(from: url as URL, sourceApp: nil)
            case let image as NSImage:
                CaptureIngest.item(from: image, title: name, sourceApp: nil)
            case let text as NSString:
                CaptureIngest.item(fromText: text as String, sourceApp: nil)
            default:
                nil
            }
        }

        /// Opens the held thing where it belongs — a link in the browser, a
        /// file in whatever owns it. Read off the pasteboard writer for the
        /// same reason `shelfItem()` is: the writer is the payload, and a
        /// second copy kept beside it is a second thing to get wrong.
        ///
        /// Text is deliberately not openable. There is nowhere for a held
        /// sentence to go, and opening TextEdit on it would be inventing a
        /// destination rather than honouring one.
        @discardableResult
        func open() -> Bool {
            guard case let url as NSURL = pasteboardItem(), let url = url as URL? else {
                return false
            }
            return NSWorkspace.shared.open(url)
        }
    }

    private(set) var entries: [Entry] = []

    private init() {}

    var isEmpty: Bool { entries.isEmpty }

    /// Whether a parked thing lets go of the tray once something else has taken
    /// it.
    ///
    /// Off unless asked for. The tray's promise is that it holds until you say
    /// otherwise, and dragging is not always saying otherwise — the same file
    /// often goes to two places, and a shelf that emptied itself after the first
    /// would make the second trip a trip back to Finder. So this is a choice,
    /// and the safe reading is the default.
    nonisolated static var clearsAfterDrag: Bool {
        UserDefaults.standard.bool(forKey: clearsAfterDragKey)
    }

    nonisolated static func setClearsAfterDrag(_ clears: Bool) {
        UserDefaults.standard.set(clears, forKey: clearsAfterDragKey)
    }

    nonisolated static let clearsAfterDragKey = "cove.clearHeldAfterDrag"

    /// Called when a drag out of the tray was accepted somewhere. Honours the
    /// setting, so the caller does not have to.
    func handOff(_ entry: Entry) {
        guard Self.clearsAfterDrag else { return }
        remove(entry)
    }

    /// The newest thing held, which is what the closed island shows. Newest
    /// rather than oldest: it is the one the user just put down.
    var latest: Entry? { entries.last }

    // MARK: - What the next question is about

    /// The one thing the next question is about, if the user has said so.
    ///
    /// Deliberately not a member of `entries`. Holding and asking are different
    /// answers to a drop — one says "carry this for me", the other says "look at
    /// this" — and folding the second into the first would put everything ever
    /// asked about onto the holding shelf, where it would sit until Cove quit.
    /// A thing already held can be attached too, and then it is both, which is
    /// the only case where one entry is in two places at once.
    ///
    /// Lives until the question is asked or the island closes. That is short on
    /// purpose: the alternative is a chip set on the island still silently
    /// attached to a question typed in the window an hour later.
    private(set) var attached: Entry?

    func attach(_ entry: Entry) {
        attached = entry
        announce()
    }

    func detach() {
        guard attached != nil else { return }
        attached = nil
        announce()
    }

    /// Attaches whatever was dropped on Ask Cove. Returns false when the
    /// pasteboard held nothing Cove can read, so the island can say so rather
    /// than opening a prompt bar about nothing.
    @discardableResult
    func attach(pasteboard: NSPasteboard) -> Bool {
        // The first only. A question is about one thing; a drag of four files
        // onto Ask is a drag that wanted Hold or Add, and quietly answering it
        // about one of the four would be picking on the user's behalf.
        guard let entry = Self.entries(from: pasteboard).first else { return false }
        attach(entry)
        return true
    }

    /// Parks everything on a dropped pasteboard. Returns how many landed.
    @discardableResult
    func add(pasteboard: NSPasteboard) -> Int {
        let added = Self.entries(from: pasteboard)
        entries.append(contentsOf: added)
        announce()
        return added.count
    }

    /// Parks one file Cove already holds a path to — a screenshot it was just
    /// offered, rather than something dragged in.
    ///
    /// No bytes are read here either. The provider is built per drag, and by
    /// then the file is still where it was: `ScreenshotWatcher` keeps its
    /// folder's security scope open for as long as it is watching, so dragging
    /// a parked screenshot back out works for the life of the session — which is
    /// exactly as long as the tray promises to last.
    func add(fileURL url: URL, preview: NSImage? = nil) {
        entries.append(
            Entry(
                name: url.lastPathComponent,
                icon: NSWorkspace.shared.icon(forFile: url.path),
                preview: preview ?? Self.preview(of: url),
                pasteboardItem: { url as NSURL }
            )
        )
        announce()
    }

    func remove(_ entry: Entry) {
        entries.removeAll { $0.id == entry.id }
        announce()
    }

    func clear() {
        entries.removeAll()
        announce()
    }

    /// The closed island reports what is being held, and it has no way to watch
    /// this object — `NotchActivityCenter` is the one thing the strip reads, so
    /// every change to the tray has to reach it.
    private func announce() {
        NotchActivityCenter.shared.trayDidChange()
    }

    // MARK: - Building

    private static func entries(from pasteboard: NSPasteboard) -> [Entry] {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            return urls.map { url in
                guard url.isFileURL else {
                    return Entry(
                        name: url.host() ?? url.absoluteString,
                        icon: symbol("link"),
                        pasteboardItem: { url as NSURL }
                    )
                }
                return Entry(
                    name: url.lastPathComponent,
                    icon: NSWorkspace.shared.icon(forFile: url.path),
                    preview: Self.preview(of: url),
                    pasteboardItem: { url as NSURL }
                )
            }
        }

        if let images = pasteboard.readObjects(forClasses: [NSImage.self]) as? [NSImage],
           !images.isEmpty {
            return images.map { image in
                Entry(
                    name: "Image",
                    icon: image,
                    preview: image,
                    pasteboardItem: { image }
                )
            }
        }

        if let strings = pasteboard.readObjects(forClasses: [NSString.self]) as? [String],
           !strings.isEmpty {
            return strings.map { text in
                Entry(
                    name: String(text.prefix(28)),
                    icon: symbol("text.alignleft"),
                    pasteboardItem: { text as NSString }
                )
            }
        }

        return []
    }

    private static func symbol(_ name: String) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage()
    }

    /// What a parked image looks like, at thumbnail size.
    ///
    /// Only images, and only a downscaled copy: the tray's promise is that
    /// nothing is stored, and a full-resolution bitmap per parked file would
    /// quietly turn a holding shelf into a second store. Everything else keeps
    /// Finder's icon, which is the honest picture of a spreadsheet.
    private static func preview(of url: URL) -> NSImage? {
        guard url.isFileURL,
              let type = UTType(filenameExtension: url.pathExtension),
              type.conforms(to: .image),
              let image = NSImage(contentsOf: url) else {
            return nil
        }

        guard let data = image.downscaledJPEGData(maxPixelSize: 320) else { return image }
        return NSImage(data: data) ?? image
    }
}

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
        /// Rebuilt per drag, because an `NSItemProvider` is consumed by the
        /// drag it is handed to.
        let provider: () -> NSItemProvider
    }

    private(set) var entries: [Entry] = []

    private init() {}

    var isEmpty: Bool { entries.isEmpty }

    /// Parks everything on a dropped pasteboard. Returns how many landed.
    @discardableResult
    func add(pasteboard: NSPasteboard) -> Int {
        let added = Self.entries(from: pasteboard)
        entries.append(contentsOf: added)
        return added.count
    }

    func remove(_ entry: Entry) {
        entries.removeAll { $0.id == entry.id }
    }

    func clear() {
        entries.removeAll()
    }

    // MARK: - Building

    private static func entries(from pasteboard: NSPasteboard) -> [Entry] {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            return urls.map { url in
                guard url.isFileURL else {
                    return Entry(
                        name: url.host() ?? url.absoluteString,
                        icon: symbol("link"),
                        provider: { NSItemProvider(object: url as NSURL) }
                    )
                }
                return Entry(
                    name: url.lastPathComponent,
                    // Finder's own icon for the file: no bytes are read, so the
                    // sandbox read access ending with the drag costs nothing.
                    icon: NSWorkspace.shared.icon(forFile: url.path),
                    provider: { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
                )
            }
        }

        if let images = pasteboard.readObjects(forClasses: [NSImage.self]) as? [NSImage],
           !images.isEmpty {
            return images.map { image in
                Entry(name: "Image", icon: image, provider: { NSItemProvider(object: image) })
            }
        }

        if let strings = pasteboard.readObjects(forClasses: [NSString.self]) as? [String],
           !strings.isEmpty {
            return strings.map { text in
                Entry(
                    name: String(text.prefix(28)),
                    icon: symbol("text.alignleft"),
                    provider: { NSItemProvider(object: text as NSString) }
                )
            }
        }

        return []
    }

    private static func symbol(_ name: String) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage()
    }
}

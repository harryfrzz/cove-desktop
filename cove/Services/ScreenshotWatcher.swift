import AppKit
import Observation
import UniformTypeIdentifiers

/// Watches the folder macOS writes screenshots into, and hands each new one to
/// the island the moment it lands.
///
/// Taking a screenshot is the most frequent capture a Mac has, and it was also
/// the one Cove was worst at: the file went to a folder, and getting it onto the
/// shelf meant finding it there and dragging it back to the notch. This closes
/// that loop — the island opens by itself and asks the same question the drop
/// face asks.
///
/// Nothing is asked of the user to set it up. macOS keeps the screenshot
/// location in `com.apple.screencapture`, and Cove reads it: where the folder is
/// is a fact the system already knows, not a preference worth making someone
/// restate. Access to it is TCC's business — the first read raises the system's
/// own prompt for Desktop or Documents, which is a better contract than a folder
/// grant buried in Cove's preferences, because it is revocable in System
/// Settings and it is worded by the OS rather than by us.
///
/// Reading that preference is also the reason Cove left the App Sandbox; see
/// `cove.entitlements`.
@MainActor
@Observable
final class ScreenshotWatcher {
    static let shared = ScreenshotWatcher()

    /// One screenshot, decoded and ready to be offered.
    ///
    /// The bitmap is carried rather than re-read later: by the time the user
    /// answers, Cove is frontmost and the answer to "what was on screen" has
    /// changed, so both the image and the app it was taken over are captured at
    /// detection time.
    struct Capture: Identifiable {
        let id = UUID()
        let url: URL
        let image: NSImage
        /// Whatever was frontmost when the shutter went. Cove is an accessory
        /// app and is never frontmost by accident, so this is the app being
        /// screenshotted.
        let sourceApp: String?

        var name: String { url.deletingPathExtension().lastPathComponent }
    }

    /// Called with each new screenshot. `NotchController` sets this; nothing
    /// else in the app hears about screenshots directly.
    var onCapture: ((Capture) -> Void)?

    /// Whether Cove watches at all. On by default: it needs nothing set up, and
    /// the one permission it does need is asked for by the system in its own
    /// words the first time the folder is read.
    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            isEnabled ? start() : stop()
        }
    }

    /// The folder being watched, for Settings.
    private(set) var folderPath: String?
    private(set) var isWatching = false
    /// Why watching isn't running. Shown in Settings rather than logged: the one
    /// way this fails is a refused TCC prompt, and that is fixed in System
    /// Settings by someone who has to be told.
    private(set) var failure: String?

    private var source: DispatchSourceFileSystemObject?
    private var folder: URL?
    /// Names already accounted for, so a rescan reports only what arrived since.
    private var seen: Set<String> = []
    private var rescanTask: Task<Void, Never>?

    private static let enabledKey = "cove.watchScreenshots"

    /// A file older than this was not just taken. The folder fires an event for
    /// anything written into it — a screenshot moved back in from elsewhere, a
    /// sync client rewriting a file — and offering to save one of those would be
    /// Cove asking about something the user did not just do.
    private static let freshness: TimeInterval = 30

    private init() {
        // Absent means on, which `bool(forKey:)` alone cannot express: an unset
        // key and an explicit `false` both read as false.
        isEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    // MARK: - Watching

    func start() {
        guard isEnabled, source == nil else { return }

        let folder = Self.screenshotFolder()
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else {
            // Almost always a refused TCC prompt. The folder is real and the
            // path is right; Cove is simply not allowed to look at it.
            folderPath = Self.displayPath(folder)
            failure = "Cove can’t read \(folder.lastPathComponent). Allow it in System Settings → Privacy & Security → Files and Folders."
            return
        }

        self.folder = folder
        folderPath = Self.displayPath(folder)
        // Everything already there is history. Only what arrives from now on is
        // something the user just did.
        seen = imageNames(in: folder)

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler {
            MainActor.assumeIsolated { ScreenshotWatcher.shared.scheduleRescan() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()

        self.source = source
        isWatching = true
        failure = nil
    }

    func stop() {
        rescanTask?.cancel()
        rescanTask = nil
        source?.cancel()
        source = nil
        folder = nil
        seen = []
        isWatching = false
    }

    /// Re-reads where screenshots go and moves the watch if it has changed.
    ///
    /// The location is a preference like any other and can be changed at any
    /// time, including by `screencapture` itself. Rather than subscribe to
    /// another app's defaults — which is not a thing that can be done reliably —
    /// this is called when Cove is activated, which is the cheapest moment that
    /// reliably follows the user having been elsewhere changing it.
    func refreshLocation() {
        guard isEnabled else { return }
        let current = Self.screenshotFolder()
        guard current != folder else { return }
        stop()
        start()
    }

    /// A screenshot lands in more than one event — the write, then the rename
    /// off the temporary name — and the bytes are not necessarily complete at
    /// the first of them. One short wait covers the whole sequence and collapses
    /// a burst of events into a single scan.
    private func scheduleRescan() {
        rescanTask?.cancel()
        rescanTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            self?.rescan()
        }
    }

    private func rescan() {
        guard let folder else { return }

        let names = imageNames(in: folder)
        let arrived = names.subtracting(seen)
        // Assigned rather than unioned, so a deleted file is forgotten too and
        // the set cannot grow without bound over a long session.
        seen = names
        guard !arrived.isEmpty else { return }

        for name in arrived.sorted() {
            let url = folder.appending(path: name)
            guard Self.isFresh(url), Self.isScreenCapture(url) else { continue }
            Task { [weak self] in await self?.offer(url) }
        }
    }

    /// Decodes the file and hands it on, retrying briefly.
    ///
    /// The dispatch source fires while the bytes are still being written, and a
    /// screenshot read at that moment decodes to a truncated image or to nothing
    /// at all. Retrying is cheaper and more reliable than trying to guess when
    /// the writer has finished.
    private func offer(_ url: URL) async {
        for attempt in 0..<6 {
            if attempt > 0 {
                try? await Task.sleep(for: .milliseconds(120))
            }
            guard let image = NSImage(contentsOf: url), image.size.width > 0 else { continue }

            onCapture?(
                Capture(
                    url: url,
                    image: image,
                    sourceApp: NSWorkspace.shared.frontmostApplication?.localizedName
                )
            )
            return
        }
    }

    // MARK: - Reading the folder

    private func imageNames(in folder: URL) -> Set<String> {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentTypeKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )) ?? []

        return Set(
            contents
                .filter { url in
                    let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
                    return type?.conforms(to: .image) == true
                }
                .map(\.lastPathComponent)
        )
    }

    private static func isFresh(_ url: URL) -> Bool {
        guard let created = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate else {
            // No date to judge by. The screenshot test below is the stricter of
            // the two, so let it decide rather than dropping the file here.
            return true
        }
        return Date.now.timeIntervalSince(created) < freshness
    }

    /// Whether the file is a screenshot rather than something else that happened
    /// to land in the same folder.
    ///
    /// Spotlight's own flag is the honest test and it is locale-independent —
    /// but a file a fraction of a second old may not be indexed yet, and on a
    /// volume with indexing off it never will be. So the name is checked too.
    /// Between them a screenshot is caught the instant it appears, and a
    /// downloaded image sharing the folder is not.
    private static func isScreenCapture(_ url: URL) -> Bool {
        if let item = MDItemCreateWithURL(nil, url as CFURL),
           let flag = MDItemCopyAttribute(item, "kMDItemIsScreenCapture" as CFString) as? Bool {
            return flag
        }

        let name = url.deletingPathExtension().lastPathComponent
        return name.localizedCaseInsensitiveContains("screenshot")
            || name.localizedCaseInsensitiveContains("screen shot")
            || name.localizedCaseInsensitiveContains("screen recording")
    }

    // MARK: - Where screenshots go

    /// The folder macOS is currently saving screenshots to.
    ///
    /// `com.apple.screencapture`'s `location` is the same value the Screenshot
    /// app's own "Save to" menu writes, so this follows the user wherever they
    /// have put it. Unset means the default, which is the Desktop. The stored
    /// value is a shell path — `~/Documents/Screenshots` — so the tilde has to be
    /// expanded rather than treated as a directory name.
    private static func screenshotFolder() -> URL {
        guard let raw = UserDefaults(suiteName: "com.apple.screencapture")?
            .string(forKey: "location")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty else {
            return defaultFolder
        }

        let expanded = (raw as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            // A location pointing at a folder that no longer exists is what
            // macOS itself falls back on the Desktop for.
            return defaultFolder
        }
        return URL(filePath: expanded)
    }

    private static var defaultFolder: URL {
        URL(filePath: NSHomeDirectory()).appending(path: "Desktop")
    }

    /// `~/Documents/Screenshots` rather than the absolute path — shorter, and it
    /// is the form the user typed if they ever set it.
    private static func displayPath(_ url: URL) -> String {
        let home = NSHomeDirectory()
        guard url.path.hasPrefix(home) else { return url.path }
        return "~" + url.path.dropFirst(home.count)
    }
}

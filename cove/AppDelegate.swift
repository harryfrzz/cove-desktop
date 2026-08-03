import AppKit
import SwiftData
import SwiftUI
import WidgetKit

/// Brings the island up and keeps a way back to it in the menu bar.
///
/// Cove runs as an accessory app: no Dock tile, no menu bar of its own, no
/// window in the switcher. The status item is the only piece of ordinary app
/// surface it has, and it exists mostly so the app can be quit by someone who
/// has never hovered the notch.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: NotchController?
    private var statusItem: NSStatusItem?
    private var linkPreviewsItem: NSMenuItem?
    private let windowController = CoveWindowController()
    /// The stamps already acted on, so a widget's note is honoured once and not
    /// re-run on every unrelated activation.
    private var lastHandledPasteStamp: Double = 0
    private var lastHandledOpenStamp: Double = 0
    private var lastHandledImportStamp: Double = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Before any window is built, so the first frame is already in the
        // chosen appearance rather than flashing the system one.
        CoveAppearanceStore.shared.apply()

        controller = NotchController()
        buildStatusItem()
        observeWidgetIntents()

#if DEBUG
        registerWidgetForDevelopment()

        // Lets a screenshot run catch the open state; hovering the notch is
        // otherwise the only way in, and that cannot be scripted.
        if ProcessInfo.processInfo.arguments.contains("--open-island") {
            controller?.model.holdsOpen = true
            controller?.open()
        }
        if ProcessInfo.processInfo.arguments.contains("--open-window") {
            windowController.show()
        }
#endif

        Task {
            // Recover items stranded mid-processing by a kill, and re-index
            // anything embedded by an older model version.
            await ShelfProcessor.shared.reconcileAtLaunch()
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

#if DEBUG
    /// Re-registers the widget with macOS on every development launch.
    ///
    /// macOS forgets a widget extension whenever the app bundle it lives in is
    /// replaced, which every rebuild does. After that `chronod` logs "Ignoring
    /// restricted or unknown extension" and Cove is simply absent from Edit
    /// Widgets — nothing is wrong with the code, the system has lost track of
    /// the extension. Running from DerivedData makes it certain.
    ///
    /// Done here rather than in a build phase because build phases run before
    /// the bundle is signed, and registering an unsigned copy does not survive
    /// the signing that follows. By the time this runs the app is signed,
    /// installed where it is going to run from, and launched.
    ///
    /// Debug only. A release build is installed once, in a stable place, and
    /// registers itself the ordinary way.
    private func registerWidgetForDevelopment() {
        let appex = Bundle.main.bundleURL
            .appending(path: "Contents/PlugIns/CoveWidgetExtension.appex")
        guard FileManager.default.fileExists(atPath: appex.path) else { return }

        Task.detached(priority: .background) {
            func pluginkit(_ arguments: [String]) {
                let process = Process()
                process.executableURL = URL(filePath: "/usr/bin/pluginkit")
                process.arguments = arguments
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try? process.run()
                process.waitUntilExit()
            }
            pluginkit(["-a", appex.path])
            pluginkit(["-e", "use", "-i", "com.loop.cove.CoveWidget"])
        }
    }
#endif

    /// Listens for the widget's buttons.
    ///
    /// `openAppWhenRun` runs an intent's `perform()` in *this* process, so the
    /// notification it posts arrives here directly — which is the only reliable
    /// signal. Activation happens before `perform()` does, so a tap's stamp is
    /// always written after `applicationDidBecomeActive` has already read the
    /// old one; relying on that alone meant the buttons quietly did nothing.
    private func observeWidgetIntents() {
        let centre = NotificationCenter.default
        centre.addObserver(
            forName: .coveIntentPaste, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.redeem(.paste) }
        }
        centre.addObserver(
            forName: .coveIntentOpen, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.redeem(.open) }
        }
        centre.addObserver(
            forName: .coveIntentImport, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.redeem(.importFile) }
        }
    }

    private enum WidgetAction { case paste, open, importFile }

    /// Runs one widget action and clears its stamp, so the fallback below does
    /// not run it a second time.
    private func redeem(_ action: WidgetAction) {
        let defaults = UserDefaults(suiteName: PasteIntoCoveIntent.appGroupID)
        NSApp.activate()

        switch action {
        case .paste:
            lastHandledPasteStamp = Date.now.timeIntervalSince1970
            defaults?.removeObject(forKey: PasteIntoCoveIntent.pendingKey)
            pasteIntoCove()
        case .open:
            lastHandledOpenStamp = Date.now.timeIntervalSince1970
            defaults?.removeObject(forKey: OpenCoveIntent.pendingKey)
            windowController.show()
        case .importFile:
            lastHandledImportStamp = Date.now.timeIntervalSince1970
            defaults?.removeObject(forKey: AddFileToCoveIntent.pendingKey)
            CaptureIngest.importFromOpenPanel(into: CoveStore.shared.mainContext)
        }
    }

    /// The fallback for a cold launch, where the intent may have run before
    /// this delegate was listening. Anything already handled above has had its
    /// stamp cleared, so nothing runs twice.
    func applicationDidBecomeActive(_ notification: Notification) {
        // Cheapest reliable moment to notice the screenshot folder has moved:
        // changing it means going to the Screenshot app, which means having been
        // somewhere other than here.
        ScreenshotWatcher.shared.refreshLocation()

        let defaults = UserDefaults(suiteName: PasteIntoCoveIntent.appGroupID)

        let pasteStamp = defaults?.double(forKey: PasteIntoCoveIntent.pendingKey) ?? 0
        if pasteStamp > lastHandledPasteStamp {
            lastHandledPasteStamp = pasteStamp
            defaults?.removeObject(forKey: PasteIntoCoveIntent.pendingKey)
            pasteIntoCove()
        }

        let openStamp = defaults?.double(forKey: OpenCoveIntent.pendingKey) ?? 0
        if openStamp > lastHandledOpenStamp {
            lastHandledOpenStamp = openStamp
            defaults?.removeObject(forKey: OpenCoveIntent.pendingKey)
            windowController.show()
        }

        let importStamp = defaults?.double(forKey: AddFileToCoveIntent.pendingKey) ?? 0
        if importStamp > lastHandledImportStamp {
            lastHandledImportStamp = importStamp
            defaults?.removeObject(forKey: AddFileToCoveIntent.pendingKey)
            CaptureIngest.importFromOpenPanel(into: CoveStore.shared.mainContext)
        }
    }

    /// Clicking the Dock tile (there isn't one) or reopening from Launchpad
    /// unfolds the island rather than doing nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        controller?.open()
        return true
    }

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "square.stack.3d.up",
            accessibilityDescription: "Cove"
        )
        item.button?.image?.isTemplate = true

        let menu = NSMenu()
        menu.addItem(
            withTitle: "Open Window",
            action: #selector(openWindow),
            keyEquivalent: ""
        ).target = self
        menu.addItem(
            withTitle: "Open Cove",
            action: #selector(openIsland),
            keyEquivalent: ""
        ).target = self
        menu.addItem(
            withTitle: "Paste into Cove",
            action: #selector(pasteIntoCove),
            keyEquivalent: ""
        ).target = self
        menu.addItem(.separator())

        // The one thing Cove does that leaves the Mac, so it gets a switch.
        // Off, saved links keep the covers they already have and new ones get a
        // drawn card instead.
        let previews = menu.addItem(
            withTitle: "Fetch Link Previews",
            action: #selector(toggleLinkPreviews),
            keyEquivalent: ""
        )
        previews.target = self
        previews.state = LinkPreviewService.isEnabled ? .on : .off
        linkPreviewsItem = previews

        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit Cove",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        item.menu = menu
        statusItem = item
    }

    @objc private func openWindow() {
        windowController.show()
    }

    @objc private func openIsland() {
        controller?.open()
    }

    @objc private func toggleLinkPreviews() {
        let enabled = !LinkPreviewService.isEnabled
        LinkPreviewService.setEnabled(enabled)
        linkPreviewsItem?.state = enabled ? .on : .off
    }

    @objc private func pasteIntoCove() {
        guard let item = CaptureIngest.itemFromClipboard() else {
            NotchActivityCenter.shared.post(.nothingToSave)
            return
        }
        CaptureIngest.insert(item, into: CoveStore.shared.mainContext)
        NotchActivityCenter.shared.post(.saved(count: 1))
    }
}

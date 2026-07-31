import AppKit
import SwiftData
import SwiftUI

/// Brings the island up and keeps a way back to it in the menu bar.
///
/// Cove runs as an accessory app: no Dock tile, no menu bar of its own, no
/// window in the switcher. The status item is the only piece of ordinary app
/// surface it has, and it exists mostly so the app can be quit by someone who
/// has never hovered the notch.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: NotchController?
    private var statusItem: NSStatusItem?
    private let windowController = CoveWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        controller = NotchController()
        buildStatusItem()

#if DEBUG
        // Lets a screenshot run catch the open state; hovering the notch is
        // otherwise the only way in, and that cannot be scripted.
        if ProcessInfo.processInfo.arguments.contains("--open-island") {
            controller?.model.holdsOpen = true
            controller?.open()
        }
#endif

        Task {
            // Recover items stranded mid-processing by a kill, and re-index
            // anything embedded by an older model version.
            await ShelfProcessor.shared.reconcileAtLaunch()
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

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

    @objc private func pasteIntoCove() {
        guard let item = CaptureIngest.itemFromClipboard() else {
            NotchActivityCenter.shared.post("Nothing Cove can hold on the clipboard")
            return
        }
        CaptureIngest.insert(item, into: CoveStore.shared.mainContext)
    }
}

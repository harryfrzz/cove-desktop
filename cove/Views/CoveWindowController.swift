import AppKit
import SwiftUI

/// The app's own window — the surface the island cannot be.
///
/// The island is deliberately small: it hangs off the notch and has room for a
/// prompt and two drop targets, nothing more. Browsing what Cove has kept,
/// searching it, opening one thing and reading it — all of that needs a window,
/// and this is it.
///
/// Built in AppKit rather than as a SwiftUI `Window` scene for the same reason
/// `NotchController` is: Cove runs as an accessory app, so the window has to be
/// ordered in and given focus explicitly. Owning the `NSWindow` is what makes
/// that dependable.
@MainActor
final class CoveWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    /// Opens the window, or brings it forward if it is already open. Cove is an
    /// accessory app and is never frontmost by accident, so showing a window
    /// means activating too — otherwise it appears behind whatever the user was
    /// in and reads as not having opened at all.
    func show() {
        let window = window ?? build()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func build() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Cove"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: CoveWindowView())
        // Smaller than this and the shelf would have nowhere to lay out; the
        // window is meant to hold a grid, not a list of one column.
        window.contentMinSize = NSSize(width: 720, height: 480)
        window.center()
        // Remembers where it was put, so reopening does not throw it back to
        // the middle of the screen.
        window.setFrameAutosaveName("CoveMainWindow")
        window.delegate = self
        self.window = window
        return window
    }
}

/// The window's contents.
///
/// Deliberately empty: this is the shell the shelf will be built into, and an
/// invented layout here would only have to be torn out. It follows the system
/// appearance — unlike the island, which is pinned to the black notch, a window
/// sits anywhere on screen and should look like it belongs there.
struct CoveWindowView: View {
    var body: some View {
        Text("Cove")
            .font(.system(size: 15, weight: .medium, design: .serif))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.background)
    }
}

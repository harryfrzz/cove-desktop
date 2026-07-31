import AppKit
import OSLog
import SwiftUI

private let dragLog = Logger(subsystem: "com.loop.cove", category: "drag")

/// The SwiftUI host, with its drop handling taken away.
///
/// `NSHostingView` registers itself for dragged types, and a registered subview
/// is offered the drag before the view underneath it — so the island's own
/// destination never saw a thing. Overriding the registration is the only way
/// to keep it out of the way for good; unregistering after the fact does not
/// hold, because SwiftUI re-registers whenever it rebuilds the tree.
final class NonDroppingHostingView<Content: View>: NSHostingView<Content> {
    override func registerForDraggedTypes(_ newTypes: [NSPasteboard.PasteboardType]) {
        // Deliberately empty. `NotchContainerView` is Cove's one destination.
    }
}

/// The window the island lives in.
///
/// A non-activating panel, so hovering the notch never takes focus from what
/// the user is actually doing. It becomes key only when they click into it —
/// otherwise the prompt bar could never be typed into.
final class NotchPanel: NSPanel {
    /// Called on the first click inside, before the event is delivered.
    var onInteraction: (() -> Void)?

    init(contentRect: CGRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        // Above the menu bar and its status items, and — with
        // `.fullScreenAuxiliary` below — above full-screen windows: the notch is
        // the one piece of screen that is Cove's no matter what is running.
        //
        // Deliberately just past `.statusBar` rather than up at `.screenSaver`.
        // A window that high is treated as a non-interactive overlay and is
        // passed over when a drag looks for somewhere to land, so the island
        // opened to meet a drag it could never be given: the file dropped
        // straight through to the desktop behind it.
        level = .statusBar + 1
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
        // `NSApp.hide` is how focus is handed back when the island closes; the
        // panel itself must survive that, or the island would vanish with it.
        canHide = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        // The panel is black against a black notch; a light system appearance
        // would put a visible seam between them.
        appearance = NSAppearance(named: .darkAqua)
    }

    // Key, so the prompt bar works once clicked. Never main: Cove has no menus
    // of its own and taking main state would rearrange the menu bar.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Clicks arrive here even while Cove is inactive (that is what a
    /// non-activating panel is for), which makes this the one place that can
    /// tell "the user is using the island" from "the pointer passed over it".
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            onInteraction?()
        }
        super.sendEvent(event)
    }
}

/// Hosts the SwiftUI island and owns both the hover tracking and the *arrival*
/// half of a drag.
///
/// Hover is a tracking area rather than a global mouse monitor on purpose: a
/// tracking area needs no permissions and stops firing when the window is not
/// under the pointer, which is exactly the question being asked.
///
/// Dragging is registered here rather than left to SwiftUI because the island
/// has to grow to meet the drag. A SwiftUI drop target on the closed pill does
/// see the drag, but opening resizes the window underneath the drag session,
/// and the target it was tracking goes out from under it — which is why nothing
/// appeared. An AppKit destination on the view that owns the whole window
/// survives that resize, so it can open the panel and hand the drag on to the
/// two targets inside.
final class NotchContainerView: NSView {
    var onHoverChange: ((Bool) -> Void)?
    /// Where the drag is, in this view's coordinates (top-left origin), or
    /// `nil` when it has left.
    var onDragMove: ((CGPoint?) -> Void)?
    /// The drop itself. `true` when Cove took it.
    var onDrop: ((NSPasteboard, CGPoint) -> Bool)?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(CaptureIngest.acceptedPasteboardTypes)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used — the island is built in code")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self
            )
        )
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChange?(false)
    }

    // MARK: - Dragging

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dragLog.info("entered types=\(sender.draggingPasteboard.types ?? [], privacy: .public)")
        onDragMove?(point(of: sender))
        return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        onDragMove?(point(of: sender))
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        onDragMove?(nil)
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        onDragMove?(nil)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let handled = onDrop?(sender.draggingPasteboard, point(of: sender)) ?? false
        dragLog.info("perform handled=\(handled, privacy: .public)")
        return handled
    }

    /// Window coordinates are bottom-left origin; this view is flipped, so the
    /// conversion also puts the point in the same space SwiftUI reports its
    /// frames in.
    private func point(of sender: any NSDraggingInfo) -> CGPoint {
        convert(sender.draggingLocation, from: nil)
    }
}

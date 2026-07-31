import AppKit

/// Notices a drag session anywhere on the system, so the island can grow to
/// meet it.
///
/// AppKit only offers a drag to a window the pointer has already entered, and
/// the closed island is the size of the notch — mostly camera housing, with a
/// few points of reachable edge either side. A drag aimed at it therefore had
/// to land on it exactly, which is not a thing anyone can do while carrying a
/// file. This sees the drag coming and tells the controller to widen the
/// window's catch area for as long as the session lasts.
///
/// Being *offered* the drag at all is a separate matter, and one of window
/// level rather than size — see `NotchPanel`.
///
/// Mouse monitors and `NSEvent.mouseLocation` need no permission — only
/// keyboard monitoring does — and the drag pasteboard's change count moves at
/// the start of every real session, which is what separates a dragged file from
/// someone moving a window by its title bar.
@MainActor
final class DragWatcher {
    /// Where the pointer is, in global coordinates, on every tick of a live
    /// drag session. The controller decides what is near enough to matter.
    ///
    /// The island's whole drop face is driven from this rather than from
    /// `draggingEntered`, so the panel opens as the drag approaches rather than
    /// only once the pointer is inside the window. AppKit is still what
    /// delivers the *drop* — it carries the pasteboard, and a sandboxed app's
    /// read access to the dropped file comes with it — but nothing the user
    /// sees waits on it.
    var onDragMoved: ((CGPoint) -> Void)?
    /// The session ended, wherever it landed.
    var onDragEnd: (() -> Void)?

    private var monitors: [Any] = []
    private var poll: Timer?
    private var changeCountAtPress: Int
    private var isDragging = false

    /// Only runs between mouse-down and mouse-up, so the cost is a handful of
    /// cheap reads during a gesture the user is already making. Fast enough
    /// that the island has opened by the time the pointer arrives.
    private static let pollInterval: TimeInterval = 1.0 / 15.0

    init() {
        changeCountAtPress = NSPasteboard(name: .drag).changeCount
    }

    // MARK: - Lifetime

    func start() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp]

        // Global sees the drag that matters — it starts in Finder, or Safari,
        // or wherever the user was. Local is here so a drag that begins inside
        // Cove's own panel is watched the same way.
        let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.route(event.type) }
        })
        if let global { monitors.append(global) }

        let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.route(event.type) }
            return event
        })
        if let local { monitors.append(local) }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        endSession()
    }

    private func route(_ type: NSEvent.EventType) {
        switch type {
        case .leftMouseDown: beginSession()
        case .leftMouseUp: endSession()
        default: break
        }
    }

    // MARK: - Session

    /// A press is not yet a drag. The change count is banked here so the tick
    /// below can tell the moment a real session writes to the drag pasteboard.
    private func beginSession() {
        let banked = NSPasteboard(name: .drag).changeCount
        changeCountAtPress = banked
        guard poll == nil else { return }

        let timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // The island opening a frame late is invisible; a timer that insists on
        // waking a sleeping CPU is not.
        timer.tolerance = Self.pollInterval / 2
        poll = timer
    }

    private func endSession() {
        poll?.invalidate()
        poll = nil
        guard isDragging else { return }
        isDragging = false
        onDragEnd?()
    }

    private func tick() {
        // Belt and braces: a mouse-up swallowed by another app's drag handling
        // would otherwise leave this running for good.
        guard NSEvent.pressedMouseButtons & 1 != 0 else {
            endSession()
            return
        }
        if !isDragging {
            // The source writes the drag pasteboard as the session opens, which
            // is the earliest honest signal that something is being carried —
            // and what separates a dragged file from a window being moved by
            // its title bar.
            let count = NSPasteboard(name: .drag).changeCount
            guard count != changeCountAtPress else { return }
            isDragging = true
        }

        onDragMoved?(NSEvent.mouseLocation)
    }
}

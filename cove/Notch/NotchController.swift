import AppKit
import SwiftData
import SwiftUI

/// Drives the island: owns the panel, decides which state it is in, and keeps
/// the window's frame and the SwiftUI content agreeing about it.
///
/// The two are moved in a deliberate order. Growing, the window is resized
/// first and the content animates into the space that is already there;
/// shrinking, the content animates in first and the window follows once it has
/// finished. Doing it the other way round clips the animation at one end and
/// leaves an invisible window swallowing clicks at the other.
@MainActor
final class NotchController: NSObject {
    let model: NotchModel

    private var panel: NotchPanel!
    private var container: NotchContainerView!
    private var metrics: NotchMetrics

    private var openTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    private var shrinkTask: Task<Void, Never>?
    private var offerTask: Task<Void, Never>?
    /// Whether the pointer is on the island right now. Read when a screenshot
    /// arrives: an offer that appears under the pointer is being looked at, and
    /// must not start counting down.
    private var isHovered = false

    private let dragWatcher = DragWatcher()
    /// A drag session is live nearby, so the window is holding a wider frame
    /// than its state calls for. Invisible — it only decides where AppKit will
    /// offer the drag.
    private var isCatchingDrag = false

    /// Whether Cove took focus for the current interaction, and therefore owes
    /// it back when the island closes.
    private var didTakeFocus = false

    /// Barely a delay at all — enough to swallow a pointer that clips the notch
    /// on the way to the menu bar, not enough to feel like waiting. Anything
    /// past about 60 ms reads as the island being slow rather than careful.
    private static let openDelay: Duration = .milliseconds(45)
    /// Longer than the open delay on purpose: leaving by accident (reaching for
    /// a control near the edge) is far more likely than arriving by accident.
    private static let closeDelay: Duration = .milliseconds(260)
    /// How long an unanswered screenshot offer stays up. Long enough to notice
    /// something appeared, read it, and reach for it; short enough that an
    /// ignored question is not a panel left covering the top of the screen.
    private static let offerDelay: Duration = .seconds(6)
    /// The shorter countdown used after the pointer has been on the offer and
    /// left again. The question has been read by then, so leaving is an answer
    /// of sorts.
    private static let offerLingerDelay: Duration = .seconds(2)
    private static let morph = Animation.spring(response: 0.34, dampingFraction: 0.82)

    override init() {
        let screen = NotchMetrics.preferredScreen() ?? NSScreen.screens[0]
        metrics = NotchMetrics(screen: screen)
        model = NotchModel(metrics: metrics)
        super.init()

        buildPanel()
        wireModel()
        watchForDrags()
        observeScreenChanges()
        observeActivity()
        observeFocusLoss()
        observeScreenshots()
    }

    // MARK: - Building

    private func buildPanel() {
        let initialFrame = frame(for: .closed)
        panel = NotchPanel(contentRect: initialFrame)

        container = NotchContainerView(frame: CGRect(origin: .zero, size: initialFrame.size))
        container.autoresizingMask = [.width, .height]
        container.onHoverChange = { [weak self] isInside in
            self?.hoverChanged(isInside)
        }
        container.onDragMove = { [weak self] point in
            self?.dragMoved(to: point)
        }
        container.onDrop = { [weak self] pasteboard, point in
            self?.performDrop(pasteboard: pasteboard, at: point) ?? false
        }

        let hosting = NonDroppingHostingView(
            rootView: NotchRootView(model: model)
        )
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        // The island is drawn inside a window that is mostly empty space; the
        // hosting view must not paint a background into it.
        hosting.layer?.backgroundColor = .clear
        container.addSubview(hosting)

        panel.contentView = container
        panel.onInteraction = { [weak self] in
            self?.takeFocus()
        }
        panel.orderFrontRegardless()
    }

    private func wireModel() {
        model.requestOpen = { [weak self] in self?.open() }
        model.requestClose = { [weak self] in self?.close() }
        model.requestFocus = { [weak self] in self?.takeFocus() }
        model.requestMove = { [weak self] screen in self?.move(to: screen) }
        model.requestEndDrag = { [weak self] in self?.endDrag() }
    }

    // MARK: - Frames

    /// The window frame for a state, widened while a drag is in flight.
    ///
    /// The island itself is still drawn at its state's size — the extra area is
    /// empty and transparent. It exists only because AppKit will not offer a
    /// drag to a window the pointer has not already entered, and the notch is
    /// far too small a thing to ask someone to hit while carrying a file.
    private func frame(for state: NotchState) -> CGRect {
        let base = metrics.frame(for: state)
        return isCatchingDrag ? base.union(metrics.dragCatchFrame) : base
    }

    /// Re-applies the frame for whatever state the island is already in. Used
    /// when the frame changes without the state doing so — the catch area
    /// appearing or going, or the screen being rearranged underneath it.
    private func applyFrame() {
        panel.setFrame(frame(for: model.state), display: true)
    }

    // MARK: - Approaching drags

    /// Follows a drag across the screen and puts the island in front of it.
    ///
    /// Reaching the catch area widens the window — which is what lets AppKit
    /// deliver the eventual drop — and raises the two drop targets. Both are
    /// driven from the pointer rather than from `draggingEntered`, so what the
    /// user sees never waits on AppKit deciding it has a destination.
    private func watchForDrags() {
        dragWatcher.onDragMoved = { [weak self] point in
            self?.dragPointerMoved(to: point)
        }
        dragWatcher.onDragEnd = { [weak self] in
            self?.endCatchingDrag()
        }
        dragWatcher.start()
    }

    private func dragPointerMoved(to global: CGPoint) {
        if !isCatchingDrag {
            guard metrics.dragCatchFrame.contains(global) else { return }
            beginCatchingDrag()
        }

        // Once the window has grown, its own frame is the honest test — it is
        // larger than the catch area while the island is open.
        if panel.frame.contains(global) || metrics.dragCatchFrame.contains(global) {
            dragMoved(to: localPoint(global))
        } else if model.isDropTargeted {
            // Wandered off mid-drag. The panel goes back to its ordinary face;
            // the window keeps its width until the session ends, so coming back
            // costs nothing.
            model.isDropTargeted = false
            model.hoveredDropZone = nil
            NotchActivityCenter.shared.isDropTargeted = false
        }
    }

    /// Global (bottom-left origin) to the panel's flipped, top-left space —
    /// which is also the space SwiftUI reports the drop zone frames in.
    private func localPoint(_ global: CGPoint) -> CGPoint {
        CGPoint(
            x: global.x - panel.frame.minX,
            y: panel.frame.maxY - global.y
        )
    }

    private func beginCatchingDrag() {
        guard !isCatchingDrag else { return }
        isCatchingDrag = true
        shrinkTask?.cancel()
        applyFrame()
    }

    private func endCatchingDrag() {
        guard isCatchingDrag else { return }
        isCatchingDrag = false
        applyFrame()
        // A session that ended without ever entering the island leaves the drop
        // face up otherwise — `draggingExited` is not sent for a drag that was
        // released somewhere else entirely.
        if model.isDropTargeted {
            endDrag()
        }
    }

    // MARK: - Hover

    private func hoverChanged(_ isInside: Bool) {
        isHovered = isInside

        if isInside {
            closeTask?.cancel()
            closeTask = nil
            // Reaching the offer is engaging with it, so the countdown stops
            // until the pointer leaves again. Reading a question should not be
            // a race against it.
            offerTask?.cancel()
            offerTask = nil
            guard model.state != .open, model.opensOnHover else { return }
            openTask?.cancel()
            openTask = Task { [weak self] in
                try? await Task.sleep(for: Self.openDelay)
                guard !Task.isCancelled else { return }
                self?.open()
            }
        } else {
            openTask?.cancel()
            openTask = nil
            // An offer blocks the ordinary auto-close, so it has to be given a
            // countdown of its own here or leaving would strand it open.
            if model.screenshotOffer != nil {
                scheduleOfferDismissal(after: Self.offerLingerDelay)
            } else {
                scheduleClose()
            }
        }
    }

    // MARK: - Dragging

    /// The whole drag, start to finish.
    ///
    /// AppKit owns this rather than SwiftUI because the island has to grow to
    /// meet the drag: a destination registered on the closed pill goes out from
    /// under the drag session the moment the window resizes, which is why a
    /// drop over the notch appeared to do nothing at all. This view is the
    /// window's own content view — it is there before the drag arrives, it
    /// resizes with the window rather than being replaced, and it stays the
    /// destination for the whole gesture.
    private func dragMoved(to point: CGPoint?) {
        guard let point else {
            // Leaving is believed immediately here, because unlike the SwiftUI
            // arrangement there are no nested destinations to be confused with:
            // this view covers the entire panel.
            endDrag()
            return
        }

        if !model.isDropTargeted {
            model.isDropTargeted = true
            NotchActivityCenter.shared.isDropTargeted = true
            open()
        }
        model.hoveredDropZone = zone(at: point)
    }

    private func zone(at point: CGPoint) -> NotchModel.DropZone? {
        model.dropZoneFrames.first { $0.value.contains(point) }?.key
    }

    /// Routes the drop to the target it landed on. A drop that landed on
    /// neither is refused rather than assigned to one on the user's behalf —
    /// holding and saving mean different things, and the animation of a
    /// rejected drag returning to its source is the honest answer.
    private func performDrop(pasteboard: NSPasteboard, at point: CGPoint) -> Bool {
        guard let zone = zone(at: point) else {
            endDrag()
            return false
        }

        let count: Int
        let landed: NotchToast
        switch zone {
        case .hold:
            count = TempTray.shared.add(pasteboard: pasteboard)
            landed = .held(count: count)
        case .save:
            count = CaptureIngest.ingest(
                pasteboard: pasteboard,
                into: CoveStore.shared.mainContext,
                sourceApp: NSWorkspace.shared.frontmostApplication?.localizedName
            )
            landed = .saved(count: count)
        case .ask:
            count = TempTray.shared.attach(pasteboard: pasteboard) ? 1 : 0
            landed = .attached
        }

        endDrag()
        NotchActivityCenter.shared.post(count == 0 ? .nothingToSave : landed)

        // Asking is the one drop that is not finished when it lands. The other
        // two are the whole gesture — the thing is held, or it is on the shelf —
        // where this one has only chosen what the question is about. So the
        // panel is kept up and put back on the page with the prompt bar on it,
        // rather than collapsing to a toast and making the user reopen it to
        // type the question they were already going to type.
        if zone == .ask, count > 0 {
            model.askRequests &+= 1
            open()
        }

        return count > 0
    }

    /// Clears the drop face. The panel itself stays open if the pointer is
    /// still on it — a drag ending is not a reason to take the island away from
    /// someone whose pointer is sitting in it.
    func endDrag() {
        model.isDropTargeted = false
        model.hoveredDropZone = nil
        NotchActivityCenter.shared.isDropTargeted = false
        scheduleClose()
    }

    private func scheduleClose() {
        closeTask?.cancel()
        closeTask = Task { [weak self] in
            try? await Task.sleep(for: Self.closeDelay)
            guard !Task.isCancelled else { return }
            guard let self, self.model.allowsAutoClose else { return }
            self.close()
        }
    }

    // MARK: - State

    func open() {
        openTask?.cancel()
        closeTask?.cancel()
        transition(to: .open)
    }

    func close() {
        openTask?.cancel()
        closeTask?.cancel()
        offerTask?.cancel()
        offerTask = nil
        model.promptText = ""
        model.isEditing = false
        // Every way out of the island is also a way out of the question — the
        // timer, Escape, a click elsewhere, and answering it. Closing is the one
        // place all of them meet.
        model.screenshotOffer = nil
        transition(to: NotchActivityCenter.shared.hasActivity ? .activity : .closed)
        releaseFocus()
    }

    func toggle() {
        model.state == .open ? close() : open()
    }

    private func transition(to newState: NotchState) {
        guard newState != model.state else { return }
        shrinkTask?.cancel()

        // A tap through the trackpad as the panel unfolds, so opening is felt
        // as well as seen — the same alignment tick a window snapping to a
        // guide uses. Silent on hardware without a Force Touch trackpad.
        if newState == .open {
            NSHapticFeedbackManager.defaultPerformer.perform(
                .alignment,
                performanceTime: .drawCompleted
            )
        }

        let target = frame(for: newState)
        let isGrowing = target.width * target.height
            > panel.frame.width * panel.frame.height

        if isGrowing {
            panel.setFrame(target, display: true)
        }

        withAnimation(Self.morph) {
            model.state = newState
        }

        if !isGrowing {
            // Held open until the collapse has played; the extra area is
            // invisible, but it is still the window's, so it cannot be given
            // back before the content has left it.
            shrinkTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(420))
                guard !Task.isCancelled, let self, self.model.state == newState else { return }
                // Recomputed rather than reused: a drag may have arrived while
                // the collapse was playing, and giving the area back under one
                // would put the notch out of reach again mid-gesture.
                self.applyFrame()
            }
        }
    }

    // MARK: - Focus

    /// Cove is an accessory app, so it is never "the frontmost app" by
    /// accident. Focus is taken on the first click inside the island and given
    /// straight back when it closes — hovering alone must never steal it.
    private func takeFocus() {
        guard !didTakeFocus else { return }
        didTakeFocus = true
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    private func releaseFocus() {
        guard didTakeFocus else { return }
        didTakeFocus = false
        panel.resignKey()
        // Hands the previous app its focus back. The panel survives because
        // `canHide` is false.
        NSApp.hide(nil)
    }

    // MARK: - Activity

    /// Keeps the closed island in step with the pipeline: something in flight
    /// pushes it out to the activity strip, and nothing in flight lets it fall
    /// back into the notch. An open island ignores all of it — the shelf is
    /// already showing the same work in more detail.
    private func observeActivity() {
        NotchActivityCenter.shared.onActivityChange = { [weak self] hasActivity in
            guard let self, self.model.state != .open else { return }
            self.transition(to: hasActivity ? .activity : .closed)
        }
    }

    // MARK: - Screenshots

    /// Hands each new screenshot to the island as a question.
    ///
    /// The watcher is started here rather than in the app delegate so the one
    /// object that can act on a capture is also the one that turns the source
    /// on: a watcher running with nothing listening would read the folder for
    /// no reason.
    private func observeScreenshots() {
        ScreenshotWatcher.shared.onCapture = { [weak self] capture in
            self?.offerScreenshot(capture)
        }
        ScreenshotWatcher.shared.start()
    }

    /// Opens the island with the screenshot in it.
    ///
    /// Deliberately without taking focus. A screenshot is taken in the middle of
    /// doing something else, and stealing the keyboard to ask a question nobody
    /// invited is worse than the question going unanswered — `open()` only
    /// orders the panel front, and focus is still taken on the first click, as
    /// everywhere else in the island.
    private func offerScreenshot(_ capture: ScreenshotWatcher.Capture) {
        // Never over a sentence being typed. The offer takes the panel, and
        // dismissing it clears the prompt with everything in it — so someone
        // mid-question would lose it to a question they did not ask. The file is
        // still in its folder either way, which makes staying quiet the cheap
        // side of this trade.
        guard !model.isEditing else { return }

        // A second shot while the first is still being asked about replaces it.
        // Stacking them would queue questions about work the user has already
        // moved on from.
        model.screenshotOffer = capture
        open()

        // An offer that arrives under the pointer is already being looked at;
        // the countdown starts when the pointer leaves.
        guard !isHovered else { return }
        scheduleOfferDismissal(after: Self.offerDelay)
    }

    private func scheduleOfferDismissal(after delay: Duration) {
        offerTask?.cancel()
        offerTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            guard let self, self.model.screenshotOffer != nil else { return }
            self.close()
        }
    }

    // MARK: - Focus loss

    /// A click anywhere else closes the island.
    ///
    /// Hover already handles the pointer wandering off, but not the case that
    /// matters most: clicking into the island (which makes it key) and then
    /// clicking back into whatever you were doing. Without this the panel
    /// stayed up over the window you had just returned to.
    private func observeFocusLoss() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(panelResignedKey),
            name: NSWindow.didResignKeyNotification,
            object: panel
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appResignedActive),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
    }

    @objc private func panelResignedKey() {
        guard model.isOpen, !model.holdsOpen, !model.isDropTargeted else { return }
        close()
    }

    @objc private func appResignedActive() {
        guard model.isOpen, !model.holdsOpen, !model.isDropTargeted else { return }
        close()
    }

    // MARK: - Screens

    private func observeScreenChanges() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @objc private func screensChanged() {
        guard let screen = NotchMetrics.preferredScreen(preferredDisplayID: metrics.displayID)
            ?? NotchMetrics.preferredScreen() else { return }
        metrics = NotchMetrics(screen: screen)
        model.metrics = metrics
        applyFrame()
    }

    /// Moves the island to another display — a laptop closed onto an external
    /// monitor is the common case, and the notch metrics differ per screen.
    func move(to screen: NSScreen) {
        metrics = NotchMetrics(screen: screen)
        model.metrics = metrics
        applyFrame()
    }
}

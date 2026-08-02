import AppKit
import Observation
import SwiftUI

/// Everything the SwiftUI side of the island reads, and the few things it asks
/// the AppKit side to do.
///
/// The window's frame and this object's `state` are changed together by
/// `NotchController` — the view never resizes the window itself, and the
/// controller never draws. The closures are the only line between them.
@MainActor
@Observable
final class NotchModel {
    var state: NotchState = .closed
    var metrics: NotchMetrics

    /// Whether reaching the notch unfolds the island. Off leaves it as a click
    /// target and a drop target only.
    var opensOnHover: Bool {
        didSet { UserDefaults.standard.set(opensOnHover, forKey: Self.hoverKey) }
    }
    /// A text field has focus. Auto-close is suspended while this is true:
    /// closing the panel mid-sentence loses the sentence.
    var isEditing = false
    /// Where a drop can land. Both are drawn by the panel; which one the drag
    /// is over is decided in AppKit, against the frames below.
    enum DropZone: String {
        case hold
        case save
    }

    /// A drag is over the island right now, so the panel is showing its two
    /// drop targets instead of the home face.
    var isDropTargeted = false
    /// Which target the drag is over, if either.
    var hoveredDropZone: DropZone?
    /// The targets' frames, in the panel's own coordinates, published by the
    /// view that draws them.
    ///
    /// Hit-testing a drop against these rather than letting each target be its
    /// own SwiftUI drop destination is deliberate: the island has to *grow* to
    /// meet an incoming drag, and a destination that appears underneath a drag
    /// session already in flight is not reliably picked up. One AppKit
    /// destination that exists before the drag arrives, plus these frames, is.
    var dropZoneFrames: [DropZone: CGRect] = [:]
    /// Held open regardless of hover or focus. Debug builds use it so a
    /// screenshot can catch the open state.
    var holdsOpen = false

    /// A screenshot has just been taken and the island is asking what to do
    /// with it.
    ///
    /// Held here rather than in the panel's own state because the controller is
    /// what acts on it: the island has to be opened to ask the question, and the
    /// question has to time out on its own — nobody asked to be interrupted, so
    /// an unanswered offer must not leave the panel hanging open.
    var screenshotOffer: ScreenshotWatcher.Capture?

    /// What has been typed into the prompt bar.
    var promptText = ""

    // Set by the controller.
    var requestOpen: () -> Void = {}
    var requestClose: () -> Void = {}
    /// Makes the panel key so it can be typed into. Called on first click and
    /// before focusing any field.
    var requestFocus: () -> Void = {}
    /// Moves the island to another display.
    var requestMove: (NSScreen) -> Void = { _ in }
    /// Tells the controller a drop is finished, so the panel can leave its
    /// two-target face.
    var requestEndDrag: () -> Void = {}

    private static let hoverKey = "cove.opensOnHover"

    init(metrics: NotchMetrics) {
        self.metrics = metrics
        // Defaults to on, which `bool(forKey:)` alone cannot express — an unset
        // key and an explicit `false` both read as false.
        let defaults = UserDefaults.standard
        opensOnHover = defaults.object(forKey: Self.hoverKey) as? Bool ?? true
    }

    var isOpen: Bool { state == .open }

    /// The size the expanded panel draws at, which is also the window's frame
    /// while open.
    var openSize: CGSize { metrics.frame(for: .open).size }
    var notchSize: CGSize { metrics.notchSize }

    /// Auto-close is only allowed when the user is plainly not using the panel.
    ///
    /// A screenshot offer blocks it too, and is dismissed by its own timer
    /// instead: the ordinary close runs 260 ms after the pointer leaves, and the
    /// pointer is nowhere near the notch when a screenshot lands — so the
    /// question would be gone before it had been read.
    var allowsAutoClose: Bool {
        !isEditing && !isDropTargeted && !holdsOpen && screenshotOffer == nil
    }
}

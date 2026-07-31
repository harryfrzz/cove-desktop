import AppKit

/// Where the island sits, and how big it is in each of its states.
///
/// All three frames hang off the top edge of one screen and share the notch's
/// horizontal centre, so growing and shrinking never moves the pill sideways —
/// the panel unfolds from exactly the shape the closed state left behind.
struct NotchMetrics: Equatable {
    /// The physical notch, or the pill Cove pretends is one on a screen that
    /// has no notch (external display, older Mac).
    let notchSize: CGSize
    let hasHardwareNotch: Bool
    /// Top edge of the screen, in global (bottom-left origin) coordinates.
    let screenTop: CGFloat
    let screenCenterX: CGFloat
    let screenWidth: CGFloat
    let displayID: CGDirectDisplayID

    /// Grab area either side of the notch when closed. The notch itself is
    /// physically unhoverable in the sense that matters — the cursor is drawn
    /// under it — so the target has to reach past its edges.
    static let closedInset: CGFloat = 18
    /// How far past each side of the notch the activity strip reaches. Wide
    /// enough for a glyph and a short line of status either side.
    static let compactSide: CGFloat = 92
    /// How far past the notch the *invisible* catch area reaches while a drag
    /// is in flight. Nothing is drawn here — it only decides where AppKit will
    /// offer a drag, and it has to be claimed before the session starts.
    ///
    /// Big enough to be aimed at while carrying a file, rather than demanding a
    /// 40pt strip of camera housing be hit exactly. The area is Cove's only for
    /// the length of a drag.
    static let dragCatchSide: CGFloat = 120
    static let dragCatchDepth: CGFloat = 90
    /// Sized to what is actually in it — the mark, the prompt bar, and room for
    /// two drop targets side by side. The panel got smaller every time
    /// something left it, which is the right way round.
    static let openSize = CGSize(width: 460, height: 232)
    /// The panel's own corner radius where it hangs below the notch.
    static let openCornerRadius: CGFloat = 26

    // MARK: - Reading the screen

    /// Metrics for the screen Cove should live on: the one with a real notch if
    /// there is one, otherwise the screen holding the menu bar.
    static func preferredScreen(preferredDisplayID: CGDirectDisplayID? = nil) -> NSScreen? {
        let screens = NSScreen.screens
        if let preferredDisplayID,
           let match = screens.first(where: { $0.displayID == preferredDisplayID }) {
            return match
        }
        return screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? screens.first
    }

    init(screen: NSScreen) {
        let frame = screen.frame
        screenTop = frame.maxY
        screenCenterX = frame.midX
        screenWidth = frame.width
        displayID = screen.displayID

        // `safeAreaInsets.top` is the camera housing's height on a notched
        // display and zero everywhere else, which is also the cleanest test for
        // whether this screen has one at all.
        let inset = screen.safeAreaInsets.top
        hasHardwareNotch = inset > 0

        if hasHardwareNotch,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            // The notch is the gap between the two usable menu-bar strips. Read
            // rather than hardcoded: it differs between the 14" and 16" panels,
            // and again on the Air.
            notchSize = CGSize(
                width: frame.width - left.width - right.width,
                height: inset
            )
        } else {
            // No notch to hide behind, so Cove draws its own pill in the same
            // place. Kept near the real thing's proportions so the expanded
            // panel reads the same on both.
            notchSize = CGSize(width: 190, height: max(NSStatusBar.system.thickness, 24))
        }
    }

    // MARK: - Frames

    /// Global frame for a given state. Every one of them is top-aligned to the
    /// screen and centred on the notch.
    func frame(for state: NotchState) -> CGRect {
        switch state {
        case .closed:
            size(
                width: notchSize.width + Self.closedInset * 2,
                height: notchSize.height + 4
            )
        case .activity:
            size(
                width: min(notchSize.width + Self.compactSide * 2, screenWidth - 40),
                height: notchSize.height + 12
            )
        case .open:
            size(
                width: min(Self.openSize.width, screenWidth - 48),
                height: min(Self.openSize.height, NSScreen.main?.frame.height ?? 900)
            )
        }
    }

    /// The window frame that lets a drag be *offered* to Cove. Unioned with
    /// whatever the current state's frame is while a drag session is live, and
    /// dropped again the moment it ends.
    var dragCatchFrame: CGRect {
        size(
            width: min(notchSize.width + Self.dragCatchSide * 2, screenWidth - 40),
            height: notchSize.height + Self.dragCatchDepth
        )
    }

    private func size(width: CGFloat, height: CGFloat) -> CGRect {
        CGRect(
            x: (screenCenterX - width / 2).rounded(),
            y: (screenTop - height).rounded(),
            width: width.rounded(),
            height: height.rounded()
        )
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) } ?? 0
    }
}

/// What the island is doing. The window frame, the shape, and what the SwiftUI
/// side draws all derive from this one value.
enum NotchState: Equatable {
    /// Hidden inside the notch. On a notched Mac this draws nothing at all.
    case closed
    /// The pipeline (or a drag) has something to say: a strip either side of
    /// the notch, in the spirit of the phone's Live Activity.
    case activity
    /// The full shelf, hanging below the notch.
    case open
}

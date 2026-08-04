import AppKit
import SwiftUI

/// The island's palette — Cove's identity: pure black, warm cream, and exactly
/// one accent, which is the only colour here the user gets to change. The
/// widget is built from the same three, which is what stops the two reading as
/// separate apps.
///
/// Unlike the phone app, this one does not follow the system appearance: the
/// panel hangs off a black notch and has to meet it seamlessly, so `surface`
/// and `panel` stay pure black always. Even the ocean-deep tone from the app
/// icon is too far from `#000000` to sit against the physical camera housing
/// without a visible seam — so the identity lives in everything else: the
/// accent, the warmth of the text, the tints.
enum CoveTheme {
    static let surface = Color.black
    static let panel = Color.black
    /// The one lift used for a control that has to look pressable — a tab, a
    /// field, a chip. Kept far below the level where it would read as a
    /// separate grey surface.
    ///
    /// Back to the ink rather than the accent. A lift tinted with the accent
    /// followed the chosen colour, which meant every field and chip in the app
    /// changed hue with the picker — six themes' worth of surfaces to check
    /// rather than six accents. The accent is the one thing that moves; the
    /// surfaces under it stay put.
    static let raised = Color(red: 0.96, green: 0.94, blue: 0.90).opacity(0.07)

    /// Warm foam, not clinical white — the same cream the icon's horizon glow
    /// fades into.
    static let ink = Color(red: 0.96, green: 0.94, blue: 0.90)
    static let inkSecondary = ink.opacity(0.56)
    static let inkTertiary = ink.opacity(0.34)

    static let hairline = ink.opacity(0.10)
    /// Cove's one accent — whichever of the six the user has chosen, Deep Water
    /// until they choose.
    ///
    /// Computed rather than stored, so a change in Settings reaches every
    /// surface without anything being threaded through. What makes that show up
    /// on screen is separate: SwiftUI only re-renders a view that *read* an
    /// observable during its body, so the two roots — `NotchRootView` and
    /// `CoveWindowView` — read the store's selection on purpose. Take those
    /// reads out and the accent changes in memory while the window keeps
    /// drawing the old one.
    /// Deep Water, always. The app's colour is not the user's to change — the
    /// six accents exist for the *widget*, where each tile carries its own and
    /// the choice is made in Edit Widget. An app that repainted itself to match
    /// would make the island and the window follow whichever tile was edited
    /// last, which is not a preference so much as a side effect.
    static let accent = Color(red: 0.24, green: 0.52, blue: 0.96)

    /// What may be printed *on* `accent`, which is not a constant and is the
    /// single most bug-prone thing in this file.
    ///
    /// Cream, because the accent is Deep Water and cream on it is 5.9:1. Still
    /// its own name rather than `ink` at the call sites: the two places that
    /// print on the accent got this wrong in both directions while the palette
    /// was being decided, and naming the relationship is what stops the next
    /// change from being a hunt.
    static let onAccent = ink

    /// The working-shimmer tone, and deliberately left alone.
    ///
    /// The warm orange is the island's, and it stays the island's. It was
    /// briefly changed to a cream on the argument that the accent is now
    /// user-chosen and three of the six themes are in orange's family — but the
    /// accent the app uses is Deep Water, the band only ever runs on the island
    /// and the window, and the shimmer is not ours to redecide.
    static let shimmer = Color(red: 0.98, green: 0.64, blue: 0.32)

    /// The library window's own backdrop: pure black in dark mode, pure white in
    /// light.
    ///
    /// This is the one part of Cove that follows the system appearance, and it
    /// is only the window — the island stays black always because it has to meet
    /// the camera housing, and the shelf's own cards and controls keep their own
    /// colours on top of this. The system's `.background` is a very dark grey
    /// rather than black, which reads as a lifted plate behind images that are
    /// themselves often near-black at the edges.
    static let windowBackground = Color(nsColor: .coveWindowBackground)

    /// The wordmark's colour in the window, opposite `windowBackground`.
    ///
    /// `ink` is a warm cream chosen to sit on true black, and on a white shelf
    /// it is very nearly invisible. This is its light-mode counterpart: the
    /// ocean-deep tone from the app icon rather than plain black, so the mark
    /// keeps Cove's identity instead of turning into system label text.
    static let windowInk = Color(nsColor: .coveWindowInk)
}

extension NSColor {
    /// A dynamic colour, so AppKit re-resolves it when the user switches
    /// appearance. `NSWindow.backgroundColor` is set from this too: without it,
    /// resizing or the moment before the first SwiftUI frame shows the window's
    /// default grey through the corners.
    static let coveWindowBackground = NSColor(name: "CoveWindowBackground") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .black : .white
    }

    /// Warm foam on black, ocean-deep on white — the two ends of the app icon's
    /// own gradient, so the mark reads as the same mark either way.
    static let coveWindowInk = NSColor(name: "CoveWindowInk") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.96, green: 0.94, blue: 0.90, alpha: 1)
            : NSColor(srgbRed: 0.07, green: 0.16, blue: 0.20, alpha: 1)
    }
}

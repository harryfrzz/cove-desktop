import AppKit
import SwiftUI

/// The island's palette — Cove's identity: a coastline seen from the water,
/// ocean-deep chrome with one seafoam accent.
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
    static let raised = Color(red: 0.96, green: 0.94, blue: 0.90).opacity(0.07)

    /// Warm foam, not clinical white — the same cream the icon's horizon glow
    /// fades into.
    static let ink = Color(red: 0.96, green: 0.94, blue: 0.90)
    static let inkSecondary = ink.opacity(0.56)
    static let inkTertiary = ink.opacity(0.34)

    static let hairline = ink.opacity(0.10)
    /// Cove's one accent — the seafoam that sits on the icon's horizon line,
    /// brightened enough to carry on true black. The same colour the working
    /// controls use.
    static let accent = Color(red: 0.42, green: 0.78, blue: 0.74)

    /// The original working-shimmer tone. The identity update changed the
    /// shared accent to seafoam, but the warm orange keeps the animated band
    /// recognisable as activity rather than a second static accent.
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

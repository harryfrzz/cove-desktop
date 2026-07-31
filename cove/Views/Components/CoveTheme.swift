import SwiftUI

/// The island's palette.
///
/// Unlike the phone app, this one does not follow the system appearance: the
/// panel hangs off a black notch and has to meet it seamlessly, so it is always
/// dark. A light island would draw a bright seam across the top of the screen
/// exactly where the hardware is blackest.
enum CoveTheme {
    /// Pure black throughout, top to bottom — the same black as the notch, so
    /// the panel reads as the hardware continuing rather than a dark window
    /// parked under it. Structure comes from hairlines, never from fills.
    static let surface = Color.black
    static let panel = Color.black
    /// The one lift used for a control that has to look pressable — a tab, a
    /// field, a chip. Kept far below the level where it would read as a
    /// separate grey surface.
    static let raised = Color.white.opacity(0.06)

    static let ink = Color(white: 0.97)
    static let inkSecondary = Color(white: 0.97).opacity(0.56)
    static let inkTertiary = Color(white: 0.97).opacity(0.34)

    static let hairline = Color.white.opacity(0.10)
    /// Cove's one warm accent — the same colour the working shimmer sweeps.
    static let accent = Color(red: 0.98, green: 0.64, blue: 0.32)
}

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
    /// shimmer sweeps.
    static let accent = Color(red: 0.42, green: 0.78, blue: 0.74)
}

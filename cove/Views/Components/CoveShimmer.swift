import SwiftUI

/// Cove's one "working" signal: a warm band that travels through whatever it is
/// applied to, rather than a spinner beside it.
///
/// Masked to its content, so it only ever lights the shape already on screen —
/// text, a glyph, a strip — and never paints a rectangle.
struct CoveShimmer: ViewModifier {
    var isActive: Bool
    /// Supplying a start time lets a caller begin at the leading clear edge and
    /// stop at a whole-cycle boundary rather than cutting a band in half.
    var startedAt: Date?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    /// The band is masked to its content, so it works by *replacing* the
    /// content's colour as it passes. On the dark island that means a near-white
    /// sweep lighting up cream text. On a white shelf the text is ocean-deep and
    /// the same white band would erase the letters for the length of the pass —
    /// so light mode sweeps in colour instead, which stays legible against the
    /// background while still reading as movement.
    ///
    /// The island pins its own colour scheme to dark, so it keeps the first
    /// treatment regardless of what the window is set to.
    private var bandColors: [Color] {
        colorScheme == .dark
            ? [.clear, Color.white.opacity(0.96), CoveTheme.shimmer.opacity(0.78), .clear]
            : [.clear, CoveTheme.accent.opacity(0.95), CoveTheme.shimmer.opacity(0.95), .clear]
    }

    /// One pass of the band.
    static let period: TimeInterval = 1.05
    /// Band width as a share of the content's own width.
    private static let bandShare: CGFloat = 0.62

    func body(content: Content) -> some View {
        content
            .overlay {
                TimelineView(
                    .animation(
                        minimumInterval: 1.0 / 30.0,
                        paused: !isActive || reduceMotion
                    )
                ) { timeline in
                    GeometryReader { proxy in
                        let width = max(proxy.size.width, 1)
                        let bandWidth = width * Self.bandShare
                        let elapsed = startedAt.map {
                            timeline.date.timeIntervalSince($0)
                        } ?? timeline.date.timeIntervalSinceReferenceDate
                        let phase = elapsed
                            .truncatingRemainder(dividingBy: Self.period) / Self.period

                        LinearGradient(
                            colors: bandColors,
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: bandWidth)
                        .rotationEffect(.degrees(-12))
                        .offset(x: -bandWidth + (width + bandWidth) * phase)
                    }
                }
                .mask(content)
                // Reduce Motion gets the dimmed content and no sweep; the state
                // is still legible from the wording beside it.
                .opacity(isActive && !reduceMotion ? 1 : 0)
                .allowsHitTesting(false)
            }
    }
}

extension View {
    /// Sweeps Cove's working highlight through this view while `isActive`.
    /// Pair it with a dimmed foreground so the band has something to lift.
    func coveShimmer(isActive: Bool) -> some View {
        modifier(CoveShimmer(isActive: isActive, startedAt: nil))
    }

    /// A controlled sweep that starts at `startedAt`. Use this for a finite
    /// operation whose shimmer must visibly run from edge to edge.
    func coveShimmer(isActive: Bool, startedAt: Date) -> some View {
        modifier(CoveShimmer(isActive: isActive, startedAt: startedAt))
    }
}

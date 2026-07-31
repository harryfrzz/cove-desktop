import SwiftUI

/// Cove's one "working" signal: a warm band that travels through whatever it is
/// applied to, rather than a spinner beside it.
///
/// Masked to its content, so it only ever lights the shape already on screen —
/// text, a glyph, a strip — and never paints a rectangle.
struct CoveShimmer: ViewModifier {
    var isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// One pass of the band.
    private static let period: TimeInterval = 1.05
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
                        let elapsed = timeline.date.timeIntervalSinceReferenceDate
                        let phase = elapsed
                            .truncatingRemainder(dividingBy: Self.period) / Self.period

                        LinearGradient(
                            colors: [
                                .clear,
                                Color.white.opacity(0.96),
                                CoveTheme.accent.opacity(0.78),
                                .clear
                            ],
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
        modifier(CoveShimmer(isActive: isActive))
    }
}

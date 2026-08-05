import SwiftUI

/// A message bubble in the shape Messages uses: a rounded rectangle whose
/// bottom corner on the speaker's side flares out into a tail and curls back.
///
/// The tail is what makes a stack of rounded rectangles read as a conversation.
/// Without one, alignment and colour are the only things saying who is talking,
/// and both fail in the case that matters most — a single short bubble with
/// nothing above it to be aligned against.
///
/// Only the last bubble of a run gets one, which is also what Messages does. A
/// tail on every bubble reads as several separate remarks; a tail on the last
/// reads as one person having finished speaking.
///
/// Drawn as a single continuous outline rather than a rounded rect with a tail
/// laid over it. Two overlapping subpaths are the obvious way to write this and
/// it is wrong: fills use the non-zero winding rule, so a tail wound against the
/// body subtracts from it instead of adding, and what renders is a wedge cut out
/// of the corner.
struct CoveBubbleShape: Shape {
    let isUser: Bool
    let hasTail: Bool
    var radius: CGFloat = 13

    /// Space along the speaker's edge that the tail occupies.
    ///
    /// Reserved whether or not this bubble has one, so every bubble in a run
    /// ends on the same vertical line. Subtracting it only when a tail is drawn
    /// would make the last bubble of a group a few points wider than the rest,
    /// which is a wobble the eye picks up immediately in a column.
    static let tailWidth: CGFloat = 5

    /// How far up the side the tail begins, how far the flare is pulled toward
    /// the top, and how far back under the bubble the curl returns — each a
    /// multiple of the corner radius, so the tail scales with the bubble rather
    /// than being a fixed size that looks wrong at one of them.
    private static let tailStart: CGFloat = 1.15
    private static let tailFlare: CGFloat = 0.55
    private static let tailCurl: CGFloat = 0.80

    func path(in rect: CGRect) -> Path {
        var body = rect
        body.size.width -= Self.tailWidth
        if !isUser { body.origin.x = rect.minX + Self.tailWidth }

        // A short bubble must not have corners taller than half of it, or the
        // arcs cross and the outline turns inside out.
        let plain = min(radius, min(body.width, body.height) / 2)

        guard hasTail, plain > 0 else {
            return Path(roundedRect: body, cornerRadius: plain, style: .continuous)
        }

        // The tailed side needs more headroom than a corner does: it spends the
        // top corner *and* `tailStart` radii of the bottom before the flare
        // begins, so on a one-line bubble that budget is what bounds the radius
        // rather than half the height.
        let r = min(plain, body.height / (1 + Self.tailStart))

        let top = body.minY
        let bottom = body.maxY
        let tip = isUser ? rect.maxX : rect.minX
        // Mirrors every horizontal offset, so the two sides are one shape rather
        // than two that happen to look alike.
        let s: CGFloat = isUser ? 1 : -1
        let near = isUser ? body.maxX : body.minX
        let far = isUser ? body.minX : body.maxX

        var path = Path()
        path.move(to: CGPoint(x: far + s * r, y: top))
        path.addLine(to: CGPoint(x: near - s * r, y: top))
        path.addQuadCurve(to: CGPoint(x: near, y: top + r), control: CGPoint(x: near, y: top))
        path.addLine(to: CGPoint(x: near, y: bottom - r * Self.tailStart))
        // Out to the tip, level with the bottom edge.
        path.addQuadCurve(
            to: CGPoint(x: tip, y: bottom),
            control: CGPoint(x: near, y: bottom - r * Self.tailFlare)
        )
        // And back under, concave, rejoining the bottom edge.
        path.addQuadCurve(
            to: CGPoint(x: near - s * r * Self.tailCurl, y: bottom),
            control: CGPoint(x: near - s * r * 0.25, y: bottom)
        )
        path.addLine(to: CGPoint(x: far + s * r, y: bottom))
        path.addQuadCurve(to: CGPoint(x: far, y: bottom - r), control: CGPoint(x: far, y: bottom))
        path.addLine(to: CGPoint(x: far, y: top + r))
        path.addQuadCurve(to: CGPoint(x: far + s * r, y: top), control: CGPoint(x: far, y: top))
        path.closeSubpath()
        return path
    }
}

extension Array where Element == ChatTurn {
    /// Whether the turn at `index` is the last thing that speaker says before
    /// the other one answers — so the one that carries the tail.
    func endsSpeakerRun(at index: Int) -> Bool {
        guard indices.contains(index) else { return false }
        let next = index + 1
        guard indices.contains(next) else { return true }
        return self[next].role != self[index].role
    }

    /// Gap above the turn at `index`: tight inside one speaker's run, open
    /// between them. The spacing is what groups the bubbles before any tail is
    /// read.
    func spacingBefore(at index: Int, tight: CGFloat, loose: CGFloat) -> CGFloat {
        guard index > 0 else { return 0 }
        return self[index - 1].role == self[index].role ? tight : loose
    }
}

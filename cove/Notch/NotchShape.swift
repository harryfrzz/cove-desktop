import SwiftUI

/// The island's outline: a rounded slab hanging from the top of the screen,
/// with the two upper corners curving *outward* into the screen edge.
///
/// Those inverted corners are what make the panel look moulded out of the notch
/// rather than stuck under it — without them the shape ends in two hard right
/// angles against the bezel and reads as a floating window that happens to be
/// at the top.
struct NotchShape: Shape {
    /// Radius of the outward flares where the shape meets the screen edge.
    var topRadius: CGFloat = 9
    /// Radius of the two free corners at the bottom.
    var bottomRadius: CGFloat

    /// Both radii animate, so growing from the notch pill to the open panel is
    /// one continuous morph rather than a shape swap partway through.
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        // The body of the shape is inset by the flare on each side; the flares
        // themselves are what reach back out to the full width.
        let bottom = min(bottomRadius, rect.height, rect.width / 2)
        let top = min(topRadius, max(rect.width / 2 - bottom, 0))

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + top, y: rect.minY + top),
            control: CGPoint(x: rect.minX + top, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX + top, y: rect.maxY - bottom))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + top + bottom, y: rect.maxY),
            control: CGPoint(x: rect.minX + top, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - top - bottom, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - top, y: rect.maxY - bottom),
            control: CGPoint(x: rect.maxX - top, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY + top))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - top, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}

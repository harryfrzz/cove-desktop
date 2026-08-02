import SwiftData
import SwiftUI

/// Root of everything drawn inside the panel: the store, the services, and the
/// island itself. Held apart from `NotchShell` so the environment is attached
/// exactly once, at the point AppKit hands SwiftUI the window.
struct NotchRootView: View {
    let model: NotchModel

    var body: some View {
        NotchShell(model: model)
            .modelContainer(CoveStore.shared)
            .environment(\.aiServices, .current)
            .environment(\.colorScheme, .dark)
    }
}

/// The island in each of its three states, and the morph between them.
///
/// The window is always at least as large as the shape drawn here — the
/// controller sees to that — so this view only ever has to worry about size and
/// content, never about the pointer or the frame.
struct NotchShell: View {
    @Bindable var model: NotchModel

    @State private var activity = NotchActivityCenter.shared

    private var notchWidth: CGFloat { model.notchSize.width }
    private var notchHeight: CGFloat { model.notchSize.height }

    private var islandSize: CGSize {
        switch model.state {
        case .closed:
            CGSize(width: notchWidth, height: notchHeight)
        case .activity:
            CGSize(
                width: min(
                    notchWidth + NotchMetrics.compactSide * 2,
                    model.metrics.screenWidth - 40
                ),
                height: notchHeight + 10
            )
        case .open:
            model.openSize
        }
    }

    private var bottomRadius: CGFloat {
        switch model.state {
        case .closed: 8
        case .activity: 14
        case .open: NotchMetrics.openCornerRadius
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            island
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var island: some View {
        ZStack(alignment: .top) {
            content
        }
        // The shelf is laid out at full size at all times and *clipped* by the
        // island's frame. That is what makes closing read as a collapse: the
        // panel is drawn into the notch rather than dissolved on the spot, and
        // the layout never has to reflow mid-animation.
        .frame(width: islandSize.width, height: islandSize.height, alignment: .top)
        .background {
            NotchShape(bottomRadius: bottomRadius)
                .fill(CoveTheme.surface)
        }
        .clipShape(NotchShape(bottomRadius: bottomRadius))
        .overlay {
            NotchShape(bottomRadius: bottomRadius)
                .stroke(
                    CoveTheme.hairline,
                    lineWidth: model.state == .open ? 1 : 0
                )
        }
        // No shadow. The panel is pure black and so is the notch it hangs from;
        // a drop shadow under a black shape on a bright wallpaper reads as a
        // grey halo around the island rather than as depth.
        .contentShape(NotchShape(bottomRadius: bottomRadius))
        // Clicking the closed pill is the keyboard-free way in, for when the
        // pointer is moving too fast for the hover delay to catch it.
        .onTapGesture {
            guard model.state != .open else { return }
            model.requestOpen()
        }
    }

    @ViewBuilder
    private var content: some View {
        // The panel stays mounted in every state so the collapse has something
        // to collapse. Its opacity is cut late rather than crossfaded: by the
        // time it goes, the frame has already swallowed nearly all of it, and a
        // fade over the whole gesture is what made closing look like a
        // dissolve instead of a movement.
        HomePanel(model: model, notchHeight: notchHeight)
            .frame(width: model.openSize.width, height: model.openSize.height, alignment: .top)
            .opacity(model.isOpen ? 1 : 0)
            .animation(
                .easeOut(duration: 0.10).delay(model.isOpen ? 0.06 : 0.16),
                value: model.isOpen
            )
            .allowsHitTesting(model.isOpen)

        if model.state == .activity {
            NotchActivityStrip(
                width: islandSize.width,
                notchWidth: notchWidth,
                height: notchHeight + 10,
                activity: activity
            )
            .transition(.opacity)
        }

        if model.state == .closed {
            closedContent
        }
    }

    /// Nothing at all on a Mac with a real notch — the shape *is* the notch. On
    /// a screen without one, a hairline pill so the island can be found.
    @ViewBuilder
    private var closedContent: some View {
        if !model.metrics.hasHardwareNotch {
            HStack(spacing: 5) {
                Circle()
                    .fill(CoveTheme.accent)
                    .frame(width: 5, height: 5)
                Text("Cove")
                    .font(.system(size: 10, weight: .semibold, design: .serif))
                    .foregroundStyle(CoveTheme.ink.opacity(0.75))
            }
            .frame(maxHeight: .infinity)
        }
    }

}

/// The closed island with something to say: one glyph and a line of status
/// either side of the notch, in the spirit of the phone's Live Activity.
private struct NotchActivityStrip: View {
    let width: CGFloat
    let notchWidth: CGFloat
    let height: CGFloat
    let activity: NotchActivityCenter

    /// The island may be clamped to the display width, so both status columns
    /// must derive from the width it was actually given — never from a flexible
    /// HStack proposal. That keeps the right-hand label inside the shape.
    private var centerWidth: CGFloat { min(notchWidth, width) }
    private var sideWidth: CGFloat { max(0, (width - centerWidth) / 2) }
    /// Breathing room between the island's rounded edge and what it says. The
    /// glyph and the word are the only things on this strip, and set flush to
    /// the corner they read as having been cut off by it.
    private var sideInset: CGFloat { min(20, sideWidth) }
    private var sideContentWidth: CGFloat { max(0, sideWidth - sideInset) }

    /// Whether the strip is reporting work still in progress.
    ///
    /// The band means "this is happening now" and nothing else. A capture that
    /// has landed is a settled fact, so "Added" and "Saved" are plain text —
    /// a shimmer there would say something is still running when nothing is.
    /// A failure is settled too, and red that also moves reads as an alarm.
    private var isWorking: Bool {
        guard !activity.isDropTargeted, activity.toast == nil else { return false }
        guard let headline = activity.headline else { return false }
        return headline.phase != .done && headline.phase != .failed
    }

    var body: some View {
        HStack(spacing: 0) {
            leading
                .frame(width: sideContentWidth, alignment: .leading)
                .clipped()
                .padding(.leading, sideInset)

            // The notch itself. Nothing may be drawn here — on the hardware
            // this is the camera housing.
            Color.clear.frame(width: centerWidth)

            trailing
                .frame(width: sideContentWidth, alignment: .trailing)
                .clipped()
                .padding(.trailing, sideInset)
        }
        .frame(width: width, height: height)
        .foregroundStyle(CoveTheme.ink)
    }

    @ViewBuilder
    private var leading: some View {
        // A toast outranks the pipeline here: it is the answer to something the
        // user just did, and it only lasts a moment.
        if let toast = activity.toast {
            HStack(spacing: 5) {
                Image(systemName: toast.systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(toast.isFailure ? .red : CoveTheme.accent)

                if let count = toast.count {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.white.opacity(0.14), in: Capsule())
                }
            }
        } else if activity.isDropTargeted {
            Label("Drop to save", systemImage: "tray.and.arrow.down.fill")
                .labelStyle(.iconOnly)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(CoveTheme.accent)
        } else if let headline = activity.headline {
            Image(systemName: icon(for: headline))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(
                    headline.phase == .failed ? .red : CoveTheme.accent
                )
                .symbolEffect(.pulse, isActive: headline.phase != .done)
        } else {
            Circle()
                .fill(CoveTheme.accent)
                .frame(width: 6, height: 6)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if let toast = activity.toast {
            Text(toast.text)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        } else if activity.isDropTargeted {
            Text("Drop to save")
                .font(.system(size: 11, weight: .semibold))
        } else if let headline = activity.headline {
            HStack(spacing: 7) {
                Text(headline.phase.label)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .shimmeringStatus(isActive: isWorking)
                if activity.inFlight.count > 1 {
                    Text("\(activity.inFlight.count)")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.white.opacity(0.14), in: Capsule())
                }
            }
        }
    }

    private func icon(for snapshot: ShelfActivitySnapshot) -> String {
        switch snapshot.phase {
        case .done: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        default: "sparkles"
        }
    }
}

private extension View {
    /// The status word, with Cove's band running through it while a capture is
    /// still being worked on.
    ///
    /// Only the word. The glyph beside it already carries its own motion — a
    /// pulse while processing, a settled checkmark once saved — and a second
    /// animation on the same small strip reads as two things happening rather
    /// than one.
    func shimmeringStatus(isActive: Bool) -> some View {
        // Dimmed underneath, so the band has something to lift rather than
        // washing over text that is already at full brightness.
        opacity(isActive ? 0.55 : 1)
            .coveShimmer(isActive: isActive)
            .animation(.easeInOut(duration: 0.2), value: isActive)
    }
}

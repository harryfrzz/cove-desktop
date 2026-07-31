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
        .shadow(
            color: .black.opacity(model.state == .open ? 0.55 : 0),
            radius: 24,
            y: 10
        )
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
    let notchWidth: CGFloat
    let height: CGFloat
    let activity: NotchActivityCenter

    var body: some View {
        HStack(spacing: 0) {
            leading
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 14)

            // The notch itself. Nothing may be drawn here — on the hardware
            // this is the camera housing.
            Color.clear.frame(width: notchWidth)

            trailing
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 14)
        }
        .frame(height: height)
        .foregroundStyle(CoveTheme.ink)
    }

    @ViewBuilder
    private var leading: some View {
        if activity.isDropTargeted {
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
            Text(toast)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
        } else if activity.isDropTargeted {
            Text("Drop to save")
                .font(.system(size: 11, weight: .semibold))
        } else if let headline = activity.headline {
            HStack(spacing: 7) {
                Text(headline.phase.label)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
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

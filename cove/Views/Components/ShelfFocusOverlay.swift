import SwiftUI

/// One item, lifted out of the shelf.
///
/// The frame is where the card sat when it was clicked, in global space, so the
/// lifted copy can start exactly on top of the real one and grow from there
/// rather than appearing from nowhere.
struct ShelfFocusTarget: Identifiable, Equatable {
    let itemID: UUID
    let frame: CGRect

    var id: UUID { itemID }
}

/// What a focused item offers. Kept as data rather than a `Menu` so the overlay
/// can lay the actions out itself — a system menu would cover the very card the
/// blur just spent effort isolating.
struct ShelfFocusAction: Identifiable {
    let id = UUID()
    let title: String
    let systemImage: String
    var isDestructive = false
    let perform: () -> Void
}

/// The lifted card and its actions, drawn over a blurred shelf.
///
/// Deliberately not a `contextMenu`: the point of the interaction is that
/// everything else recedes and one thing is left in focus, which a menu floating
/// over an unchanged grid does not do. The card grows a little from where it
/// already was, so it reads as the same object rather than a preview of it.
struct ShelfFocusOverlay<Cover: View>: View {
    let target: ShelfFocusTarget
    let title: String
    let subtitle: String?
    let actions: [ShelfFocusAction]
    let onDismiss: () -> Void
    @ViewBuilder let cover: () -> Cover

    /// Enough to read as "picked up" without the card jumping somewhere new.
    private static var liftScale: CGFloat { 1.06 }
    private static var panelWidth: CGFloat { 230 }

    @State private var isPresented = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                // Anywhere off the card puts it back.
                Color.black.opacity(isPresented ? 0.28 : 0)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture(perform: dismiss)

                card
                    .frame(width: target.frame.width, height: target.frame.height)
                    .scaleEffect(isPresented ? Self.liftScale : 1)
                    .position(x: target.frame.midX, y: target.frame.midY)

                panel
                    .frame(width: Self.panelWidth)
                    .position(panelCenter(in: proxy.size))
                    .opacity(isPresented ? 1 : 0)
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.82), value: isPresented)
        }
        .onAppear { isPresented = true }
        // Escape is the expected way out of a mode like this.
        .onExitCommand(perform: dismiss)
    }

    private var card: some View {
        cover()
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.white.opacity(0.22), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.45), radius: 26, y: 14)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)

                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)

            Divider()

            ForEach(actions) { action in
                Button {
                    action.perform()
                    onDismiss()
                } label: {
                    Label(action.title, systemImage: action.systemImage)
                        .font(.callout)
                        .foregroundStyle(action.isDestructive ? Color.red : Color.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 4)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.primary.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.32), radius: 18, y: 8)
    }

    /// Sits under the card by default, and flips above it when there is no room
    /// below — a panel half off the bottom of the window would hide its own
    /// destructive action.
    private func panelCenter(in size: CGSize) -> CGPoint {
        let estimatedHeight = 64 + CGFloat(actions.count) * 36
        let gap: CGFloat = 14
        let liftedHalf = target.frame.height * Self.liftScale / 2

        let below = target.frame.midY + liftedHalf + gap + estimatedHeight / 2
        let above = target.frame.midY - liftedHalf - gap - estimatedHeight / 2
        let y = below + estimatedHeight / 2 > size.height ? above : below

        return CGPoint(
            x: min(max(target.frame.midX, Self.panelWidth / 2 + 12), size.width - Self.panelWidth / 2 - 12),
            y: min(max(y, estimatedHeight / 2 + 12), size.height - estimatedHeight / 2 - 12)
        )
    }

    private func dismiss() {
        isPresented = false
        onDismiss()
    }
}

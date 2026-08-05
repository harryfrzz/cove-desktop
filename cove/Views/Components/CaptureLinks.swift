import AppKit
import SwiftUI

/// The captures an answer is holding out, and what clicking one does.
///
/// An answer stores the ids it offered, never the addresses. Resolving happens
/// here, at the moment of drawing, against the live shelf — so a link the user
/// clicks is always the shelf's own record of where that capture points, and a
/// capture deleted since the answer was given quietly stops being offered
/// rather than opening something that is no longer there.
enum CaptureLinks {
    /// The captures behind `ids`, in the order they were offered, skipping any
    /// that have gone or have nothing to open.
    static func resolve(_ ids: [UUID], in items: [ShelfItem]) -> [ShelfItem] {
        ids.compactMap { id in
            items.first { $0.id == id && $0.linkURL != nil }
        }
    }

    static func open(_ item: ShelfItem) {
        guard let url = item.linkURL else { return }
        NSWorkspace.shared.open(url)
    }
}

/// One offered capture on the island: a row you click to go there.
///
/// A row rather than the address written into the sentence. The panel is 460pt
/// wide and shows a handful of lines, so a URL printed into the prose is
/// truncated before it is even readable — and when the answer is "you have two
/// of these", the second one is the half that gets cut. Given a row each, both
/// are on screen and either can be taken.
struct IslandCaptureLink: View {
    let item: ShelfItem

    @State private var isHovered = false

    var body: some View {
        Button {
            CaptureLinks.open(item)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: item.kind.systemImage)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(CoveTheme.accent)
                    .frame(width: 13)

                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(CoveTheme.accent)
                        .underline(isHovered)
                        .lineLimit(1)

                    if let host = item.linkHost, !host.isEmpty {
                        Text(host)
                            .font(.system(size: 9))
                            .foregroundStyle(CoveTheme.inkTertiary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(isHovered ? CoveTheme.accent : CoveTheme.inkTertiary)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(
                isHovered ? CoveTheme.accent.opacity(0.14) : CoveTheme.raised,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        isHovered ? CoveTheme.accent.opacity(0.55) : CoveTheme.hairline,
                        lineWidth: 1
                    )
            }
            // The whole row takes the click, not just the words in it.
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.snappy(duration: 0.14), value: isHovered)
        // The address, for the one moment somebody wants to check where a link
        // goes before taking it.
        .help(item.linkURL?.absoluteString ?? item.title)
        .accessibilityLabel("Open \(item.title)")
    }
}

/// The same offer in the window, where there is room for it to look like the
/// link it is rather than like a button.
struct WindowCaptureLink: View {
    let item: ShelfItem

    @State private var isHovered = false

    var body: some View {
        Button {
            CaptureLinks.open(item)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: item.kind.systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(CoveTheme.accent)

                Text(item.title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(CoveTheme.accent)
                    .underline(isHovered)
                    .lineLimit(1)

                if let host = item.linkHost, !host.isEmpty {
                    Text(host)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Image(systemName: "arrow.up.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(isHovered ? CoveTheme.accent : .secondary)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(
                isHovered ? CoveTheme.accent.opacity(0.14) : .primary.opacity(0.05),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        isHovered ? CoveTheme.accent.opacity(0.55) : .primary.opacity(0.10),
                        lineWidth: 1
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.snappy(duration: 0.14), value: isHovered)
        .help(item.linkURL?.absoluteString ?? item.title)
        .accessibilityLabel("Open \(item.title)")
    }
}

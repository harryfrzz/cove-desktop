import SwiftUI

/// Whether the chat screen's offer to connect has been waved away.
///
/// Persisted, because a banner that came back on every launch would be a
/// notification rather than an offer. Dismissing it is not the same as refusing
/// the permissions — nothing is asked of the system here — so Settings keeps the
/// connections whether or not this was ever shown.
@MainActor
@Observable
final class ConnectionsBannerState {
    static let shared = ConnectionsBannerState()

    private static let key = "cove.connectionsBannerDismissed"

    private(set) var isDismissed: Bool

    private init() {
        isDismissed = UserDefaults.standard.bool(forKey: Self.key)
    }

    func dismiss() {
        isDismissed = true
        UserDefaults.standard.set(true, forKey: Self.key)
    }

    /// Brought back by Settings, for someone who dismissed it and then changed
    /// their mind about the apps.
    func restore() {
        isDismissed = false
        UserDefaults.standard.set(false, forKey: Self.key)
    }
}

/// The offer to let Cove reach Calendar, Reminders and Notes, above the
/// transcript where the asking happens.
///
/// It appears only while there is something left to ask — a grant that has been
/// refused is an answer, and re-offering it would be nagging about a decision
/// already made. Dismissing it is remembered.
///
/// Deliberately in the chat area rather than over the shelf. These connections
/// only matter to the half of Cove that takes instructions, and a banner about
/// Calendar over a wall of screenshots is an interruption about something the
/// user is not doing.
struct ConnectionsBanner: View {
    @State private var connections = CoveConnections.shared
    @State private var banner = ConnectionsBannerState.shared
    @State private var isWorking = false

    var body: some View {
        if !banner.isDismissed, connections.hasUnasked {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "app.connected.to.app.below.fill")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(CoveTheme.accent)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Let Cove use your other apps")
                        .font(.callout.weight(.semibold))

                    Text("Ask it to add an event, a reminder or a note, and it will — once Calendar, Reminders and Notes are connected.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Button {
                    Task { await connectAll() }
                } label: {
                    Text(isWorking ? "Connecting…" : "Connect")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(CoveTheme.accent.opacity(0.16), in: Capsule())
                        .foregroundStyle(CoveTheme.accent)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isWorking)

                Button {
                    banner.dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.primary.opacity(0.08), lineWidth: 1)
            }
            .padding(.horizontal, 22)
            .padding(.top, 14)
            .transition(.opacity.combined(with: .move(edge: .top)))
            .animation(.easeOut(duration: 0.25), value: banner.isDismissed)
            .animation(.easeOut(duration: 0.25), value: connections.hasUnasked)
        }
    }

    /// Asks for all three in turn rather than at once.
    ///
    /// macOS shows one permission sheet at a time and queues the rest behind it;
    /// firing them together produces a stack of prompts with no order and no
    /// explanation of which is which. Sequential is slower to click through and
    /// far easier to understand.
    private func connectAll() async {
        isWorking = true
        defer { isWorking = false }

        if connections.calendar == .notAsked { await connections.connectCalendar() }
        if connections.reminders == .notAsked { await connections.connectReminders() }
        if connections.notes == .notAsked { await connections.connectNotes() }
    }
}

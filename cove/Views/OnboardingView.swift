import AppKit
import SwiftUI

/// Whether the first run has been done with, and the one place that is decided.
///
/// A plain flag rather than a version number. Versioned onboarding sounds like
/// foresight and behaves like a bug: bumping it puts a five-page introduction in
/// front of everyone who has been using Cove for months, to tell them about a
/// feature a release note would have covered. If a later version needs to say
/// something, it should say it where the thing is.
@MainActor
@Observable
final class CoveOnboarding {
    static let shared = CoveOnboarding()

    private static let key = "cove.hasOnboarded"

    /// Read once at launch. Nothing else writes this key, so re-reading it would
    /// only be asking `UserDefaults` a question this already knows the answer
    /// to.
    private(set) var isFinished: Bool

    private init() {
        isFinished = UserDefaults.standard.bool(forKey: Self.key)
    }

    func finish() {
        isFinished = true
        UserDefaults.standard.set(true, forKey: Self.key)
    }

    /// Puts the flow back. Only Settings calls this — it is a way to re-read
    /// what Cove said at the start, not a state the app enters on its own.
    func reset() {
        isFinished = false
        UserDefaults.standard.set(false, forKey: Self.key)
    }
}

/// What Cove says the first time the window is opened.
///
/// Five pages, and each one either explains something the app cannot show on its
/// own or hands over a switch that is genuinely better decided now than found
/// later. Nothing here is a tour of buttons: the shelf explains itself the
/// moment something is dropped on it, and a page describing that would be a page
/// nobody reads.
///
/// The two that carry switches are the ones with a cost attached — watching the
/// screenshot folder asks macOS for access to it, and asking Cove things needs
/// Apple Intelligence turned on in System Settings. Both are easier to say yes
/// to when the reason is on screen, which is the argument for onboarding at all.
struct OnboardingView: View {
    let onFinish: () -> Void

    @State private var page: Page = .welcome
    @State private var screenshots = ScreenshotWatcher.shared
    /// Shared rather than page-owned, so a download started here keeps running
    /// if the introduction is finished mid-way, and Settings shows it still
    /// going instead of an idle button.
    @State private var installer = MobileCLIPInstaller.shared
    /// Held rather than read once, so the Apple Intelligence page follows the
    /// model finishing its download while someone is looking at it.
    @State private var assistant = CoveAssistant.shared

    private enum Page: Int, CaseIterable, Comparable {
        case welcome
        case island
        case screenshots
        case search
        case asking
        case ready

        static func < (a: Page, b: Page) -> Bool { a.rawValue < b.rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Keyed on the page so each one arrives rather than having its
                // words swapped underneath it.
                .id(page)
                .transition(.opacity)

            footer
        }
        .background(CoveTheme.windowBackground)
        .animation(.easeInOut(duration: 0.22), value: page)
    }

    // MARK: - Pages

    @ViewBuilder
    private var content: some View {
        switch page {
        case .welcome:
            // No title: the wordmark is the title. Set as both, the page said
            // "Cove" twice in two sizes, which reads as a layout mistake rather
            // than as emphasis.
            page(
                icon: nil,
                title: nil,
                body: """
                    A shelf for the things you are keeping for later — screenshots, \
                    links, notes and files. Everything stays on this Mac.
                    """
            ) {
                OnboardingMark {
                    Text("Cove")
                        .font(.system(size: 64, weight: .semibold, design: .serif))
                        .foregroundStyle(.primary)
                }
                .padding(.bottom, 4)
            }

        case .island:
            page(
                icon: "rectangle.topthird.inset.filled",
                title: "Drop it on the notch",
                body: """
                    Drag anything to the top of the screen and Cove opens to take it. \
                    Press ⌘V there to save whatever is on the clipboard, or hold \
                    something in the tray to hand it to another app.
                    """
            )

        case .screenshots:
            page(
                icon: "camera.viewfinder",
                title: "Catch screenshots as they land",
                body: """
                    Cove can watch the folder macOS saves screenshots to and offer \
                    each new one on the island, so keeping it is one click and \
                    ignoring it costs nothing.
                    """
            ) {
                Toggle("Offer new screenshots", isOn: $screenshots.isEnabled)
                    .toggleStyle(.switch)
                    .font(.body.weight(.medium))

                // Said before the system asks rather than after. macOS will put
                // up its own permission sheet the first time the folder is read,
                // and a prompt that arrives with no explanation is the one people
                // deny.
                Text("macOS will ask for access to the folder the first time.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

        case .search:
            page(
                icon: "magnifyingglass",
                title: "Search reads what you saved",
                body: """
                    Cove encodes every capture on this Mac, so a search can reach a \
                    screenshot that never contained the words you typed. The encoders \
                    ship with the app and are already working.
                    """
            ) {
                encoderSetup
            }

        case .asking:
            page(
                icon: "sparkles",
                title: "Ask Cove what you saved",
                body: """
                    Questions go to the same shelf, in sentences rather than search \
                    terms — and Cove can open what it finds.
                    """
            ) {
                assistantStatus
            }

        case .ready:
            page(
                icon: "checkmark.circle",
                title: "That is all of it",
                body: """
                    Cove lives in the menu bar and on the notch. Everything here can \
                    be changed later in Settings.
                    """
            )
        }
    }

    /// The encoders, and the optional download of a fresh pair.
    ///
    /// Worded carefully, because the honest version is not the one this control
    /// implies. Cove ships with working encoders and search is on before anyone
    /// reads this page — the download fetches a fresh ~200 MB copy from Apple's
    /// conversions that takes precedence over the bundled one. That is a repair,
    /// or a way to pick up a newer conversion, and offering it as *setup* would
    /// tell a first-time user that a feature already working needs 200 MB before
    /// it does. So the state comes first and the button is plainly optional.
    @ViewBuilder
    private var encoderSetup: some View {
        VStack(spacing: 12) {
            switch installer.phase {
            case .idle, .finished, .failed:
                if case .failed(let reason) = installer.phase {
                    Text(reason)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                } else if case .finished = installer.phase {
                    Label("Fresh copy installed", systemImage: "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Label(
                        installer.hasOverride ? "Using a downloaded copy" : "Ready to search",
                        systemImage: "checkmark.circle.fill"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }

                Button {
                    Task { await installer.install() }
                } label: {
                    Text(installer.hasOverride ? "Download Again (~200 MB)" : "Download a Fresh Copy (~200 MB)")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(CoveTheme.accent)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(CoveTheme.accent.opacity(0.14), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)

                Text("Optional — only worth it to repair a bad model.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

            case .measuring:
                progress(nil, label: "Checking the download size…")

            case .downloading(let fraction):
                progress(fraction, label: "Downloading… \(Int(fraction * 100))%")

            case .compiling:
                // Core ML compilation reports nothing, so neither does this.
                progress(nil, label: "Compiling for this Mac…")

            case .preparing:
                progress(nil, label: "Preparing albums…")
            }
        }
        .frame(maxWidth: 360)
        .animation(.easeInOut(duration: 0.2), value: installer.phase)
    }

    /// A determinate bar while there are bytes to count and an indeterminate one
    /// while there are not. Compilation has no fraction to report, and a bar
    /// frozen at 100% would read as a hang.
    private func progress(_ fraction: Double?, label: String) -> some View {
        VStack(spacing: 8) {
            if let fraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }

            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(width: 300)
    }

    /// Whether the written half of asking is available, and what to do when it
    /// is not.
    ///
    /// The page is worth showing either way: search works without Apple
    /// Intelligence and is most of what the feature is. This only governs
    /// whether Cove can answer in sentences.
    @ViewBuilder
    private var assistantStatus: some View {
        switch assistant.readiness {
        case .ready:
            Label("Apple Intelligence is on, so Cove can answer in sentences.", systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.secondary)

        case .unavailable(let reason):
            VStack(spacing: 10) {
                Text(reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Text("Without it Cove still searches your shelf and shows what matched.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)

                Button {
                    NSWorkspace.shared.open(
                        URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")!
                    )
                } label: {
                    Text("Open System Settings")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(CoveTheme.accent)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(CoveTheme.accent.opacity(0.14), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// One page's furniture, so five pages cannot drift apart in spacing or
    /// type. `accessory` is whatever that page hands over — a switch, a status,
    /// or nothing.
    private func page<Accessory: View>(
        icon: String?,
        title: String?,
        body text: String,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() }
    ) -> some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)

            if let icon {
                OnboardingMark {
                    Image(systemName: icon)
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(CoveTheme.accent)
                }
                .accessibilityHidden(true)
            }

            accessory()

            if let title {
                Text(title)
                    .font(.title.weight(.semibold))
                    .multilineTextAlignment(.center)
            }

            Text(text)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                // Narrow on purpose. A paragraph that runs the full width of a
                // 960pt window is one the eye loses its place in.
                .frame(maxWidth: 420)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer

    /// Two arrows and the dots, on the page rather than on a bar of their own.
    ///
    /// The bar was the default thing to reach for and it was wrong here: it drew
    /// a hard grey edge across the bottom of a black window, which made a page
    /// with nothing but a wordmark on it look like a dialog with a footer. The
    /// controls sit on the same surface as the words now, and the page is one
    /// thing.
    private var footer: some View {
        ZStack {
            // Laid over the row rather than placed inside it. Between two
            // spacers the dots centre themselves in whatever space the controls
            // leave, which is a different centre on every page — they slid left
            // the moment the back arrow was absent. They mark position and must
            // not appear to move.
            dots

            HStack(spacing: 14) {
                // Present from the second page on, and kept out of the layout
                // rather than disabled on the first: a permanently dead control
                // teaches people to stop reading that corner.
                if page != .welcome {
                    arrow("chevron.left", prominent: false) { step(-1) }
                        .accessibilityLabel("Back")
                        .transition(.opacity)
                }

                Spacer()

                // Skipping is offered until the last page, where going on *is*
                // finishing and two controls doing the same thing would be a
                // question with one answer.
                if page != .ready {
                    Button("Skip", action: onFinish)
                        .buttonStyle(.plain)
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }

                arrow(page == .ready ? "checkmark" : "chevron.right", prominent: true) {
                    page == .ready ? onFinish() : step(1)
                }
                .accessibilityLabel(page == .ready ? "Start using Cove" : "Continue")
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 24)
    }

    /// The island's send button at window size: a glyph in a filled circle. Cove
    /// already navigates this way in the one other place it has a forward
    /// action, and matching it costs nothing.
    private func arrow(_ symbol: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(prominent ? AnyShapeStyle(CoveTheme.onAccent) : AnyShapeStyle(.secondary))
                .frame(width: 34, height: 34)
                .background(
                    Circle().fill(
                        prominent ? AnyShapeStyle(CoveTheme.accent) : AnyShapeStyle(.primary.opacity(0.08))
                    )
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private var dots: some View {
        HStack(spacing: 6) {
            ForEach(Page.allCases, id: \.rawValue) { candidate in
                Circle()
                    .fill(candidate == page ? AnyShapeStyle(CoveTheme.accent) : AnyShapeStyle(.quaternary))
                    .frame(width: 6, height: 6)
            }
        }
        .animation(.easeOut(duration: 0.2), value: page)
        .accessibilityHidden(true)
    }

    private func step(_ delta: Int) {
        guard let next = Page(rawValue: page.rawValue + delta) else { return }
        page = next
    }
}

/// A page's mark, lit by Cove's shimmer as the page arrives and then left at
/// rest.
///
/// A few passes rather than a loop. The shimmer is Cove's working signal
/// everywhere else in the app, and one running forever under a paragraph would
/// say the introduction is busy doing something — as well as being a moving
/// object competing with the words it is meant to introduce. Running it once on
/// arrival keeps the arrival and drops the claim.
///
/// The base dims underneath it, which is not decoration: the band works by
/// replacing the content's colour as it passes, so it needs something darker to
/// lift. Against a window's full-strength label colour in dark mode the band is
/// white on near-white and there is nothing to see.
///
/// Self-triggering, because the pages remount — `content` is keyed on the page —
/// so appearing is the same event as being switched to, and no timing has to be
/// coordinated from outside.
private struct OnboardingMark<Content: View>: View {
    @ViewBuilder var content: Content

    /// Whole passes of the band, so it stops at the clear edge rather than
    /// cutting a lit band in half.
    private static var passes: Double { 2 }

    @State private var isShimmering = false
    @State private var startedAt = Date.now

    var body: some View {
        content
            .opacity(isShimmering ? 0.45 : 1)
            .coveShimmer(isActive: isShimmering, startedAt: startedAt)
            .animation(.easeOut(duration: 0.35), value: isShimmering)
            .task {
                startedAt = .now
                isShimmering = true
                try? await Task.sleep(for: .seconds(CoveShimmer.period * Self.passes))
                isShimmering = false
            }
    }
}

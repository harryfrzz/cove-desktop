import AppKit
import SwiftUI

/// What Cove is running, in one screen.
///
/// Deliberately short. Every line is read from the live stack rather than
/// written into it — whether the encoders loaded, how much of the shelf they
/// have covered — but a page that lists tensor widths and compute units is a
/// diagnostics dump, and nobody opens Settings to read one. What matters is
/// whether a thing is on, how far it has got, and the one switch that decides
/// if Cove ever touches the network.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model = SettingsModel()
    /// Shared singletons rather than page-owned state: an install started here
    /// keeps running if the sheet is dismissed, and reopening Settings shows it
    /// still going instead of an idle button.
    @State private var installer = MobileCLIPInstaller.shared
    @State private var updater = UpdateChecker.shared
    @State private var appearance = CoveAppearanceStore.shared
    @State private var screenshots = ScreenshotWatcher.shared
    /// Held rather than read once, so the row follows Apple Intelligence
    /// finishing its download while this page is open.
    @State private var assistant = CoveAssistant.shared
    @State private var onboarding = CoveOnboarding.shared

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    appearanceSection
                    onThisMac
                    screenshotSection
                    holdingSection
                    modelSection
                    shelfSection
                    privacySection
                    updatesSection
                    introductionSection
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 480, height: 470)
        .background(CoveTheme.windowBackground)
        .task { await model.load() }
    }

    private var header: some View {
        HStack {
            Text("Settings")
                .font(.title3.weight(.semibold))

            Spacer()

            Button("Done") { dismiss() }
                .buttonStyle(.glass)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private var onThisMac: some View {
        SettingsSection("On this Mac") {
            SettingsRow("Embeddings", value: model.modelName, badge: model.modelBadge)
            SettingsRow("Albums", value: model.classifierName, badge: model.classifierBadge)
            SettingsRow("Text recognition", value: "Vision", badge: "On")
            // Both of these were fixed strings, and both had become untrue.
            // This page is the one place Cove says what it is actually running,
            // so a hardcoded answer here is worse than no page.
            SettingsRow("Search", value: searchName, badge: "On")
            if assistant.isReady {
                SettingsRow("Language model", value: "Apple Intelligence", badge: "On")
            } else if case .unavailable(let reason) = assistant.readiness {
                SettingsRow("Language model", value: reason, tone: .muted)
            }

            if let failure = model.modelFailure {
                SettingsRow("Problem", value: failure, tone: .warning)
            }
        }
    }

    /// Search says which half is actually running.
    ///
    /// The semantic half needs MobileCLIP's text tower to encode the query, so
    /// on a Mac where the encoders are missing it is not merely off — it cannot
    /// start. Saying "Keyword" there is the truth, and saying it everywhere was
    /// the bug.
    private var searchName: String {
        AIServices.current.embeddings == nil ? "Keyword" : "Meaning and keyword"
    }

    private var appearanceSection: some View {
        SettingsSection("Appearance") {
            Picker(
                "Theme",
                selection: Binding(
                    get: { appearance.selection },
                    set: { appearance.selection = $0 }
                )
            ) {
                ForEach(CoveAppearance.allCases) { candidate in
                    Label(candidate.title, systemImage: candidate.systemImage)
                        .tag(candidate)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text("Sets the window's theme. The island stays dark — it meets the black notch and cannot have a seam.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

        }
    }

    /// The switch, and where Cove is watching.
    ///
    /// The folder is shown but not editable, because it is not Cove's to set:
    /// macOS owns it, the Screenshot app's "Save to" menu is where it changes,
    /// and a second control here would be a place for the two to disagree.
    private var screenshotSection: some View {
        SettingsSection("Screenshots") {
            Toggle(
                "Offer new screenshots on the island",
                isOn: Binding(
                    get: { screenshots.isEnabled },
                    set: { screenshots.isEnabled = $0 }
                )
            )
            .toggleStyle(.switch)

            SettingsRow(
                "Folder",
                value: screenshots.folderPath ?? "Reading…",
                badge: screenshots.isWatching ? "On" : nil,
                tone: screenshots.isWatching ? .normal : .muted
            )

            if let failure = screenshots.failure {
                SettingsRow("Problem", value: failure, tone: .warning)
            }

            Text("Take a screenshot and the island opens with it, offering the same two answers a drop does. Cove follows wherever macOS is set to save them — there is nothing to point it at. Only new screenshots are read, and only to ask about them; nothing is copied to the shelf unless you say so.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// What the holding shelf does once something has been carried off it.
    private var holdingSection: some View {
        SettingsSection("Holding shelf") {
            Toggle(
                "Let go once something is dropped",
                isOn: Binding(
                    get: { model.clearsHeldAfterDrag },
                    set: { model.clearsHeldAfterDrag = $0 }
                )
            )
            .toggleStyle(.switch)

            Text("Off, a held thing stays on the island until you remove it — so the same file can be dropped in two places. On, it lets go as soon as something accepts it. A drag released over nothing is not a drop, and never clears it either way.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Installing, repairing, and re-running setup for the encoders.
    private var modelSection: some View {
        SettingsSection("Embedding model") {
            SettingsRow("Loaded from", value: model.modelSource)

            switch installer.phase {
            case .measuring:
                SettingsRow("Status", value: "Checking download size…", tone: .muted)
            case .downloading(let fraction):
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: fraction)
                    Text("Downloading — \(Int(fraction * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .compiling:
                SettingsRow("Status", value: "Compiling for this Mac…", tone: .muted)
            case .preparing:
                SettingsRow("Status", value: "Re-encoding album prompts…", tone: .muted)
            case .finished:
                SettingsRow("Status", value: "Ready", badge: "On")
            case .failed(let reason):
                SettingsRow("Status", value: reason, tone: .warning)
            case .idle:
                EmptyView()
            }

            HStack(spacing: 10) {
                Button(installer.hasOverride ? "Reinstall" : "Install") {
                    Task {
                        await installer.install()
                        await model.load()
                    }
                }
                .disabled(installer.isBusy)

                Button("Run Setup") {
                    Task {
                        await installer.rerunSetup()
                        await model.load()
                    }
                }
                .disabled(installer.isBusy)
                .help("Rebuilds the album prompt vectors without re-downloading")

                if installer.hasOverride {
                    Button("Use Bundled") {
                        Task {
                            await installer.removeOverride()
                            await model.load()
                        }
                    }
                    .disabled(installer.isBusy)
                    .help("Deletes the downloaded copy and falls back to the model inside Cove")
                }
            }
            .padding(.top, 4)

            Text("Cove ships with a working model. Installing downloads a fresh copy (~200 MB) to Application Support, which takes precedence — use it to repair a bad model or to try a converted one.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var updatesSection: some View {
        SettingsSection("Updates") {
            SettingsRow("Version", value: updater.currentVersion)

            switch updater.state {
            case .checking:
                SettingsRow("Status", value: "Checking…", tone: .muted)
            case .upToDate:
                SettingsRow("Status", value: "Cove is up to date", badge: "On")
            case .available(let version, _):
                SettingsRow("Status", value: "Version \(version) is available")
            case .failed(let reason):
                SettingsRow("Status", value: reason, tone: .warning)
            case .idle:
                EmptyView()
            }

            HStack(spacing: 10) {
                Button("Check for Updates") {
                    Task { await updater.check() }
                }
                .disabled(updater.isChecking)

                if case .available(_, let url) = updater.state {
                    Button("Open Release") { NSWorkspace.shared.open(url) }
                }

                if updater.isChecking {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.top, 4)
        }
    }

    private var introductionSection: some View {
        SettingsSection("Introduction") {
            SettingsRow(
                "First run",
                value: onboarding.isFinished ? "Done" : "Showing"
            )

            // The only way back to it. Everything the introduction sets is on
            // this page too, so this is for reading what Cove said rather than
            // for changing anything — which is why it says "Show" and not
            // "Reset".
            Button("Show Introduction Again") {
                onboarding.reset()
                dismiss()
            }
            .disabled(!onboarding.isFinished)
            .padding(.top, 4)
        }
    }

    private var shelfSection: some View {
        SettingsSection("Shelf") {
            SettingsRow("Saved items", value: "\(model.coverage.totalItems)")
            SettingsRow("Photos embedded", value: model.imageCoverage)

            HStack(spacing: 10) {
                Button("Re-index Shelf") {
                    Task { await model.reindex() }
                }
                .disabled(!model.isEmbeddingAvailable || model.isWorking)

                if model.isWorking {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.top, 4)
        }
    }

    private var privacySection: some View {
        SettingsSection("Privacy") {
            Toggle(
                "Fetch link previews",
                isOn: Binding(
                    get: { model.fetchLinkPreviews },
                    set: { model.fetchLinkPreviews = $0 }
                )
            )
            .toggleStyle(.switch)

            // The one claim on this page worth spelling out, because it is the
            // one a user cannot check for themselves.
            Text("Everything else stays on this Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - State

@MainActor
@Observable
private final class SettingsModel {
    var status: MobileCLIPEmbeddingService.Status?
    var coverage = EmbeddingCoverage()
    var isWorking = false

    var fetchLinkPreviews: Bool = LinkPreviewService.isEnabled {
        didSet { LinkPreviewService.setEnabled(fetchLinkPreviews) }
    }

    var clearsHeldAfterDrag: Bool = TempTray.clearsAfterDrag {
        didSet { TempTray.setClearsAfterDrag(clearsHeldAfterDrag) }
    }

    func load() async {
        status = await MobileCLIPEmbeddingService.shared.status()
        coverage = await ShelfProcessor.shared.embeddingCoverage()
    }

    /// Puts every stored item back through the encoders. This is the button that
    /// matters after a model changes: items captured beforehand hold no vector
    /// at all, and nothing else in the app goes back for them.
    func reindex() async {
        isWorking = true
        defer { isWorking = false }

        await ShelfProcessor.shared.refreshAll()
        while await ShelfProcessor.shared.isBusy {
            try? await Task.sleep(for: .milliseconds(300))
        }
        await load()
    }

    var isEmbeddingAvailable: Bool { status?.isLoaded == true }

    var modelName: String { MobileCLIPModelDescriptor.current.displayName }

    var modelBadge: String {
        guard let status else { return "…" }
        if status.isLoaded { return "On" }
        return status.isInstalled ? "Failed" : "Missing"
    }

    var modelFailure: String? { status?.failure }

    /// Which of the two locations the encoders came from — the app bundle, or a
    /// downloaded copy in Application Support that overrides it.
    var modelSource: String {
        guard let source = status?.imageSource ?? status?.textSource else {
            return "Not found"
        }
        return source.label
    }

    var classifierName: String {
        isEmbeddingAvailable ? "Sorted by image, zero-shot" : "Vision labels"
    }

    var classifierBadge: String { isEmbeddingAvailable ? "On" : "Fallback" }

    /// "12 of 40". An empty shelf says so rather than reading "0 of 0", which
    /// looks like a failure.
    var imageCoverage: String {
        guard coverage.totalImages > 0 else { return "No photos saved yet" }
        return "\(coverage.embeddedImages) of \(coverage.totalImages)"
    }
}

// MARK: - Building blocks

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)

            VStack(alignment: .leading, spacing: 9) {
                content
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CoveTheme.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.primary.opacity(0.08), lineWidth: 1)
            }
        }
    }
}

private struct SettingsRow: View {
    enum Tone {
        case normal
        case muted
        case warning
    }

    let label: String
    let value: String
    var badge: String?
    var tone: Tone = .normal

    init(_ label: String, value: String, badge: String? = nil, tone: Tone = .normal) {
        self.label = label
        self.value = value
        self.badge = badge
        self.tone = tone
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .leading)

            Text(value)
                .font(.subheadline)
                .foregroundStyle(colour)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let badge {
                Text(badge)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(badgeForeground(badge))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(badgeForeground(badge).opacity(0.16), in: Capsule())
            }
        }
    }

    private var colour: Color {
        switch tone {
        case .normal: .primary
        case .muted: .secondary
        case .warning: .red
        }
    }

    /// Green only for a state that is genuinely working. "Fallback" and
    /// "Missing" are not failures worth alarming anyone about, but they are not
    /// the good case either.
    private func badgeForeground(_ badge: String) -> Color {
        switch badge {
        case "On": CoveTheme.accent
        case "Failed": .red
        default: .secondary
        }
    }
}

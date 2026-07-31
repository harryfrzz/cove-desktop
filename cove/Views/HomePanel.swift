import SwiftData
import SwiftUI

/// The open island.
///
/// One face, three states: the mark on its own, the mark replaced by an answer
/// while a prompt is in flight, and the two drop targets while something is
/// being dragged over it. Everything else Cove can do is reachable from a drop
/// or from the prompt bar, so there is nothing else on screen to reach for.
struct HomePanel: View {
    @Bindable var model: NotchModel
    /// Height of the strip along the top that the camera housing occupies.
    /// Nothing may be drawn inside it.
    let notchHeight: CGFloat

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ChatThread.updatedAt, order: .reverse) private var threads: [ChatThread]

    @State private var tray = TempTray.shared
    @State private var activity = NotchActivityCenter.shared
    @State private var answer: String?
    @State private var isThinking = false
    @FocusState private var isPromptFocused: Bool

    /// Breathing room on every edge. Generous on purpose: the panel holds very
    /// little, and what little it holds should not look wedged into a corner.
    private static let inset: CGFloat = 22

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: max(notchHeight, 30))

            if model.isDropTargeted {
                DropTargets(model: model)
                    .padding(.horizontal, Self.inset)
                    .padding(.bottom, Self.inset)
                    .transition(.opacity)
            } else {
                centrepiece
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, Self.inset)

                if !tray.isEmpty {
                    TrayStrip(tray: tray)
                        .padding(.horizontal, Self.inset)
                        .padding(.bottom, 14)
                }

                promptBar
                    .padding(.horizontal, Self.inset)
                    .padding(.bottom, Self.inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.snappy(duration: 0.24), value: model.isDropTargeted)
        .animation(.snappy(duration: 0.24), value: tray.entries.count)
        // Escape closes, like any other transient panel.
        .onExitCommand { model.requestClose() }
        .background {
            // `⌘V` is the fastest capture Cove has: whatever is on the
            // clipboard, on the shelf, without moving the pointer.
            Button("Paste", action: captureClipboard)
                .keyboardShortcut("v", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .onChange(of: isPromptFocused) { _, focused in
            model.isEditing = focused
        }
    }

    // MARK: - Centre

    /// The mark, or the last answer in its place. The shimmer is Cove's one
    /// "working" signal and it lives here for the same reason it lived on the
    /// phone's title: whatever is thinking should be the thing you are already
    /// looking at.
    @ViewBuilder
    private var centrepiece: some View {
        if let answer {
            Text(answer)
                .font(.system(size: 12))
                .foregroundStyle(CoveTheme.inkSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .transition(.opacity)
        } else {
            Text("Cove")
                .font(.system(size: 34, weight: .semibold, design: .serif))
                .foregroundStyle(CoveTheme.ink.opacity(isThinking ? 0.4 : 0.92))
                .coveShimmer(isActive: isThinking)
                .animation(.easeInOut(duration: 0.25), value: isThinking)
        }
    }

    // MARK: - Prompt

    private var promptBar: some View {
        HStack(spacing: 9) {
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(CoveTheme.accent)

            TextField("Ask Cove…", text: $model.promptText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(CoveTheme.ink)
                .focused($isPromptFocused)
                .onSubmit(submit)
                // Clicking has to make the panel key first, or the field takes
                // focus that keystrokes never reach.
                .onTapGesture { model.requestFocus() }

            Button(action: submit) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(CoveTheme.surface)
                    .frame(width: 20, height: 20)
                    .background(
                        Circle().fill(
                            model.promptText.isEmpty ? CoveTheme.inkTertiary : CoveTheme.ink
                        )
                    )
            }
            .buttonStyle(.plain)
            .disabled(model.promptText.trimmingCharacters(in: .whitespaces).isEmpty || isThinking)
        }
        .padding(.leading, 14)
        .padding(.trailing, 5)
        .frame(height: 34)
        .frame(maxWidth: 320)
        .background(CoveTheme.raised, in: Capsule())
        .overlay {
            Capsule().strokeBorder(CoveTheme.hairline, lineWidth: 1)
        }
        .frame(maxWidth: .infinity)
    }

    /// Stores both sides of the exchange and shows the reply where the mark
    /// was. The model that would write that reply is not in this build, so the
    /// reply says exactly that rather than sounding like an answer.
    private func submit() {
        let question = model.promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isThinking else { return }
        model.promptText = ""
        isThinking = true

        let thread: ChatThread
        if let existing = threads.first {
            thread = existing
        } else {
            thread = ChatThread()
            modelContext.insert(thread)
        }

        let reply = "Cove’s on-device model isn’t wired up yet, so there’s no answer to give — the question is saved."

        modelContext.insert(thread.append(role: .user, text: question))
        modelContext.insert(thread.append(role: .assistant, text: reply))
        try? modelContext.save()

        Task {
            // Long enough for the shimmer to read as work rather than a flicker.
            try? await Task.sleep(for: .milliseconds(900))
            withAnimation(.easeInOut(duration: 0.2)) {
                isThinking = false
                answer = reply
            }
            try? await Task.sleep(for: .seconds(6))
            withAnimation(.easeInOut(duration: 0.25)) { answer = nil }
        }
    }

    private func captureClipboard() {
        guard let item = CaptureIngest.itemFromClipboard() else {
            activity.post("Nothing Cove can hold on the clipboard")
            return
        }
        CaptureIngest.insert(item, into: modelContext)
    }
}

// MARK: - Drop targets

/// The choice a drag lands on: park it, or keep it.
///
/// Two targets rather than one because they mean different things and cannot be
/// undone into each other — parked things vanish on quit, saved things are on
/// the shelf until deleted. Asking at the moment of the drop is the only point
/// where the user still has both intentions in mind.
private struct DropTargets: View {
    @Bindable var model: NotchModel

    var body: some View {
        HStack(spacing: 14) {
            target(
                zone: .hold,
                title: "Hold here",
                subtitle: "Until you quit",
                systemImage: "tray.full",
                tint: CoveTheme.ink
            )

            target(
                zone: .save,
                title: "Add to Cove",
                subtitle: "Saved to the shelf",
                systemImage: "square.stack.3d.up.fill",
                tint: CoveTheme.accent
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Each target publishes its frame and draws its state; the drag itself is
    /// hit-tested against those frames in AppKit, which is the only place that
    /// reliably sees a drag that arrived before the panel had opened.
    private func target(
        zone: NotchModel.DropZone,
        title: String,
        subtitle: String,
        systemImage: String,
        tint: Color
    ) -> some View {
        let isTargeted = model.hoveredDropZone == zone

        return VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(isTargeted ? tint : tint.opacity(0.65))
            VStack(spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(CoveTheme.ink)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(CoveTheme.inkTertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            isTargeted ? tint.opacity(0.14) : Color.white.opacity(0.03),
            in: .rect(cornerRadius: 16)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(
                    isTargeted ? tint.opacity(0.85) : CoveTheme.hairline,
                    style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: isTargeted ? [] : [5, 4])
                )
        }
        .scaleEffect(isTargeted ? 1.02 : 1)
        .animation(.snappy(duration: 0.16), value: isTargeted)
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .global)
        } action: { frame in
            model.dropZoneFrames[zone] = frame
        }
    }
}

// MARK: - Tray

/// What is parked right now: a row of chips, each one draggable straight back
/// out to wherever it was headed.
private struct TrayStrip: View {
    @Bindable var tray: TempTray

    var body: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal) {
                HStack(spacing: 7) {
                    ForEach(tray.entries) { entry in
                        chip(entry)
                    }
                }
                .padding(.horizontal, 1)
            }
            .scrollIndicators(.never)

            Button {
                tray.clear()
            } label: {
                Text("Clear")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(CoveTheme.inkTertiary)
            }
            .buttonStyle(.plain)
            .help("Empty the holding shelf")
        }
        .frame(height: 30)
    }

    private func chip(_ entry: TempTray.Entry) -> some View {
        HStack(spacing: 6) {
            Image(nsImage: entry.icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)
            Text(entry.name)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(CoveTheme.ink)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(CoveTheme.raised, in: Capsule())
        .overlay {
            Capsule().strokeBorder(CoveTheme.hairline, lineWidth: 1)
        }
        .onDrag { entry.provider() }
        .contextMenu {
            Button("Remove", systemImage: "xmark") { tray.remove(entry) }
        }
        .help(entry.name)
    }
}

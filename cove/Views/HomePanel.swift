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
    /// Which page the scroll view has settled on. Optional because that is what
    /// `scrollPosition(id:)` reports — it is briefly `nil` mid-flight, which is
    /// not a third page, so readers fall back to home.
    @State private var scrolledPage: Page? = .home

    private var page: Page { scrolledPage ?? .home }

    private enum Page: Hashable, CaseIterable {
        case home
        case chats
    }

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
                pages
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Its own row rather than an overlay pinned to the bottom of
                // the pages. Floating, the dots landed hard against the prompt
                // bar and read as specks on it.
                pageDots
                    .padding(.top, 2)
                    .padding(.bottom, 12)

                if !tray.isEmpty {
                    TrayStrip(tray: tray)
                        .padding(.horizontal, Self.inset)
                        .padding(.bottom, 14)
                }

                // Only on the home page. Asking something is what the mark is
                // for; the history is for reading what was already asked, and
                // on a panel this short the bar's height is the difference
                // between three visible rows and five.
                if page == .home {
                    promptBar
                        .padding(.horizontal, Self.inset)
                        .padding(.bottom, Self.inset)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.snappy(duration: 0.24), value: model.isDropTargeted)
        .animation(.snappy(duration: 0.24), value: tray.entries.count)
        .animation(.snappy(duration: 0.28), value: page)
        .onChange(of: page) { _, current in
            // A field that is gone should not still hold the keystrokes. Left
            // focused, typing on the history page would land in a prompt bar
            // that isn't on screen.
            if current != .home { isPromptFocused = false }
        }
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

    // MARK: - Pages

    /// The panel's two faces, side by side: the mark and whatever it is saying,
    /// and the history of what has been asked.
    ///
    /// Swiping rather than a tab bar or a button. The island is small enough
    /// that a control costs a real fraction of the surface, and there are only
    /// two pages — a horizontal drag is unambiguous with two, and the dots say
    /// so without taking a row.
    private var pages: some View {
        GeometryReader { proxy in
            let width = proxy.size.width

            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    // Padding inside the fixed width, not outside it. Applied
                    // after the frame it would add to the page's width, and the
                    // page would no longer be a page wide.
                    centrepiece
                        .padding(.horizontal, Self.inset)
                        .frame(width: width)
                        .id(Page.home)

                    ChatHistoryPage(threads: threads)
                        .frame(width: width)
                        .id(Page.chats)
                }
                .scrollTargetLayout()
            }
            // A two-finger swipe on a trackpad is a scroll event, not a drag —
            // no button is ever pressed, so a `DragGesture` never hears it. A
            // paging scroll view is the thing that does, and it comes with the
            // rubber-banding at the ends and the velocity-aware snap that would
            // otherwise have to be written by hand.
            .scrollTargetBehavior(.paging)
            .scrollIndicators(.never)
            .scrollPosition(id: $scrolledPage)
        }
    }

    private var pageDots: some View {
        HStack(spacing: 5) {
            ForEach(Page.allCases, id: \.self) { candidate in
                Circle()
                    .fill(CoveTheme.ink.opacity(candidate == page ? 0.65 : 0.22))
                    .frame(width: 4, height: 4)
            }
        }
        .padding(.bottom, 2)
        .animation(.easeOut(duration: 0.2), value: page)
        // Purely an indicator: a swipe that starts on the dots has to reach the
        // pages underneath, and there is nothing here worth clicking.
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
            activity.post(.nothingToSave)
            return
        }
        CaptureIngest.insert(item, into: modelContext)
    }
}

// MARK: - Chat history

/// What has been asked, newest first — and, once a row is opened, what was said
/// back.
///
/// Two levels rather than a navigation stack: the island is one small surface
/// and a push animation across it reads as the whole panel leaving. Opening a
/// thread swaps the list for the transcript in place, and the same chevron
/// brings the list back.
private struct ChatHistoryPage: View {
    let threads: [ChatThread]

    @State private var openThread: ChatThread?

    private static let inset: CGFloat = 22

    var body: some View {
        Group {
            if let openThread {
                transcript(of: openThread)
            } else if threads.isEmpty {
                empty
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.snappy(duration: 0.22), value: openThread?.id)
    }

    private var empty: some View {
        VStack(spacing: 7) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(CoveTheme.inkTertiary)

            Text("No chats yet")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(CoveTheme.inkSecondary)

            Text("Ask Cove something and it will be kept here.")
                .font(.system(size: 10))
                .foregroundStyle(CoveTheme.inkTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, Self.inset)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 8) {
            header("Recent")

            ScrollView {
                VStack(spacing: 7) {
                    ForEach(threads) { thread in
                        Button {
                            openThread = thread
                        } label: {
                            row(thread)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Self.inset)
                .padding(.bottom, 6)
            }
            .scrollIndicators(.never)
        }
    }

    private func row(_ thread: ChatThread) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(thread.title.isEmpty ? "Untitled" : thread.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(CoveTheme.ink)
                    .lineLimit(1)

                if let reply = thread.orderedTurns.last(where: { $0.role == .assistant }) {
                    Text(reply.text)
                        .font(.system(size: 10))
                        .foregroundStyle(CoveTheme.inkTertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(thread.updatedAt.formatted(.relative(presentation: .numeric, unitsStyle: .narrow)))
                .font(.system(size: 9))
                .foregroundStyle(CoveTheme.inkTertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        // A hit area the width of the row, not the width of the words.
        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .background(CoveTheme.raised, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private func transcript(of thread: ChatThread) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                openThread = nil
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 9, weight: .semibold))
                    Text(thread.title.isEmpty ? "Untitled" : thread.title)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(CoveTheme.inkSecondary)
                .padding(.horizontal, Self.inset)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            ScrollView {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(thread.orderedTurns) { turn in
                        bubble(turn)
                    }
                }
                .padding(.horizontal, Self.inset)
                .padding(.bottom, 6)
            }
            .scrollIndicators(.never)
        }
    }

    /// The user's turn sits right and tinted, Cove's sits left and plain — the
    /// arrangement every transcript uses, so no label is needed to say who said
    /// what.
    private func bubble(_ turn: ChatTurn) -> some View {
        let isUser = turn.role == .user

        return Text(turn.text)
            .font(.system(size: 10))
            .foregroundStyle(isUser ? CoveTheme.surface : CoveTheme.ink)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                isUser ? AnyShapeStyle(CoveTheme.accent) : AnyShapeStyle(CoveTheme.raised),
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
            .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
            .textSelection(.enabled)
    }

    private func header(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(CoveTheme.inkTertiary)
            .padding(.horizontal, Self.inset)
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

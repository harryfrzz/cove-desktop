import SwiftData
import SwiftUI

/// What has been asked of Cove, and where it can be asked more.
///
/// A screen rather than a sheet, and that is the difference between reading a
/// conversation and being in one. A sheet is a thing you dismiss to get back to
/// work; this is somewhere to sit, so it takes the window the way an album does
/// and leaves by the same back button.
///
/// The island keeps the same threads on its second page, but not the same way.
/// That surface is 460pt wide, so it shows the list or one conversation and
/// swaps between them, and a transcript read there arrives four lines at a time.
/// Here both are on screen at once. It is written separately rather than shared
/// for the same reason: the island's version is sized in 9 to 11 point type
/// against a panel that is black whatever the system is doing, and lifting it
/// into a window that follows the appearance would put cream text on white.
struct ChatHistoryScreen: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ChatThread.updatedAt, order: .reverse) private var threads: [ChatThread]
    /// The shelf, for grounding a question in it. Newest first, and narrowed to
    /// a handful by the search before any of it reaches the model.
    @Query(sort: \ShelfItem.createdAt, order: .reverse) private var items: [ShelfItem]

    /// Which conversation is being read. Held by id rather than by the model
    /// object so a thread deleted elsewhere leaves an empty pane rather than a
    /// dangling reference.
    @State private var selection: ChatThread.ID?
    /// A conversation being started but not yet spoken into. There is no thread
    /// behind this yet — one is made by asking, not by clicking New — so it is a
    /// state of this screen rather than a row in the store.
    @State private var isStartingNew = false
    @State private var draft = ""
    /// Held so the bar appears by itself if Apple Intelligence finishes
    /// downloading while the screen is open.
    @State private var assistant = CoveAssistant.shared
    @FocusState private var isPromptFocused: Bool

    /// The thread on show, or nil while a new one is being started.
    private var openThread: ChatThread? {
        guard !isStartingNew else { return nil }
        return threads.first { $0.id == selection } ?? threads.first
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 244)

            Divider()

            conversation
                .frame(maxWidth: .infinity)
        }
        .background(CoveTheme.windowBackground)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Chats")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    startNew()
                } label: {
                    Label("New Chat", systemImage: "square.and.pencil")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Start a new conversation")
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)

            ScrollView {
                LazyVStack(spacing: 4) {
                    if isStartingNew {
                        newRow
                    }

                    ForEach(threads) { thread in
                        Button {
                            open(thread)
                        } label: {
                            row(thread)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.automatic)
        }
    }

    /// The conversation that does not exist yet, standing where it will be. It
    /// keeps the list from appearing to ignore the New button on an empty shelf
    /// of chats.
    private var newRow: some View {
        Text("New conversation")
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(
                CoveTheme.accent.opacity(0.20),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
    }

    private func row(_ thread: ChatThread) -> some View {
        let isOpen = thread.id == openThread?.id

        return VStack(alignment: .leading, spacing: 3) {
            Text(thread.title.isEmpty ? "Untitled" : thread.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)

            if let reply = thread.orderedTurns.last(where: { $0.role == .assistant }) {
                Text(reply.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Text(thread.updatedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        // A hit area the width of the row, not the width of the words.
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .background(
            isOpen ? CoveTheme.accent.opacity(0.20) : Color.clear,
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
    }

    // MARK: - Conversation

    private var conversation: some View {
        VStack(spacing: 0) {
            transcript
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            promptBar
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
        }
    }

    @ViewBuilder
    private var transcript: some View {
        if let openThread {
            ScrollViewReader { proxy in
                ScrollView {
                    let turns = openThread.orderedTurns

                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(turns.enumerated()), id: \.element.id) { index, turn in
                            bubble(turn, hasTail: turns.endsSpeakerRun(at: index))
                                .padding(.top, turns.spacingBefore(at: index, tight: 3, loose: 12))
                                .id(turn.id)
                        }
                    }
                    .padding(22)
                }
                // A reply added below the fold is a reply nobody sees. The last
                // turn is what the screen is about, so it is what stays in view.
                .onChange(of: openThread.turns.count) { _, _ in
                    scrollToEnd(proxy, in: openThread)
                }
                .onChange(of: openThread.id) { _, _ in
                    scrollToEnd(proxy, in: openThread)
                }
                .onAppear { scrollToEnd(proxy, in: openThread) }
            }
        } else {
            empty
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy, in thread: ChatThread) {
        guard let last = thread.orderedTurns.last else { return }
        proxy.scrollTo(last.id, anchor: .bottom)
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.tertiary)

            Text(threads.isEmpty ? "No chats yet" : "New conversation")
                .font(.title3.weight(.semibold))

            // Says why there is nowhere to type when there is nowhere to type,
            // rather than pointing at a bar that is not drawn.
            Text(prompt)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    /// Says what asking will actually do, which is not the same on every Mac.
    /// Without the model there is still a search behind the bar, so this names
    /// the reduced thing rather than reading as an apology for a dead control.
    private var prompt: String {
        switch assistant.readiness {
        case .ready:
            "Ask Cove something below. It is kept here and on the island."
        case .unavailable(let reason):
            "\(reason) You can still search your shelf from the bar below."
        }
    }

    /// The user's turn sits right and tinted, Cove's sits left and plain — the
    /// arrangement every transcript uses, so no label is needed to say who said
    /// what.
    private func bubble(_ turn: ChatTurn, hasTail: Bool) -> some View {
        let isUser = turn.role == .user

        return Text(turn.text)
            .font(.body)
            // Asked for rather than picked. Which of cream or black reads on the
            // user's bubble depends on which of the six accents is selected. The
            // other side takes the system's label colour, which is what makes it
            // readable in both appearances.
            .foregroundStyle(isUser ? AnyShapeStyle(CoveTheme.onAccent) : AnyShapeStyle(.primary))
            .textSelection(.enabled)
            .padding(.vertical, 9)
            .padding(.horizontal, 14)
            .padding(isUser ? .trailing : .leading, CoveBubbleShape.tailWidth)
            .background(
                isUser ? AnyShapeStyle(CoveTheme.accent) : AnyShapeStyle(.primary.opacity(0.07)),
                // Larger radius than the island's: the same shape at window type
                // size, not the same number of points.
                in: CoveBubbleShape(isUser: isUser, hasTail: hasTail, radius: 17)
            )
            // Short answers should not be stretched across the pane, and long
            // ones should not run the full width of a wide window — either way
            // the eye loses the line it was on.
            .frame(maxWidth: 460, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    // MARK: - Asking

    private var promptBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(CoveTheme.accent)

            TextField(assistant.isReady ? "Ask Cove…" : "Search your shelf…", text: $draft)
                .textFieldStyle(.plain)
                .font(.body)
                .focused($isPromptFocused)
                .onSubmit(send)

            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(CoveTheme.surface)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(canSend ? CoveTheme.accent : Color.secondary))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .frame(height: 40)
        .background(.primary.opacity(0.05), in: Capsule())
        .overlay { Capsule().strokeBorder(.primary.opacity(0.12), lineWidth: 1) }
        .contentShape(Capsule())
        .onTapGesture { isPromptFocused = true }
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Continues whichever conversation is open, or starts one if this is the
    /// first thing said.
    ///
    /// The thread is only known once the answer is back — it is `CoveChat` that
    /// makes one, and only after there is something to put in it — so selecting
    /// it waits for that rather than guessing.
    private func send() {
        guard canSend else { return }
        let question = draft
        draft = ""
        isPromptFocused = true

        Task {
            guard let exchange = await CoveChat.ask(
                question,
                in: openThread,
                shelf: items,
                context: modelContext
            ) else { return }

            selection = exchange.thread.id
            isStartingNew = false
        }
    }

    private func startNew() {
        isStartingNew = true
        selection = nil
        draft = ""
        isPromptFocused = true
    }

    private func open(_ thread: ChatThread) {
        isStartingNew = false
        selection = thread.id
    }
}

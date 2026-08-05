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
    /// The shelf, for grounding a question in it. Newest first, and narrowed to
    /// a handful by the search before any of it reaches the model.
    @Query(sort: \ShelfItem.createdAt, order: .reverse) private var items: [ShelfItem]

    @State private var tray = TempTray.shared
    @State private var activity = NotchActivityCenter.shared
    @State private var answer: String?
    @State private var isThinking = false
    /// Held so the bar appears by itself if Apple Intelligence finishes
    /// downloading while the panel is open.
    @State private var assistant = CoveAssistant.shared
    @FocusState private var isPromptFocused: Bool
    /// Which page the scroll view has settled on. Optional because that is what
    /// `scrollPosition(id:)` reports — it is briefly `nil` mid-flight, which is
    /// not a third page, so readers fall back to home.
    @State private var scrolledPage: Page? = .home

    private var page: Page { scrolledPage ?? .home }

    private enum Page: Hashable {
        case home
        case chats
        /// Only there while something is held.
        case tray
    }

    /// The pages that exist right now.
    ///
    /// The tray is last, and that is the load-bearing part rather than a
    /// preference. It comes and goes with what it holds, and a page that appears
    /// *between* two others moves the one after it — which leaves a paging
    /// scroll view trying to hold a position that has slid out from under it,
    /// parked between two pages. Appended at the end it moves nothing, so it can
    /// be conditional and the swipe stays honest.
    private var pageOrder: [Page] {
        tray.isEmpty ? [.home, .chats] : [.home, .chats, .tray]
    }

    /// Breathing room on every edge. Generous on purpose: the panel holds very
    /// little, and what little it holds should not look wedged into a corner.
    private static let inset: CGFloat = 22

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: max(notchHeight, 30))
            face
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.snappy(duration: 0.24), value: model.isDropTargeted)
        .animation(.snappy(duration: 0.24), value: model.screenshotOffer?.id)
        .animation(.snappy(duration: 0.28), value: page)
        .onChange(of: page) { _, current in
            // A field that is gone should not still hold the keystrokes. Left
            // focused, typing on the history page would land in a prompt bar
            // that isn't on screen.
            if current != .home { isPromptFocused = false }
        }
        .onChange(of: tray.isEmpty) { _, isEmpty in
            // The last thing held has been taken somewhere and its page went
            // with it. Standing on a page that no longer exists leaves the
            // scroll view showing nothing, so the panel walks back to the mark.
            if isEmpty, scrolledPage == .tray { scrolledPage = .home }
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

    /// Which of the panel's three faces is up: the drop targets, a screenshot
    /// being asked about, or the pages.
    ///
    /// Split out of `body` because the type-checker was timing out on it. That
    /// is not a style complaint — a body it cannot check in reasonable time is
    /// one build away from not compiling at all.
    @ViewBuilder
    private var face: some View {
        if model.isDropTargeted {
            // The drop face outranks the offer, and it has to: `DropTargets` is
            // what publishes the zone frames the drag is hit-tested against, so
            // a screenshot landing mid-drag must not be allowed to unmount it.
            // What the user is holding wins over a question Cove asked on its
            // own.
            DropTargets(model: model)
                .padding(.horizontal, Self.inset)
                .padding(.bottom, Self.inset)
                .transition(.opacity)
        } else if let offer = model.screenshotOffer {
            ScreenshotOffer(
                capture: offer,
                onSave: { save(offer) },
                onHold: { hold(offer) },
                onDismiss: { model.requestClose() }
            )
            .padding(.horizontal, Self.inset)
            .padding(.bottom, Self.inset)
            .transition(.opacity)
        } else {
            deck
        }
    }

    private var deck: some View {
        VStack(spacing: 0) {
            pages
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Its own row rather than an overlay pinned to the bottom of the
            // pages. Floating, the dots landed hard against the prompt bar and
            // read as specks on it.
            pageDots
                .padding(.top, 2)
                .padding(.bottom, 12)

            // Only on the home page. Asking something is what the mark is for;
            // the other two are for reading what is already there, and on a
            // panel this short the bar's height is the difference between three
            // visible rows and five.
            // …and only when there is a model to answer. A prompt bar with
            // nothing behind it is a control that takes a question and cannot
            // do anything with it, which is what this used to be: it shimmered,
            // then replied that it wasn't wired up. Better to not offer it.
            if page == .home, assistant.isReady {
                promptBar
                    .padding(.horizontal, Self.inset)
                    .padding(.bottom, Self.inset)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
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
                // Written out rather than looped. `scrollPosition(id:)` tracks
                // these by the identity attached here, and a `ForEach` over a
                // computed array gives that identity a second owner — which is
                // how a page that comes and goes ends up leaving the scroll view
                // parked between two of them.
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

                    if !tray.isEmpty {
                        TrayPage(tray: tray)
                            .frame(width: width)
                            .id(Page.tray)
                    }
                }
                .scrollTargetLayout()
            }
            // A two-finger swipe on a trackpad is a scroll event, not a drag —
            // no button is ever pressed, so a `DragGesture` never hears it. A
            // paging scroll view is the thing that does, and it comes with the
            // rubber-banding at the ends and the velocity-aware snap that would
            // otherwise have to be written by hand.
            .scrollTargetBehavior(OnePageAtATime(pageWidth: width))
            .scrollIndicators(.never)
            .scrollPosition(id: $scrolledPage)
        }
    }

    private var pageDots: some View {
        HStack(spacing: 5) {
            ForEach(pageOrder, id: \.self) { candidate in
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

    /// Asks the on-device model, grounded in the captures that best match the
    /// question, and shows the reply where the mark was.
    ///
    /// Two things here are deliberate. The shimmer now covers real work, so
    /// there is no sleep: it lasts exactly as long as the model takes, which is
    /// what a working indicator is for. And the reply is shown after the answer
    /// exists rather than before — the version this replaced inserted both turns
    /// up front and then waited 900ms to reveal a string it already had, which
    /// is the shape of a fake.
    ///
    /// Retrieval, the model, and the store are `CoveChat`'s, not this view's.
    /// The chat screen in the window asks the same way, and the two must not
    /// answer the question of what asking means differently.
    private func submit() {
        let question = model.promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isThinking else { return }
        model.promptText = ""
        isThinking = true

        Task {
            // Continues the newest thread, which on this surface is the only one
            // reachable: the island shows one conversation, and starting a
            // second is something the window's chat screen does.
            let reply = await CoveChat.ask(
                question,
                in: threads.first,
                shelf: items,
                context: modelContext
            )?.reply

            withAnimation(.easeInOut(duration: 0.2)) {
                isThinking = false
                answer = reply
            }
            try? await Task.sleep(for: .seconds(6))
            withAnimation(.easeInOut(duration: 0.25)) { answer = nil }
        }
    }

    // MARK: - Screenshots

    /// Puts the screenshot on the shelf.
    ///
    /// Built from the bitmap the watcher already decoded rather than from the
    /// path, for two reasons: the kind is known here to be a screenshot, where
    /// `CaptureIngest` would have to infer it from a filename that is localised;
    /// and the file's read access belongs to the watcher's folder scope, which
    /// this way is used once, at the moment it is certainly still open.
    private func save(_ capture: ScreenshotWatcher.Capture) {
        guard let item = CaptureIngest.item(
            from: capture.image,
            title: capture.name,
            sourceApp: capture.sourceApp,
            kind: .screenshot,
            sourceIdentifier: capture.url.path
        ) else {
            activity.post(.nothingToSave)
            model.requestClose()
            return
        }

        CaptureIngest.insert(item, into: modelContext)
        activity.post(.saved(count: 1))
        // Closing collapses the panel back to the activity strip, where the
        // toast just posted is what the island says next — so answering the
        // question is confirmed in the same place it was asked.
        model.requestClose()
    }

    private func hold(_ capture: ScreenshotWatcher.Capture) {
        TempTray.shared.add(fileURL: capture.url)
        activity.post(.held(count: 1))
        model.requestClose()
    }

    private func captureClipboard() {
        guard let item = CaptureIngest.itemFromClipboard() else {
            activity.post(.nothingToSave)
            return
        }
        CaptureIngest.insert(item, into: modelContext)
    }
}

// MARK: - Paging

/// One page per gesture, however hard the swipe.
///
/// `.paging` snaps to page boundaries but does not limit how many it crosses: a
/// flick carries two or three, so leaving the mark could land on the tray with
/// the history never seen, and the panel appears to jump rather than turn. On a
/// surface this small that reads as the gesture misfiring.
///
/// So every gesture is clamped to a single step from wherever it began.
/// `originalTarget` is the resting position the scroll view started this
/// interaction from, which is what makes "one step" mean one step from the page
/// you were on rather than from wherever momentum had reached.
private struct OnePageAtATime: ScrollTargetBehavior {
    let pageWidth: CGFloat

    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        guard pageWidth > 0 else { return }

        let start = (context.originalTarget.rect.minX / pageWidth).rounded()
        let proposed = (target.rect.minX / pageWidth).rounded()
        let stepped = min(max(proposed, start - 1), start + 1)

        target.rect.origin.x = stepped * pageWidth
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
            // The user's bubble is filled with the accent, so its text is
            // whatever reads on the accent the user picked — not always the
            // cream the rest of the transcript uses.
            .foregroundStyle(isUser ? CoveTheme.onAccent : CoveTheme.ink)
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

// MARK: - Screenshot offer

/// The question the island asks itself, without being dropped on: a screenshot
/// has just been taken, and here it is.
///
/// The two answers are the same two the drop face offers, in the same order and
/// the same shapes. That is the point — a screenshot arriving on its own and a
/// file dragged to the notch are the same decision, so learning it once should
/// be enough. What is new is the third answer, which is to do nothing: this is
/// the only surface in Cove that speaks first, so leaving the file exactly where
/// macOS put it has to be as easy as taking it.
private struct ScreenshotOffer: View {
    let capture: ScreenshotWatcher.Capture
    let onSave: () -> Void
    let onHold: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            header
            answers
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The shot itself, so there is no doubt which one is being asked about —
    /// two screenshots in a row otherwise produce two identical questions.
    private var header: some View {
        HStack(spacing: 11) {
            Image(nsImage: capture.image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 84, height: 52)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(CoveTheme.hairline, lineWidth: 1)
                }

            VStack(alignment: .leading, spacing: 3) {
                Text("Screenshot taken")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(CoveTheme.ink)

                Text(capture.sourceApp ?? capture.name)
                    .font(.system(size: 10))
                    .foregroundStyle(CoveTheme.inkTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(CoveTheme.inkTertiary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Leave it where it is")
            .accessibilityLabel("Dismiss")
        }
    }

    private var answers: some View {
        HStack(spacing: 14) {
            answer(
                title: "Hold here",
                subtitle: "Until you quit",
                systemImage: "tray.full",
                tint: CoveTheme.ink,
                perform: onHold
            )

            answer(
                title: "Add to Cove",
                subtitle: "Saved to the shelf",
                systemImage: "square.stack.3d.up.fill",
                tint: CoveTheme.accent,
                perform: onSave
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Deliberately the drop target's own shape and states, driven by hover
    /// rather than by a drag. A button that looked like a button here would make
    /// the two ways of putting a screenshot on the shelf look like two features.
    private func answer(
        title: String,
        subtitle: String,
        systemImage: String,
        tint: Color,
        perform: @escaping () -> Void
    ) -> some View {
        ScreenshotAnswerButton(
            title: title,
            subtitle: subtitle,
            systemImage: systemImage,
            tint: tint,
            perform: perform
        )
    }
}

private struct ScreenshotAnswerButton: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    let perform: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: perform) {
            VStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(isHovered ? tint : tint.opacity(0.65))

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
                isHovered ? tint.opacity(0.14) : Color.white.opacity(0.03),
                in: .rect(cornerRadius: 16)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(
                        isHovered ? tint.opacity(0.85) : CoveTheme.hairline,
                        style: StrokeStyle(lineWidth: isHovered ? 2 : 1, dash: isHovered ? [] : [5, 4])
                    )
            }
            .scaleEffect(isHovered ? 1.02 : 1)
            // The whole tile takes the click, not just the glyph and the words.
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.snappy(duration: 0.16), value: isHovered)
        .accessibilityLabel("\(title), \(subtitle)")
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

/// What is parked right now, as a page of its own.
///
/// This used to be a strip wedged under the pages, and it was the wrong shape
/// for the job. A parked thing exists to be carried somewhere — the whole
/// gesture is picking it back up and dropping it in another window — and a chip
/// the height of a line of text is a small thing to aim at while the panel is
/// also trying to be a prompt bar and a history. Given the page, each held thing
/// can be big enough to grab and can show what it actually is.
///
/// The page only exists while something is held, so arriving here always means
/// arriving at something.
private struct TrayPage: View {
    @Bindable var tray: TempTray

    @Environment(\.modelContext) private var modelContext

    private static let inset: CGFloat = 22

    /// Promotes a held thing to the shelf.
    ///
    /// It leaves the tray as it goes. Holding and saving are the two answers the
    /// drop face offers and they are opposites — one lasts until Cove quits, the
    /// other until you delete it — so a thing that is now both would be sitting
    /// under a countdown it no longer needs. Nothing is lost by moving it: unlike
    /// a drag out, which hands the thing to another app, this leaves it somewhere
    /// Cove can still show you.
    private func save(_ entry: TempTray.Entry) {
        guard let item = entry.shelfItem() else {
            NotchActivityCenter.shared.post(.nothingToSave)
            return
        }

        CaptureIngest.insert(item, into: modelContext)
        NotchActivityCenter.shared.post(.saved(count: 1))
        tray.remove(entry)
    }

    /// Adaptive rather than a fixed column count: the panel is one width today,
    /// but a held item is a fixed size and the row should fill whatever it is
    /// given rather than leave a gap on the right.
    private static let columns = [GridItem(.adaptive(minimum: 84), spacing: 9, alignment: .top)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            // A grid rather than a row. A row put everything past the third item
            // off the side of a panel that is already the width of a notch, and
            // the whole point of the page is seeing what you are carrying. The
            // scroll here is vertical, which also keeps it out of the way of the
            // horizontal swipe between pages.
            ScrollView(.vertical) {
                LazyVGrid(columns: Self.columns, spacing: 10) {
                    ForEach(tray.entries) { entry in
                        card(entry)
                    }
                }
                .padding(.horizontal, Self.inset)
                .padding(.bottom, 6)
            }
            .scrollIndicators(.never)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(tray.entries.count == 1 ? "1 held" : "\(tray.entries.count) held")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(CoveTheme.inkTertiary)

            Spacer(minLength: 0)

            Button {
                tray.clear()
            } label: {
                Text("Clear")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(CoveTheme.inkTertiary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Empty the holding shelf")
        }
        .padding(.horizontal, Self.inset)
    }

    /// One parked thing, sized to be picked up.
    ///
    /// `onDrag` is the entire point of the card. Everything else here — the
    /// preview, the name, the remove button — is in service of knowing which one
    /// to grab.
    private func card(_ entry: TempTray.Entry) -> some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(CoveTheme.raised)

                if let preview = entry.preview {
                    Image(nsImage: preview)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(nsImage: entry.icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 30, height: 30)
                }
            }
            // Height fixed, width taken from the grid cell, so every row lines
            // up whatever shape the things in it are.
            .frame(height: 54)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(CoveTheme.hairline, lineWidth: 1)
            }

            Text(entry.name)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(CoveTheme.inkSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity)
        }
        // The card is the drag handle, so the whole of it has to be draggable —
        // including the gap between the picture and the name. The overlay is
        // what carries the drag, and it covers the card for the same reason.
        .contentShape(Rectangle())
        .overlay {
            TrayDragOut(
                image: entry.preview ?? entry.icon,
                pasteboardItem: entry.pasteboardItem,
                onAccepted: { tray.handOff(entry) },
                onSave: { save(entry) },
                onRemove: { tray.remove(entry) },
                onOpen: { entry.open() }
            )
        }
        .help(entry.name)
    }
}

/// Drags a held thing out of the tray, and reports whether anything took it.
///
/// SwiftUI's `onDrag` hands over an item provider and then never speaks again.
/// It cannot tell a drop that landed in another app from one released over the
/// desktop and cancelled — and on that distinction rests whether the tray is
/// allowed to let go. Dropping a file on nothing and finding Cove had forgotten
/// it would be losing something the user was still carrying, which is the one
/// thing a holding shelf must not do.
///
/// AppKit does say: `draggingSession(_:endedAt:operation:)` reports the
/// operation the destination actually performed, and an empty one means nobody
/// took it. So the drag is run here instead.
private struct TrayDragOut: NSViewRepresentable {
    let image: NSImage
    let pasteboardItem: () -> any NSPasteboardWriting
    let onAccepted: () -> Void
    let onSave: () -> Void
    let onRemove: () -> Void
    let onOpen: () -> Void

    func makeNSView(context: Context) -> TrayDragOutView {
        let view = TrayDragOutView()
        apply(to: view)
        return view
    }

    func updateNSView(_ view: TrayDragOutView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: TrayDragOutView) {
        view.image = image
        view.pasteboardItem = pasteboardItem
        view.onAccepted = onAccepted
        view.onSave = onSave
        view.onRemove = onRemove
        view.onOpen = onOpen
    }
}

final class TrayDragOutView: NSView, NSDraggingSource {
    var image: NSImage?
    var pasteboardItem: (() -> any NSPasteboardWriting)?
    var onAccepted: (() -> Void)?
    var onSave: (() -> Void)?
    var onRemove: (() -> Void)?
    var onOpen: (() -> Void)?

    /// The island is a non-activating panel and is usually not the key window.
    /// Without this the first press only brings it forward and the drag it was
    /// meant to start never happens.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Whether the press that is still down has turned into a drag.
    ///
    /// A press on a held thing is ambiguous until it ends: moved, it is the
    /// start of a drag; released where it began, it is a click asking to open
    /// the thing. So the press is claimed here, the decision is deferred, and
    /// `mouseUp` acts only if nothing dragged.
    private var isDragging = false

    override func mouseDown(with event: NSEvent) {
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pasteboardItem, let image else { return }
        isDragging = true

        let item = NSDraggingItem(pasteboardWriter: pasteboardItem())
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        guard !isDragging else { return }
        onOpen?()
    }

    /// Right-click is handled here rather than by a SwiftUI `contextMenu`: this
    /// view covers the card, so a menu declared underneath it would never be
    /// reached.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(
            withTitle: "Open",
            action: #selector(openEntry),
            keyEquivalent: ""
        ).target = self
        menu.addItem(.separator())
        // Keeping it comes first of the remaining two: it is the one that
        // cannot be undone by doing the other.
        menu.addItem(
            withTitle: "Add to Cove",
            action: #selector(saveEntry),
            keyEquivalent: ""
        ).target = self
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Remove",
            action: #selector(removeEntry),
            keyEquivalent: ""
        ).target = self
        return menu
    }

    @objc private func openEntry() {
        onOpen?()
    }

    @objc private func saveEntry() {
        onSave?()
    }

    @objc private func removeEntry() {
        onRemove?()
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        // Copy rather than move: the file stays where it is. The tray holds a
        // path, and taking it somewhere should not empty the place it came from.
        .copy
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        // An empty operation is a drag that was let go over nothing, or refused.
        // The thing is still being carried, so the tray keeps it.
        guard !operation.isEmpty else { return }
        onAccepted?()
    }
}

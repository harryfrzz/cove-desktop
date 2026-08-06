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
    /// Which thread the home page is showing, set by asking.
    ///
    /// Nil until a question is asked, which is what keeps the mark up on a
    /// freshly opened panel, and nil again when the island closes: the island is
    /// a transient surface and its resting face is the wordmark, not the tail of
    /// a conversation from an hour ago. Nothing is lost by clearing it — the
    /// thread is on the Chats page and in the window.
    @State private var askedThreadID: UUID?
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
        .onChange(of: model.isOpen) { _, isOpen in
            // The island is transient and its resting face is the mark. A panel
            // reopened tomorrow showing the tail of today's conversation would
            // be a surface that never returns to rest. Only the home page's view
            // of it is dropped — the thread itself is on the Chats page and in
            // the window.
            guard !isOpen else { return }
            askedThreadID = nil
            // The attachment goes with it, for the same reason. It was chosen
            // for the question about to be typed, and a panel reopened tomorrow
            // still holding it would answer an unrelated question about a file
            // the user has forgotten pointing at.
            tray.detach()
        }
        // A drop on Ask Cove. It lands wherever the panel happened to be, so
        // this is what puts it back on the page the prompt bar is on and into
        // the field — the drop chose the subject, and the next thing to happen
        // is typing.
        .onChange(of: model.askRequests) { _, _ in
            scrolledPage = .home
            model.requestFocus()
            isPromptFocused = true
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
            //
            // Shown whether or not Apple Intelligence is set up. This was gated
            // on the model for a while, on the reasoning that a bar which cannot
            // answer should not be offered — but that was measuring the wrong
            // thing. Search is a separate local stack, so without the model the
            // bar still finds what was asked for and says what it found; the
            // reply loses its prose, not its substance. Hiding it meant a Mac
            // without Apple Intelligence had no way to ask the shelf anything,
            // and no way to see why.
            if page == .home {
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

    /// The mark, or the conversation in its place.
    ///
    /// The answer used to land here as one centred paragraph, capped at four
    /// lines, with the question nowhere on screen. That reads as a panel
    /// announcing something rather than as an exchange, and it loses the half
    /// the user wrote — which is the half that makes a reply legible when it
    /// arrives a few seconds later. The same transcript the Chats page draws is
    /// drawn here instead, on the same bubbles, so the two surfaces are
    /// recognisably one feature.
    ///
    /// The mark stays for a panel nobody has asked anything yet. It is Cove's
    /// resting face and the thing the island is when it has nothing to say.
    @ViewBuilder
    private var centrepiece: some View {
        if hasConversation {
            liveTranscript
                .transition(.opacity)
        } else {
            Text("Cove")
                .font(.system(size: 34, weight: .semibold, design: .serif))
                .foregroundStyle(CoveTheme.ink.opacity(isThinking ? 0.4 : 0.92))
                .coveShimmer(isActive: isThinking)
                .animation(.easeInOut(duration: 0.25), value: isThinking)
        }
    }

    /// The thread being spoken to right now, or nil while the mark is up.
    ///
    /// Resolved from the store rather than held as a copy, so the bubbles follow
    /// what was actually saved — including the assistant's turn, which lands
    /// after the question and is what the user is waiting for.
    private var conversation: ChatThread? {
        guard let askedThreadID else { return nil }
        return threads.first { $0.id == askedThreadID }
    }

    private var hasConversation: Bool {
        conversation?.turns.isEmpty == false
    }

    /// The turns worth drawing.
    ///
    /// Cove's turn is stored empty the moment a question is asked and filled in
    /// as the answer streams, so the transcript always ends in a turn with no
    /// text in it for as long as the model is thinking. An empty bubble is not
    /// a turn anyone can read — `pendingBubble` stands in its place until the
    /// first words land.
    private var visibleTurns: [ChatTurn] {
        (conversation?.orderedTurns ?? []).filter { !$0.text.isEmpty }
    }

    /// Whether the answer has been asked for and has not begun arriving.
    private var isAwaitingReply: Bool {
        isThinking && conversation?.orderedTurns.last?.text.isEmpty != false
    }

    /// The exchange, newest last, with the shimmer under it until Cove speaks.
    private var liveTranscript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(visibleTurns.enumerated()), id: \.element.id) { index, turn in
                        VStack(alignment: .leading, spacing: 5) {
                            transcriptBubble(
                                turn.text,
                                isUser: turn.role == .user,
                                // No tail while the shimmer is about to sit
                                // under this bubble: it continues Cove's side of
                                // the conversation even though it is not a turn.
                                hasTail: visibleTurns.endsSpeakerRun(at: index)
                                    && !(index == visibleTurns.count - 1 && isAwaitingReply)
                            )

                            // Resolved against the live shelf at the moment of
                            // drawing, so a row is always the shelf's own record
                            // of where that capture points — and one deleted
                            // since the answer was given quietly stops being
                            // offered.
                            ForEach(CaptureLinks.resolve(turn.linkedItemIDs, in: items)) { item in
                                IslandCaptureLink(item: item)
                            }
                        }
                        .padding(.top, visibleTurns.spacingBefore(at: index, tight: 2, loose: 8))
                        .transition(.coveBubble(isUser: turn.role == .user))
                        .id(turn.id)
                    }

                    if isAwaitingReply {
                        pendingBubble
                            .padding(.top, 8)
                            .transition(.coveBubble(isUser: false))
                            .id(Self.pendingBubbleID)
                    }
                }
                .padding(.vertical, 2)
                // The spring the bubbles arrive on. Declared here rather than on
                // each of them so a question and the answer under it land as one
                // movement.
                .animation(Self.bubbleSpring, value: visibleTurns.count)
                .animation(Self.bubbleSpring, value: isAwaitingReply)
                // Each streamed snapshot makes the reply taller. Without this the
                // bubble jumps to its new size; with it, it grows.
                .animation(.easeOut(duration: 0.18), value: visibleTurns.last?.text)
            }
            .scrollIndicators(.never)
            // The last thing said is what the panel is about, and on a surface
            // this short it is off the bottom the moment there are three turns.
            .onChange(of: visibleTurns.count) { _, _ in scrollToEnd(proxy) }
            .onChange(of: isAwaitingReply) { _, _ in scrollToEnd(proxy) }
            // A reply that is still growing pushes its own last line out of
            // sight, so the follow has to happen on every snapshot rather than
            // once when the turn appeared.
            .onChange(of: visibleTurns.last?.text) { _, _ in scrollToEnd(proxy) }
            .onAppear { scrollToEnd(proxy) }
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        let target: AnyHashable? = isAwaitingReply
            ? Self.pendingBubbleID
            : visibleTurns.last?.id
        guard let target else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(target, anchor: .bottom)
        }
    }

    /// Cove's turn before it has one: the shimmer, in the shape the answer will
    /// arrive in, so nothing moves when it does.
    private var pendingBubble: some View {
        Text("Thinking…")
            .font(.system(size: 10))
            .foregroundStyle(CoveTheme.inkSecondary)
            .coveShimmer(isActive: true)
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .padding(.leading, CoveBubbleShape.tailWidth)
            .background(CoveTheme.raised, in: CoveBubbleShape(isUser: false, hasTail: true))
            .frame(maxWidth: Self.bubbleWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(.opacity)
    }

    /// Deliberately the same geometry, type size and colours as the Chats page's
    /// own bubbles. Two transcripts on one panel that disagreed about what a
    /// bubble looks like would read as two different features.
    private func transcriptBubble(_ text: String, isUser: Bool, hasTail: Bool) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(isUser ? CoveTheme.onAccent : CoveTheme.ink)
            .multilineTextAlignment(.leading)
            .textSelection(.enabled)
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            // The tail's own width, on its side only, so the text sits centred
            // in the body of the bubble rather than drifting towards the tail.
            .padding(isUser ? .trailing : .leading, CoveBubbleShape.tailWidth)
            .background(
                isUser ? AnyShapeStyle(CoveTheme.accent) : AnyShapeStyle(CoveTheme.raised),
                in: CoveBubbleShape(isUser: isUser, hasTail: hasTail)
            )
            .frame(maxWidth: Self.bubbleWidth, alignment: isUser ? .trailing : .leading)
            .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    /// Wide enough for a sentence, narrow enough that a bubble is visibly a
    /// bubble rather than the full width of the panel.
    private static let bubbleWidth: CGFloat = 260

    /// Enough bounce to read as arriving, not so much that a reply wobbles.
    /// Short, because it runs while someone is already reading the words.
    private static let bubbleSpring = Animation.spring(response: 0.34, dampingFraction: 0.7)

    private static let pendingBubbleID = "cove-pending-answer"

    // MARK: - Prompt

    /// The bar, with whatever the next question is about sitting above it.
    ///
    /// Above rather than inside. A chip in the capsule takes the room the
    /// question is typed into — on a 320pt field a filename leaves space for
    /// about four words — and it reads as part of what was typed, which is the
    /// one thing it is not.
    @ViewBuilder
    private var promptBar: some View {
        VStack(spacing: 7) {
            if let attached = tray.attached {
                attachmentChip(attached)
            }

            promptField
        }
        .animation(.snappy(duration: 0.2), value: tray.attached?.id)
    }

    /// What the next question is about, and the way to say it isn't.
    private func attachmentChip(_ entry: TempTray.Entry) -> some View {
        HStack(spacing: 7) {
            Image(nsImage: entry.preview ?? entry.icon)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 18, height: 18)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

            Text(entry.name)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(CoveTheme.inkSecondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Button {
                tray.detach()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(CoveTheme.inkTertiary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Ask about the shelf instead")
        }
        .padding(.leading, 7)
        .padding(.trailing, 3)
        .padding(.vertical, 4)
        .background(CoveTheme.raised, in: Capsule())
        .overlay { Capsule().strokeBorder(CoveTheme.hairline, lineWidth: 1) }
        .frame(maxWidth: 320)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    /// Says what the bar will do with what is typed into it. All three states
    /// are real: an attachment changes what the question is about, and no model
    /// changes what comes back.
    private var placeholder: String {
        if tray.attached != nil { return "Ask about this…" }
        return assistant.isReady ? "Ask Cove…" : "Search your shelf…"
    }

    private var promptField: some View {
        HStack(spacing: 9) {
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(CoveTheme.accent)

            // Names the reduced thing when the model is missing, so the bar does
            // not promise an answer it will come back from with a list.
            TextField(placeholder, text: $model.promptText)
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
    /// question, and puts the exchange on the panel as it happens.
    ///
    /// The shimmer covers real work, so there is no sleep: it lasts exactly as
    /// long as the model takes, which is what a working indicator is for.
    ///
    /// Nothing here dismisses the answer on a timer any more. The reply used to
    /// clear itself after six seconds, which suited a line of text standing in
    /// for the wordmark and does not suit a conversation — a transcript that
    /// erases itself while being read is not one. It goes when the island does,
    /// and the thread it belonged to is on the Chats page either way.
    ///
    /// Retrieval, the model, and the store are `CoveChat`'s, not this view's.
    /// The chat screen in the window asks the same way, and the two must not
    /// answer the question of what asking means differently.
    private func submit() {
        let question = model.promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isThinking else { return }
        model.promptText = ""

        // The thread this opening of the island started, and nil for the first
        // question of a new one — which is what makes each opening its own
        // conversation rather than an endless append to whatever was asked
        // days ago. `CoveChat` creates the thread on that first question, so a
        // panel opened and closed without a word leaves nothing behind.
        //
        // Follow-ups within the same opening continue it, because `askedThreadID`
        // is set below and only cleared when the island closes.
        guard let exchange = CoveChat.begin(question, in: conversation, context: modelContext) else {
            return
        }

        // Synchronous, so the question is on screen in this frame rather than
        // several seconds later when the model has finished.
        askedThreadID = exchange.thread.id
        isThinking = true

        Task {
            await CoveChat.answer(exchange, to: question, shelf: items, context: modelContext)
            isThinking = false
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
///
/// What decides *whether* to step is the part that took two attempts. Rounding
/// the projected target to the nearest page — the obvious reading of "snap" —
/// makes the gesture demand half a page of travel before it commits to
/// anything, and a two-finger swipe on a trackpad does not travel half of 460pt
/// unless it is thrown. Every ordinary swipe fell back to the page it started
/// on, which reads as the panel refusing to turn rather than as a threshold not
/// being met.
///
/// So a flick counts on its own. Past `flickVelocity` the direction of the
/// gesture is the answer and the distance is irrelevant; below it, a fifth of a
/// page is enough to commit. Those are the two ways a person actually asks for
/// the next page — throw it, or push it and let go — and either one now turns
/// exactly one.
private struct OnePageAtATime: ScrollTargetBehavior {
    let pageWidth: CGFloat

    /// Points per second past which the gesture is a flick and its length no
    /// longer matters. Low enough that a lazy two-finger push clears it, high
    /// enough that the drift at the end of a slow drag does not.
    private static let flickVelocity: CGFloat = 220

    /// How far a slow drag must travel to count, as a fraction of the page.
    /// A fifth: far enough not to fire on a nudge, near enough that the page is
    /// visibly following the fingers before it commits.
    private static let commitFraction: CGFloat = 0.2

    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        guard pageWidth > 0 else { return }

        let origin = context.originalTarget.rect.minX
        let start = (origin / pageWidth).rounded()
        let travelled = target.rect.minX - origin
        let velocity = context.velocity.dx

        // One of three answers: forward, back, or stay. Never two pages, whatever
        // the momentum proposed.
        let step: CGFloat
        if abs(velocity) >= Self.flickVelocity {
            step = velocity > 0 ? 1 : -1
        } else if abs(travelled) >= pageWidth * Self.commitFraction {
            step = travelled > 0 ? 1 : -1
        } else {
            step = 0
        }

        target.rect.origin.x = (start + step) * pageWidth
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

    /// The shelf, for resolving the captures a past answer offered. Queried here
    /// rather than passed down: this page is reached by swiping and may never be
    /// looked at, and the home page has no reason to carry the shelf on its
    /// behalf.
    @Query(sort: \ShelfItem.createdAt, order: .reverse) private var items: [ShelfItem]

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
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                header("Recent")

                Spacer(minLength: 8)

                Text("\(threads.count) \(threads.count == 1 ? "chat" : "chats")")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(CoveTheme.inkTertiary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(CoveTheme.raised, in: Capsule())
                    .overlay { Capsule().strokeBorder(CoveTheme.hairline, lineWidth: 1) }
                    .accessibilityLabel("\(threads.count) recent chats")
            }
            .padding(.trailing, Self.inset)

            ScrollView {
                IslandMasonryLayout(minimumColumnWidth: 178, spacing: 9) {
                    ForEach(threads) { thread in
                        Button {
                            openThread = thread
                        } label: {
                            card(thread)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Self.inset)
                // The cards are allowed to sit slightly apart from the heading
                // and the page dots. That gives the wall enough visual edge to
                // read as a collection rather than the same list in columns.
                .padding(.top, 1)
                .padding(.bottom, 8)
            }
            .scrollIndicators(.never)
        }
    }

    /// A conversation needs more than a single stripped line to be recognisable
    /// later. Giving the question and answer room to breathe also creates the
    /// uneven heights that make the compact wall worth using over a grid.
    private func card(_ thread: ChatThread) -> some View {
        let reply = thread.orderedTurns.last(where: { $0.role == .assistant })?.text

        return VStack(alignment: .leading, spacing: 8) {
            Text(thread.updatedAt.formatted(.relative(presentation: .numeric, unitsStyle: .narrow)))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(CoveTheme.inkTertiary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .trailing)

            Text(thread.title.isEmpty ? "Untitled" : thread.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(CoveTheme.ink)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let reply, !reply.isEmpty {
                Text(reply)
                    .font(.system(size: 10))
                    .foregroundStyle(CoveTheme.inkSecondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Waiting for Cove…")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(CoveTheme.inkTertiary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        // A single card is the tap target — not just its label — so the space
        // left by a short reply remains as easy to open as the words themselves.
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .background(CoveTheme.raised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(CoveTheme.hairline, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.24), radius: 7, y: 3)
    }

    private func transcript(of thread: ChatThread) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
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
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Self.inset)

            ScrollView {
                // Empty turns are Cove's, waiting to be streamed into — or left
                // behind by a thread that was interrupted mid-answer. Neither is
                // a bubble worth drawing.
                let turns = thread.orderedTurns.filter { !$0.text.isEmpty }

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(turns.enumerated()), id: \.element.id) { index, turn in
                        VStack(alignment: .leading, spacing: 5) {
                            bubble(turn, hasTail: turns.endsSpeakerRun(at: index))

                            ForEach(CaptureLinks.resolve(turn.linkedItemIDs, in: items)) { item in
                                IslandCaptureLink(item: item)
                            }
                        }
                        .padding(.top, turns.spacingBefore(at: index, tight: 2, loose: 8))
                        .transition(.coveBubble(isUser: turn.role == .user))
                    }
                }
                .padding(.horizontal, Self.inset)
                .padding(.bottom, 6)
                // A thread opened from the list arrives whole, so this only ever
                // animates a turn added while it is being read.
                .animation(.spring(response: 0.34, dampingFraction: 0.7), value: turns.count)
            }
            .scrollIndicators(.never)

            // This is an action on the whole conversation, so it belongs after
            // the transcript rather than alongside the title it merely happens
            // to be opened from. Keeping it outside the scroll view also means
            // it remains reachable after a long answer.
            openInAppButton(thread)
                .padding(.horizontal, Self.inset)
                .padding(.top, 2)
                .padding(.bottom, 7)
        }
    }

    /// The way out of a panel this size.
    ///
    /// The island is 460pt wide and the transcript gets a few short rows of it.
    /// That is the right budget for a glance and the wrong one for an answer
    /// that ran to a list — which is a shape Cove produces often enough that
    /// reading one should not mean scrolling a strip under the notch.
    ///
    /// Glass rather than the panel's own raised fill: it sits over the
    /// transcript rather than in it, and the material is what says so.
    private func openInAppButton(_ thread: ChatThread) -> some View {
        Button {
            NotificationCenter.default.post(
                name: .coveOpenChat,
                object: nil,
                userInfo: [CoveWindowController.threadIDKey: thread.id]
            )
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "macwindow")
                    .font(.system(size: 9, weight: .semibold))
                Text("Open in App")
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(CoveTheme.ink)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            // The action gets the island's one wide, tactile surface. This is
            // deliberately the glass effect rather than `raised`: it floats
            // over the transcript instead of looking like another message.
            .glassEffect(.regular.interactive(), in: Capsule())
            // The glass is drawn outside the label, so without this only the
            // glyph and the words take a click.
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens this conversation in Cove's window, where there is room to read it")
    }

    /// The user's turn sits right and tinted, Cove's sits left and plain — the
    /// arrangement every transcript uses, so no label is needed to say who said
    /// what.
    private func bubble(_ turn: ChatTurn, hasTail: Bool) -> some View {
        let isUser = turn.role == .user

        return Text(turn.text)
            .font(.system(size: 10))
            // The user's bubble is filled with the accent, so its text is
            // whatever reads on the accent the user picked — not always the
            // cream the rest of the transcript uses.
            .foregroundStyle(isUser ? CoveTheme.onAccent : CoveTheme.ink)
            .multilineTextAlignment(.leading)
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .padding(isUser ? .trailing : .leading, CoveBubbleShape.tailWidth)
            .background(
                isUser ? AnyShapeStyle(CoveTheme.accent) : AnyShapeStyle(CoveTheme.raised),
                in: CoveBubbleShape(isUser: isUser, hasTail: hasTail)
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

/// Packs chat cards into the shortest column. The island uses two columns at
/// its normal width, but this remains a one-column list if an accessibility
/// size or a future panel size leaves less room than a readable card needs.
private struct IslandMasonryLayout: Layout {
    var minimumColumnWidth: CGFloat
    var spacing: CGFloat

    typealias Cache = Void

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) -> CGSize {
        let width = resolvedWidth(from: proposal)
        let columnWidth = columnWidth(for: width)
        var heights = Array(repeating: CGFloat.zero, count: columnCount(for: width))

        for subview in subviews {
            let column = shortestColumn(in: heights)
            let size = subview.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil))
            heights[column] += (heights[column] == 0 ? 0 : spacing) + size.height
        }

        return CGSize(width: width, height: heights.max() ?? 0)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) {
        let width = max(bounds.width, 1)
        let columnWidth = columnWidth(for: width)
        var heights = Array(repeating: CGFloat.zero, count: columnCount(for: width))

        for subview in subviews {
            let column = shortestColumn(in: heights)
            let y = bounds.minY + heights[column] + (heights[column] == 0 ? 0 : spacing)
            let size = subview.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil))

            subview.place(
                at: CGPoint(
                    x: bounds.minX + CGFloat(column) * (columnWidth + spacing),
                    y: y
                ),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: columnWidth, height: size.height)
            )
            heights[column] = y - bounds.minY + size.height
        }
    }

    private func resolvedWidth(from proposal: ProposedViewSize) -> CGFloat {
        guard let width = proposal.width, width.isFinite, width > 0 else {
            return minimumColumnWidth
        }
        return width
    }

    private func columnCount(for width: CGFloat) -> Int {
        max(1, Int((width + spacing) / (minimumColumnWidth + spacing)))
    }

    private func columnWidth(for width: CGFloat) -> CGFloat {
        let count = CGFloat(columnCount(for: width))
        return (width - spacing * (count - 1)) / count
    }

    private func shortestColumn(in heights: [CGFloat]) -> Int {
        heights.indices.min { heights[$0] < heights[$1] } ?? 0
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
        // Three across a panel the width of a notch, so the subtitles are
        // shorter than they were and the type is a size down. The alternative
        // was two rows, which puts the third answer somewhere a drag already
        // heading for the first two has to be taken back out of.
        HStack(spacing: 10) {
            target(
                zone: .hold,
                title: "Hold",
                subtitle: "Until you quit",
                systemImage: "tray.full",
                tint: CoveTheme.ink
            )

            target(
                zone: .save,
                title: "Add to Cove",
                subtitle: "Kept on the shelf",
                systemImage: "square.stack.3d.up.fill",
                tint: CoveTheme.accent
            )

            target(
                zone: .ask,
                title: "Ask Cove",
                subtitle: "Read, not kept",
                systemImage: "sparkles",
                tint: CoveTheme.ink
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

        return VStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(isTargeted ? tint : tint.opacity(0.65))
            VStack(spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(CoveTheme.ink)
                Text(subtitle)
                    .font(.system(size: 9))
                    .foregroundStyle(CoveTheme.inkTertiary)
            }
            // Three columns in 416pt leaves ~130 each. Nothing here should wrap
            // to two lines and change the height of one target but not its
            // neighbours.
            .lineLimit(1)
            .minimumScaleFactor(0.85)
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
    ///
    /// Wide enough that a screenshot is legible as itself. At 84 a held capture
    /// was a stamp — you could tell it apart from a spreadsheet and not much
    /// else, which is thin for the one page whose whole job is showing what you
    /// are carrying.
    private static let columns = [GridItem(.adaptive(minimum: 124), spacing: 14, alignment: .top)]

    /// How far a card leans, and always the same way for the same card.
    ///
    /// Derived from the entry's id rather than its position, which is the part
    /// that matters. Tilting by index looks identical on a full tray and is
    /// wrong the moment one is removed: every card behind the gap would shuffle
    /// to a new angle, so taking one thing off the shelf visibly disturbs the
    /// others. An id is fixed for the life of the entry, so a card is only ever
    /// tilted once.
    ///
    /// Never nearer than 1.5° to straight. Below that it stops reading as a
    /// scatter and starts reading as a layout fault.
    private static func tilt(for entry: TempTray.Entry) -> Double {
        let magnitude = 1.5 + Double(entry.id.uuid.0 % 32) / 32 * 3.5
        return entry.id.uuid.1 % 2 == 0 ? magnitude : -magnitude
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            // A grid rather than a row. A row put everything past the third item
            // off the side of a panel that is already the width of a notch, and
            // the whole point of the page is seeing what you are carrying. The
            // scroll here is vertical, which also keeps it out of the way of the
            // horizontal swipe between pages.
            ScrollView(.vertical) {
                LazyVGrid(columns: Self.columns, spacing: 16) {
                    ForEach(tray.entries) { entry in
                        card(entry)
                    }
                }
                // Room for the lean. A tilted card reaches past the box the grid
                // gave it, and without this the corner nearest the edge is the
                // first thing the scroll view cuts off.
                .padding(.horizontal, Self.inset - 6)
                .padding(.vertical, 8)
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
        VStack(spacing: 7) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(CoveTheme.raised)

                if let preview = entry.preview {
                    Image(nsImage: preview)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(nsImage: entry.icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 40, height: 40)
                }
            }
            // Height fixed, width taken from the grid cell, so every row lines
            // up whatever shape the things in it are.
            .frame(height: 80)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(CoveTheme.hairline, lineWidth: 1)
            }
            // What makes the tilt read as a card lying on something rather than
            // as a picture drawn crooked. Under the name as well as the picture
            // would smear the text, so it stops at the frame.
            .shadow(color: .black.opacity(0.45), radius: 7, y: 4)

            Text(entry.name)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(CoveTheme.inkSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity)
        }
        // The whole card leans, name included: a straight caption under a tilted
        // picture reads as the picture having slipped.
        .rotationEffect(.degrees(Self.tilt(for: entry)))
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
                onOpen: { entry.open() },
                onAsk: { tray.attach(entry) }
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
    let onAsk: () -> Void

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
        view.onAsk = onAsk
    }
}

final class TrayDragOutView: NSView, NSDraggingSource {
    var image: NSImage?
    var pasteboardItem: (() -> any NSPasteboardWriting)?
    var onAccepted: (() -> Void)?
    var onSave: (() -> Void)?
    var onRemove: (() -> Void)?
    var onOpen: (() -> Void)?
    var onAsk: (() -> Void)?

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
        menu.addItem(
            withTitle: "Ask Cove About This",
            action: #selector(askAboutEntry),
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

    @objc private func askAboutEntry() {
        onAsk?()
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

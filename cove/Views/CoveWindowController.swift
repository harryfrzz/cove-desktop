import AppKit
import Observation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// The app's own window — the surface the island cannot be.
///
/// The island is deliberately small: it hangs off the notch and has room for a
/// prompt and two drop targets, nothing more. Browsing what Cove has kept,
/// searching it, opening one thing and reading it — all of that needs a window,
/// and this is it.
///
/// Built in AppKit rather than as a SwiftUI `Window` scene for the same reason
/// `NotchController` is: Cove runs as an accessory app, so the window has to be
/// ordered in and given focus explicitly. Owning the `NSWindow` is what makes
/// that dependable.
@MainActor
final class CoveWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model = CoveWindowModel()

    /// Opens the window, or brings it forward if it is already open. Cove is an
    /// accessory app and is never frontmost by accident, so showing a window
    /// means activating too — otherwise it appears behind whatever the user was
    /// in and reads as not having opened at all.
    func show() {
        let window = window ?? build()
        // Read before ordering front: afterwards it is always true, and what
        // matters is whether this is an arrival or merely a raise. Bringing an
        // already-open window forward should not replay the entrance and throw
        // away whatever the user was looking at.
        let isArriving = !window.isVisible

        NSApp.activate()
        window.makeKeyAndOrderFront(nil)

        if isArriving {
            model.openCount &+= 1
        }
    }

    private func build() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Cove"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        // Black in dark mode, white in light — the one part of Cove that follows
        // the system appearance. Set on the window as well as in SwiftUI because
        // the titlebar is drawn by AppKit and a live resize exposes the window's
        // own colour before the hosting view catches up.
        window.backgroundColor = NSColor.coveWindowBackground
        window.contentView = NSHostingView(
            rootView: CoveWindowView(model: model)
                .modelContainer(CoveStore.shared)
        )
        // Smaller than this and the shelf would have nowhere to lay out; the
        // window is meant to hold a grid, not a list of one column.
        window.contentMinSize = NSSize(width: 720, height: 480)
        window.center()
        // Remembers where it was put, so reopening does not throw it back to
        // the middle of the screen.
        window.setFrameAutosaveName("CoveMainWindow")
        window.delegate = self
        self.window = window
        return window
    }
}

/// The library window. It deliberately stays separate from the notch: the
/// island is for capture, while this surface is for taking time to browse the
/// things that have already been saved.
@MainActor
@Observable
private final class CoveWindowModel {
    var isRefreshing = false
    var refreshStartedAt = Date.now
    /// Bumped every time the window is brought up. The shelf watches it to
    /// replay its entrance — the window is reused rather than rebuilt, so this
    /// is the only signal that says "you are being looked at again".
    var openCount = 0
}

private struct CoveWindowView: View {
    @Bindable var model: CoveWindowModel
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ShelfItem.createdAt, order: .reverse) private var items: [ShelfItem]
    @State private var selectedItem: ShelfItem?
    /// Each pile's frame in window space, so the album screen knows where its
    /// images were gathered before they fly apart.
    @State private var pileFrames: [ShelfAlbumKey: CGRect] = [:]
    @State private var openAlbum: ShelfAlbumKey?
    /// Drives the wall: false heaps the images back at the pile, true throws
    /// them out to their slots. Owned here rather than by the album screen so
    /// the back button can run the burst in reverse before the screen goes.
    @State private var albumScattered = false
    /// Fades the album's background and title, so the screen doesn't cut away
    /// while the images are still flying home.
    @State private var albumChrome: Double = 1
    /// Identifies the in-flight open or close, so a stale one can't finish.
    @State private var albumTransition = 0
    @State private var isAddingLink = false
    @State private var isAddingNote = false
    /// The item lifted out of the shelf by a right-click, if any.
    @State private var focus: ShelfFocusTarget?
    /// Whether clicking a card picks it rather than opens it. A mode rather than
    /// a per-item action: choosing five things one context menu at a time is not
    /// how anyone clears a shelf.
    @State private var isSelecting = false
    @State private var selection: Set<UUID> = []
    @State private var pendingDelete: [ShelfItem] = []
    @State private var isShowingSettings = false
    @State private var isShowingChats = false
    /// Whether Cove has introduced itself yet. Shared rather than owned by this
    /// view, so Settings can put the introduction back.
    @State private var onboarding = CoveOnboarding.shared
    /// Narrows the library to one kind of thing. Not persisted: a filter that
    /// outlived the session would hide captures the user knows they saved.
    @State private var filter: ShelfFilter = .all
    /// Lets the glass on the pills be one system rather than five separate
    /// panes, so the selected pill's tint travels between them.
    @Namespace private var filterGlass
    /// False heaps the shelf at rest — small and invisible — and true pops it
    /// into place. Driven by the window opening, not by the view appearing:
    /// the hosting view is never torn down, so `onAppear` fires once per launch
    /// and every later reopen would show a shelf that was already there.
    @State private var isRevealed = false
    /// Viewport width of the pill row, so the row can be made to fill it and
    /// centre its pills inside.
    @State private var pillRowWidth: CGFloat = 0
    @State private var searchText = ""
    /// Ids the current query matched, or `nil` when there is no query. A set
    /// rather than the items themselves: the shelf is already sorted the way it
    /// should be drawn, and re-ordering it by relevance would make the piles
    /// jump around while someone is still typing.
    @State private var searchMatches: Set<UUID>?
    /// Where each match placed, so the shelf can show them in the order the
    /// search ranked them.
    ///
    /// The set above answers "is this a match", which was all a keyword search
    /// needed — every hit contained the word and recency was as good an order as
    /// any. A semantic search's whole output is the ordering: the item that
    /// merely feels related and the one that is the answer are both matches, and
    /// collapsing them into a set threw away the only thing distinguishing them.
    @State private var searchRanking: [UUID: Int]?
    @FocusState private var isSearchFocused: Bool
    /// Held so the window re-renders when the accent changes — see the same
    /// state on `NotchRootView` for why a colour property reading this store is
    /// not enough on its own.

    /// Long enough for the last print to land: the implode stagger tops out at
    /// 0.36s and its spring runs ~0.42s. The spring's final settling is
    /// invisible once a card is back on the pile, so this stops short of it.
    private static let implodeDuration: Duration = .milliseconds(660)

    var body: some View {
        screens
            .background(CoveTheme.windowBackground)
            .accessibilityIdentifier("cove-library-window")
            // Runs when the shelf appears and again on every reopen. One task
            // rather than an onAppear/onChange/onDisappear trio, because it also
            // gets the cancellation right: closing the window mid-entrance
            // leaves the shelf at rest, ready to pop again next time.
            .task(id: model.openCount) { await playEntrance() }
            .task(id: searchText) { await runSearch() }
            // The window title is the only place a screen names itself, so it
            // follows the screen rather than staying on the app's name.
            .navigationTitle(title)
            .toolbar { toolbarContent }
            .sheet(isPresented: $isShowingSettings) {
                SettingsView()
            }
            .sheet(
                isPresented: Binding(
                    get: { selectedItem != nil },
                    set: { if !$0 { selectedItem = nil } }
                )
            ) {
                Group {
                    if let selectedItem {
                        ShelfItemDetailView(item: selectedItem)
                    }
                }
            }
            .sheet(isPresented: $isAddingLink) {
                AddLinkSheet(onAdd: addLink)
            }
            .sheet(isPresented: $isAddingNote) {
                AddNoteSheet(onAdd: addNote)
            }
            .confirmationDialog(
                pendingDelete.count == 1
                    ? "Delete this item?"
                    : "Delete \(pendingDelete.count) items?",
                isPresented: Binding(
                    get: { !pendingDelete.isEmpty },
                    set: { if !$0 { pendingDelete = [] } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive, action: confirmDelete)
                Button("Cancel", role: .cancel) { pendingDelete = [] }
            } message: {
                Text("Removed from this Mac for good.")
            }
            // Above everything, including the toolbar's own reach: on a first
            // run there is nothing on the shelf to browse and no reason to let
            // anyone into a window that would only show an empty state. A sheet
            // was the other option and is the wrong one — sheets are dismissed
            // by Escape, and an introduction that vanishes on a stray keystroke
            // is one nobody finishes.
            .overlay {
                if !onboarding.isFinished {
                    OnboardingView(onFinish: onboarding.finish)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.28), value: onboarding.isFinished)
    }

    private var title: String {
        if isShowingChats { return "Chats" }
        return openAlbum?.title ?? "Cove"
    }

    /// The three screens the window can be showing, and the lifted card over
    /// them.
    ///
    /// Split out of `body`, along with the toolbar and the sheets, because the
    /// compiler had started reporting that it could not type-check the whole
    /// thing in reasonable time. That is a warning one addition away from
    /// becoming a build failure, not a style note.
    private var screens: some View {
        // A navigation stack would own the transition, and its push is a slide
        // that fights the burst. Swapping the screens directly keeps both
        // directions of the animation here, where the pile frames already live.
        ZStack {
            ZStack {
                library

                if let openAlbum {
                    ImageAlbumScreen(
                        items: albumItems(in: openAlbum),
                        scatterFrame: pileFrames[openAlbum],
                        isScattered: albumScattered,
                        chromeOpacity: albumChrome,
                        onSelect: activate,
                        selection: selection,
                        onSecondaryClick: { item, frame in
                            focus = ShelfFocusTarget(itemID: item.id, frame: frame)
                        }
                    )
                }

                // Last, so it covers both. Chats is not a layer over the shelf
                // the way the focus overlay is — it is somewhere else the window
                // can be, and it draws its own background to say so.
                if isShowingChats {
                    ChatHistoryScreen()
                        .transition(.opacity)
                }
            }
            // The shelf recedes so one item can be looked at. Disabling it as
            // well as blurring it means a stray click lands on the overlay's
            // dismiss area rather than opening whatever was underneath.
            .blur(radius: focus == nil ? 0 : 16)
            .disabled(focus != nil)
            .animation(.easeOut(duration: 0.22), value: focus == nil)
            // Above both screens: most items live inside an album, and a count
            // hidden behind the album's own background would be useless exactly
            // where the selecting happens.
            .overlay(alignment: .bottomTrailing) {
                if isSelecting {
                    selectionBar
                        .padding(28)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.86), value: isSelecting)
            .animation(.easeOut(duration: 0.16), value: selection.count)

            if let focus, let item = item(with: focus.itemID) {
                focusOverlay(focus, item: item)
            }
        }
    }

    /// One toolbar for the window, switching with the screen. Three screens each
    /// declaring their own would all stay live — the library never leaves the
    /// hierarchy — and their items would stack up.
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // The introduction covers the window's content but not its chrome, which
        // is drawn by AppKit outside the hosting view. Left alone, Settings and
        // Refresh stay clickable over a modal first run — and Settings is where
        // the control for replaying that first run lives, which is a loop worth
        // not offering.
        if onboarding.isFinished {
            ToolbarItem(placement: .navigation) {
                // Both the album and the chats are screens the window went into,
                // so both leave by the same door.
                if openAlbum != nil || isShowingChats {
                    backButton
                }
            }

            ToolbarItemGroup(placement: .primaryAction) {
                if isShowingChats {
                    // Nothing else on this screen acts on the shelf, and a
                    // Refresh that reprocessed every capture from inside a
                    // conversation would be a button with no visible effect and
                    // a long one.
                    settingsButton
                } else {
                    // Selecting only exists inside an album. On the library
                    // screen the things on show are piles and a pile is not a
                    // thing that can be picked or deleted — offering Select
                    // there put the window in a mode where the only visible
                    // targets did nothing.
                    if openAlbum != nil {
                        if isSelecting && !selection.isEmpty {
                            Button("Delete", systemImage: "trash") {
                                pendingDelete = items.filter { selection.contains($0.id) }
                            }
                            .tint(.red)
                            .accessibilityLabel("Delete \(selection.count) selected")
                        }

                        Button(isSelecting ? "Done" : "Select") {
                            setSelecting(!isSelecting)
                        }
                        .accessibilityHint(
                            isSelecting
                                ? "Leaves selection and clears what is picked"
                                : "Lets you pick several photos to delete at once"
                        )
                    } else {
                        refreshButton
                    }

                    historyButton
                    settingsButton
                }
            }
        }
    }

    private func focusOverlay(_ target: ShelfFocusTarget, item: ShelfItem) -> some View {
        ShelfFocusOverlay(
            target: target,
            title: item.title,
            subtitle: item.linkHost ?? item.kind.label,
            actions: focusActions(for: item),
            onDismiss: { focus = nil }
        ) {
            ShelfCover(item: item)
        }
    }

    private func focusActions(for item: ShelfItem) -> [ShelfFocusAction] {
        var actions: [ShelfFocusAction] = [
            ShelfFocusAction(title: "Open", systemImage: "arrow.up.forward.square") {
                selectedItem = item
            }
        ]

        if item.kind == .link, let url = item.linkURL {
            actions.append(
                ShelfFocusAction(title: "Copy Link", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
            )
        }

        actions.append(
            ShelfFocusAction(title: "Delete", systemImage: "trash", isDestructive: true) {
                pendingDelete = [item]
            }
        )
        return actions
    }

    private func item(with id: UUID) -> ShelfItem? {
        items.first { $0.id == id }
    }

    /// Drops the shelf back to its resting state and lets it spring in again.
    ///
    /// The wait is the load-bearing part. The reset and the reveal cannot happen
    /// in the same pass — SwiftUI would see one value that never changed and
    /// animate nothing — but a single runloop turn is not enough either. Opening
    /// the window decodes every visible capture and lays out two masonry walls
    /// on the main thread, and a spring started inside that work is simply not
    /// drawn: the cards are already in place by the first frame that gets
    /// rendered. Letting the first layout finish first is what makes the pop
    /// something you actually see.
    private func playEntrance() async {
        isRevealed = false

        do {
            try await Task.sleep(for: .milliseconds(140))
        } catch {
            // Closed mid-wait. The shelf stays at rest, so reopening pops it.
            return
        }
        isRevealed = true
    }

    private func setSelecting(_ selecting: Bool) {
        withAnimation(.easeOut(duration: 0.18)) {
            isSelecting = selecting
            // Leaving the mode drops the picks with it; a hidden selection that
            // survives would delete the wrong things the next time it is opened.
            if !selecting { selection.removeAll() }
        }
    }

    /// What a click on a card does. In selection mode it picks, otherwise it
    /// opens — the same click, read against the current mode.
    private func activate(_ item: ShelfItem) {
        guard isSelecting else {
            selectedItem = item
            return
        }
        if selection.contains(item.id) {
            selection.remove(item.id)
        } else {
            selection.insert(item.id)
        }
    }

    private func confirmDelete() {
        let doomed = pendingDelete
        pendingDelete = []
        selection.subtract(doomed.map(\.id))
        modelContext.deleteShelfItems(doomed)

        // An emptied selection has nothing left to act on, so the mode goes too
        // rather than leaving a bare Done button behind.
        if selection.isEmpty {
            setSelecting(false)
        }
    }

    /// Says what the mode is and how much is picked. The toolbar carries the
    /// actions; this is the running count, which a button label can't hold.
    private var selectionBar: some View {
        Text(
            selection.isEmpty
                ? "Select items to delete"
                : (selection.count == 1 ? "1 selected" : "\(selection.count) selected")
        )
        .font(.subheadline.weight(.medium))
        .foregroundStyle(selection.isEmpty ? .secondary : .primary)
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(.regularMaterial, in: Capsule())
        .overlay { Capsule().strokeBorder(.primary.opacity(0.12), lineWidth: 1) }
        .shadow(color: .black.opacity(0.28), radius: 14, y: 6)
    }

    private var backButton: some View {
        Button(action: goBack) {
            Label("Back", systemImage: "chevron.left")
                .labelStyle(.iconOnly)
        }
        // The fade belongs to the album's implode; chats leaves by a plain
        // crossfade and must not inherit a chrome value the album left behind.
        .opacity(isShowingChats ? 1 : albumChrome)
        .accessibilityLabel("Back to library")
    }

    /// Leaves whichever screen the window went into. Chats first: it is drawn
    /// over the album, so it is the one being looked at when both are up.
    private func goBack() {
        if isShowingChats {
            withAnimation(.easeOut(duration: 0.2)) { isShowingChats = false }
            return
        }
        closeAlbum()
    }

    @MainActor
    private func showAlbum(_ key: ShelfAlbumKey) {
        let token = beginTransition()
        albumScattered = false
        albumChrome = 1
        openAlbum = key

        Task { @MainActor in
            // One committed frame with the images heaped on the pile, then
            // release, so the burst is seen starting from the pile.
            try? await Task.sleep(for: .milliseconds(50))
            guard albumTransition == token else { return }
            albumScattered = true
        }
    }

    @MainActor
    private func closeAlbum() {
        guard openAlbum != nil else { return }
        let token = beginTransition()
        albumScattered = false
        // Selecting belongs to the album that was open. Leaving it behind would
        // strand the library in a mode whose only control has just gone.
        setSelecting(false)

        // The chrome holds until the images are most of the way home, so the
        // library is revealed by the fade rather than by a cut.
        withAnimation(.easeOut(duration: 0.3).delay(0.3)) {
            albumChrome = 0
        }

        Task { @MainActor in
            try? await Task.sleep(for: Self.implodeDuration)
            guard albumTransition == token else { return }
            openAlbum = nil
            albumChrome = 1
        }
    }

    /// Claims the in-flight transition. Reopening an album mid-implode would
    /// otherwise let the old close finish and tear the new screen back down.
    private func beginTransition() -> Int {
        albumTransition &+= 1
        return albumTransition
    }

    private var library: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if items.isEmpty {
                    VStack(spacing: 0) {
                        wordmark
                            .padding(.horizontal, 32)
                            .padding(.top, 26)
                            .padding(.bottom, 22)

                        emptyState
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(.horizontal, 32)
                            .padding(.bottom, 32)
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 30) {
                            // The wordmark rides in the content, so it passes
                            // under the bar's blur on the way out instead of
                            // sitting on a fixed strip above it.
                            wordmark
                                .frame(maxWidth: .infinity)
                                .padding(.bottom, 2)

                            searchAndFilterRow

                            if albums.isEmpty && otherItems.isEmpty {
                                filteredEmptyState
                                    .frame(maxWidth: .infinity)
                                    .padding(.top, 40)
                            }

                            if !albums.isEmpty {
                                MasonryLayout(minimumColumnWidth: 260, spacing: 26) {
                                    ForEach(Array(albums.enumerated()), id: \.element.id) { index, album in
                                        Button {
                                            showAlbum(album.key)
                                        } label: {
                                            // The pile reports its own rect in
                                            // global space, so the album screen
                                            // can line up with it without the
                                            // two sharing an ancestor.
                                            ImageAlbumCard(album: album) { frame in
                                                pileFrames[album.key] = frame
                                            }
                                        }
                                        .buttonStyle(.plain)
                                        .modifier(ShelfEntrance(isRevealed: isRevealed, order: index))
                                    }
                                }
                            }

                            if !otherItems.isEmpty {
                                VStack(alignment: .leading, spacing: 14) {
                                    Text(albums.isEmpty ? "Saved items" : "Other saved items")
                                        .font(.title3.weight(.semibold))

                                    MasonryLayout(minimumColumnWidth: 216, spacing: 18) {
                                        ForEach(Array(otherItems.enumerated()), id: \.element.id) { index, item in
                                            Button {
                                                activate(item)
                                            } label: {
                                                SavedItemCard(
                                                    item: item,
                                                    isSelected: selection.contains(item.id)
                                                )
                                            }
                                            .buttonStyle(.plain)
                                            // The stagger carries on from the
                                            // albums rather than restarting, so
                                            // the shelf lands as one wave.
                                            .modifier(
                                                ShelfEntrance(
                                                    isRevealed: isRevealed,
                                                    order: albums.count + index
                                                )
                                            )
                                            .onSecondaryClick { frame in
                                                focus = ShelfFocusTarget(itemID: item.id, frame: frame)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 32)
                        .padding(.bottom, 32)
                    }
                    .scrollIndicators(.automatic)
                    // The shelf runs under the toolbar and the system blurs and
                    // fades it out at that edge, so the bar reads as floating
                    // over the content rather than as a strip above it.
                    .scrollEdgeEffectStyle(.soft, for: .top)
                }
            }

            // Adding and deleting are opposite intents; showing both at once
            // invites the wrong one.
            if !isSelecting {
                floatingAddButton
                    .padding(28)
                    .transition(.opacity)
            }
        }
        .background(CoveTheme.windowBackground)
    }

    /// What the filter and the query together let through. Everything the
    /// library draws is built from this rather than from `items`, so one pill or
    /// one word governs the albums, the cards, and the empty state at once.
    private var visibleItems: [ShelfItem] {
        let matching = items.filter { item in
            filter.matches(item) && (searchMatches?.contains(item.id) ?? true)
        }
        // Only while searching. With no query there is no ranking, and the
        // shelf's own newest-first order is the right one.
        guard let searchRanking else { return matching }
        return matching.sorted {
            (searchRanking[$0.id] ?? .max) < (searchRanking[$1.id] ?? .max)
        }
    }

    /// Runs the shelf's search, debounced.
    ///
    /// Restarted on every keystroke by `task(id:)`, so the sleep is the whole
    /// debounce: a cancelled task never reaches the search, and someone typing
    /// at speed scores the shelf once at the end rather than once per letter.
    private func runSearch() async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchMatches = nil
            searchRanking = nil
            return
        }

        do {
            try await Task.sleep(for: .milliseconds(180))
        } catch {
            return
        }

        let results = (try? await AIServices.current.search.search(query, in: items)) ?? []
        searchMatches = Set(results.map(\.id))
        searchRanking = Dictionary(
            uniqueKeysWithValues: results.enumerated().map { ($0.element.id, $0.offset) }
        )
    }

    /// The pills worth offering: the shelf's own kinds, in a fixed order, plus
    /// All. A pill for a kind nothing on the shelf has is a control that can
    /// only ever empty the screen.
    private var availableFilters: [ShelfFilter] {
        let offered = ShelfFilter.selectable.filter { candidate in
            items.contains(where: candidate.matches)
        }
        return offered.count > 1 ? [.all] + offered : []
    }

    /// Links are excluded on purpose, and it is load-bearing. A link with a
    /// fetched cover has `imageData` like any screenshot does, so grouping on
    /// that alone would file it into an image album — where it stops being a
    /// link and starts being an anonymous picture of a web page.
    private var imageAlbums: [ShelfImageAlbum] {
        let visual = visibleItems.filter { $0.imageData != nil && $0.kind != .link }
        return Dictionary(grouping: visual, by: \.imageCategory)
            .map { category, items in
                ShelfImageAlbum(
                    key: .images(category),
                    items: items.sorted { $0.createdAt > $1.createdAt }
                )
            }
    }

    private var linkItems: [ShelfItem] {
        visibleItems.filter { $0.kind == .link }
    }

    /// What's left once the albums have taken theirs: notes and files.
    private var otherItems: [ShelfItem] {
        visibleItems.filter { $0.imageData == nil && $0.kind != .link }
    }

    /// Every pile on the top wall, newest first. Links are one pile among the
    /// visual categories rather than a wall of their own — they are another kind
    /// of thing the user kept, not a different part of the app.
    private var albums: [ShelfImageAlbum] {
        var all = imageAlbums
        if !linkItems.isEmpty {
            all.append(ShelfImageAlbum(key: .links, items: linkItems))
        }
        return all.sorted { lhs, rhs in
            if lhs.latestDate == rhs.latestDate {
                return lhs.key.title < rhs.key.title
            }
            return lhs.latestDate > rhs.latestDate
        }
    }

    private func albumItems(in key: ShelfAlbumKey) -> [ShelfItem] {
        albums.first(where: { $0.key == key })?.items ?? []
    }

    private var wordmark: some View {
        Text("Cove")
            .font(.system(size: 30, weight: .semibold, design: .serif))
            .foregroundStyle(CoveTheme.windowInk.opacity(0.62))
            .coveShimmer(
                isActive: model.isRefreshing,
                startedAt: model.refreshStartedAt
            )
            .accessibilityLabel("Cove")
    }

    private var refreshButton: some View {
        Button(action: refreshShelf) {
            Label(
                model.isRefreshing ? "Refreshing" : "Refresh",
                systemImage: "arrow.clockwise"
            )
            .symbolEffect(.rotate, isActive: model.isRefreshing)
        }
        .disabled(model.isRefreshing)
        .accessibilityHint("Reprocesses the shelf with the current OCR, enrichment, and embedding services")
    }

    private var historyButton: some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) { isShowingChats = true }
        } label: {
            Label("Chats", systemImage: "bubble.left.and.bubble.right")
        }
        .accessibilityHint("Shows what you have asked Cove, and what it said back")
    }

    private var settingsButton: some View {
        Button {
            isShowingSettings = true
        } label: {
            Label("Settings", systemImage: "gearshape")
        }
        .accessibilityHint("Shows what Cove runs on device: embeddings, albums, text recognition, and search")
    }

    private var floatingAddButton: some View {
        Menu {
            Button("Link", systemImage: "link") { isAddingLink = true }
            Button("Text", systemImage: "note.text") { isAddingNote = true }
            Divider()
            Button("Image", systemImage: "photo") { addFiles(ofType: [.image]) }
            Button("File", systemImage: "doc") { addFiles(ofType: nil) }
        } label: {
            Label("Add", systemImage: "plus")
                .font(.headline)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.glass)
        .controlSize(.extraLarge)
        .fixedSize()
        .accessibilityHint("Choose what to add to your Cove shelf")
    }

    /// One row of glass pills, scrolling sideways if the shelf holds enough
    /// kinds to overflow a narrow window.
    ///
    /// A segmented control would have been the AppKit reflex, but it fixes its
    /// segments to equal widths and boxes them in a frame — on a screen whose
    /// whole idea is loose piles of images with no plate behind them, that reads
    /// as furniture from another app. Glass is the right material here for the
    /// same reason it is right on the Add button: these float over the shelf
    /// rather than sitting in a bar above it, and the images should show through.
    /// Deliberately short. A field the width of the window would read as the
    /// point of the screen, and the point of this screen is the shelf — this is
    /// the way to narrow it, sitting above the pills that do the same job by
    /// kind.
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("Search", text: $searchText)
                .textFieldStyle(.plain)
                .font(.subheadline)
                .focused($isSearchFocused)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    isSearchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .transition(.opacity)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        // A fixed width rather than a flexible one: it shares a row with the
        // pills, and a field that grew to fill the gap would turn the row into
        // a search bar with some buttons stuck on the end.
        .frame(width: 190)
        // Same material as the pills beside it, so the row reads as one control.
        .glassEffect(.regular.interactive(), in: Capsule())
        // The glass is drawn outside the field, so without this only the glyph
        // and the text itself take a click — the same gap that made the pills
        // miss.
        .contentShape(Capsule())
        .onTapGesture { isSearchFocused = true }
        .animation(.easeOut(duration: 0.15), value: searchText.isEmpty)
    }

    /// The field and the pills on one line, centred under the wordmark. They do
    /// the same job — narrowing the shelf — so they belong on the same row and
    /// scroll together when the window is too narrow to hold them.
    private var searchAndFilterRow: some View {
        ScrollView(.horizontal) {
            // Spacing 0 rather than the row's own 8: inside a container, glass
            // shapes closer than this distance flow together. That merge is the
            // right effect for a cluster of icons, and the wrong one here —
            // these are separate choices and have to read as separate.
            GlassEffectContainer(spacing: 0) {
                HStack(spacing: 8) {
                    searchField

                    ForEach(availableFilters) { candidate in
                        pill(candidate)
                    }
                }
            }
            // Centred under the wordmark. A horizontal scroll view sizes its
            // content to fit, so there is nothing for an alignment to work
            // against — the row has to be told to fill the viewport before it
            // can sit in the middle of it. Once the pills outgrow the window
            // their own width wins and the row scrolls from the leading edge,
            // which is the behaviour that matters on a narrow window.
            .frame(minWidth: pillRowWidth, alignment: .center)
            .padding(.vertical, 2)
        }
        .scrollIndicators(.never)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            pillRowWidth = width
        }
    }

    private func pill(_ candidate: ShelfFilter) -> some View {
        let isOn = candidate == filter

        return Button {
            withAnimation(.snappy(duration: 0.28)) { filter = candidate }
        } label: {
            Label(candidate.title, systemImage: candidate.systemImage)
                .font(.subheadline.weight(.medium))
                // Asked for rather than picked. Whether cream or black reads on
                // the pill depends on which of the six accents is selected, and
                // this line has been hardcoded wrong in both directions.
                .foregroundStyle(isOn ? AnyShapeStyle(CoveTheme.onAccent) : AnyShapeStyle(.primary))
                .padding(.horizontal, 15)
                .padding(.vertical, 8)
                // Load-bearing. A plain button hit-tests what it actually draws,
                // which here is the glyph and the word — the padding between
                // them and the capsule's edge is empty, so clicks near the rim
                // fell straight through to the shelf behind. The glass is drawn
                // outside the button and contributes no hit region of its own,
                // so the shape has to be declared here.
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        // `.interactive()` is what makes the glass answer the pointer — it
        // swells under a press and settles back, which is the whole point of
        // the material over a static capsule.
        .glassEffect(
            isOn
                ? .regular.tint(CoveTheme.accent).interactive()
                : .regular.interactive(),
            in: Capsule()
        )
        .glassEffectID(candidate.id, in: filterGlass)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }

    /// Shown when the filter is the reason the screen is bare. Distinct from the
    /// empty shelf on purpose: nothing is missing, and the way out is one click
    /// rather than saving something new.
    private var filteredEmptyState: some View {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        return VStack(spacing: 10) {
            Image(systemName: query.isEmpty ? filter.systemImage : "magnifyingglass")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)

            // Naming the query matters: with a pill also narrowing the shelf,
            // "nothing here" leaves it ambiguous which of the two emptied it.
            Text(query.isEmpty ? "No \(filter.title.lowercased()) yet" : "Nothing matches “\(query)”")
                .font(.headline)

            Button("Show everything") {
                withAnimation(.snappy(duration: 0.28)) {
                    filter = .all
                    searchText = ""
                }
            }
            .buttonStyle(.glass)
            .padding(.top, 4)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.tertiary)

            Text("Your shelf is clear")
                .font(.title3.weight(.semibold))

            Text("Add a file here, paste something into Cove, or drop it on the notch. Saved items will arrange themselves here.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 390)
        }
    }

    private func addFiles(ofType contentTypes: [UTType]?) {
        CaptureIngest.importFromOpenPanel(into: modelContext, contentTypes: contentTypes)
    }

    /// Both composers hand off to the same builders the notch and the clipboard
    /// use, so a link typed here is indistinguishable from one dropped on the
    /// island — including the duplicate check and the pipeline hand-off.
    private func addLink(_ text: String) {
        guard let url = Self.normalizedURL(from: text),
              let item = CaptureIngest.item(from: url, sourceApp: nil) else {
            return
        }
        CaptureIngest.insert(item, into: modelContext)
    }

    private func addNote(_ text: String) {
        guard let item = CaptureIngest.item(fromText: text, sourceApp: nil) else { return }
        CaptureIngest.insert(item, into: modelContext)
    }

    /// Accepts what people actually type. "github.com" is a URL to everyone
    /// except `URL(string:)`, which happily parses it as a relative path with no
    /// host at all — hence the explicit host and scheme checks.
    static func normalizedURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host(),
              host.contains(".") else {
            return nil
        }
        return url
    }

    private func refreshShelf() {
        guard !model.isRefreshing else { return }
        let startedAt = Date.now
        model.refreshStartedAt = startedAt
        model.isRefreshing = true

        Task {
            // An empty shelf can refresh before the first animation frame.
            // Finish the current complete sweep instead of dropping the band
            // part-way through its path; longer real work simply adds cycles.
            defer { model.isRefreshing = false }

            await waitForShelfRefresh()
            await finishShimmerCycle(startedAt: startedAt)
        }
    }

    private func waitForShelfRefresh() async {
        await ShelfProcessor.shared.refreshAll()
        while await ShelfProcessor.shared.isBusy {
            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                return
            }
        }
    }

    private func finishShimmerCycle(startedAt: Date) async {
        let elapsed = max(0, Date.now.timeIntervalSince(startedAt))
        let completedCycles = max(1, ceil(elapsed / CoveShimmer.period))
        let remaining = completedCycles * CoveShimmer.period - elapsed
        guard remaining > 0 else { return }

        let milliseconds = max(1, Int((remaining * 1_000).rounded(.up)))
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }
}

/// The pop each pile and card makes when the window arrives.
///
/// A spring rather than a fade because the shelf is a pile of physical-feeling
/// prints: they should land like objects being set down, with the small
/// overshoot a real one has. The stagger runs in reading order, so the eye is
/// led across the wall instead of everything appearing at once.
///
/// Scale and opacity only — no offset. `ImageAlbumCard` publishes its own frame
/// so the album screen can fly its images out of the pile, and `scaleEffect` is
/// a render transform that leaves that layout geometry untouched. An offset
/// would move it, and clicking a pile mid-entrance would burst from the wrong
/// place.
private struct ShelfEntrance: ViewModifier {
    let isRevealed: Bool
    /// Position in the wave.
    let order: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Enough to read as a pop, short of the rubber-band bounce that would make
    /// a shelf of twenty items feel unserious.
    private static let restingScale: CGFloat = 0.80
    private static let step: Double = 0.055
    /// Past about half a second the last card arrives long after the window has
    /// settled, and the wave stops reading as one gesture.
    private static let maximumDelay: Double = 0.5

    private var isSettled: Bool { isRevealed || reduceMotion }

    func body(content: Content) -> some View {
        content
            .scaleEffect(isSettled ? 1 : Self.restingScale)
            .opacity(isSettled ? 1 : 0)
            .animation(
                reduceMotion
                    ? .easeOut(duration: 0.2)
                    // Under-damped on purpose: the card overshoots a little and
                    // settles back, which is what makes it read as landing
                    // rather than as fading up.
                    : .spring(response: 0.45, dampingFraction: 0.58)
                        .delay(min(Double(order) * Self.step, Self.maximumDelay)),
                value: isSettled
            )
    }
}

/// Narrows the library to one kind of capture.
///
/// Deliberately coarser than `ShelfItemKind`: screenshots and images are the
/// same thing to someone looking for a picture they saved, and splitting them
/// would put two pills on screen that most people could not tell apart.
private enum ShelfFilter: String, CaseIterable, Identifiable {
    case all
    case images
    case links
    case notes
    case files

    var id: String { rawValue }

    /// Everything except All, in the order the pills appear.
    static var selectable: [ShelfFilter] {
        allCases.filter { $0 != .all }
    }

    var title: String {
        switch self {
        case .all: "All"
        case .images: "Images"
        case .links: "Links"
        case .notes: "Text"
        case .files: "Files"
        }
    }

    var systemImage: String {
        switch self {
        case .all: "square.stack.3d.up"
        case .images: "photo"
        case .links: "link"
        case .notes: "note.text"
        case .files: "doc"
        }
    }

    /// Images are matched on carrying a bitmap rather than on their kind, and
    /// links are excluded from that for the same reason they are excluded from
    /// the albums: a link that fetched a cover has `imageData` too, and it is
    /// still a link.
    func matches(_ item: ShelfItem) -> Bool {
        switch self {
        case .all: true
        case .images: item.imageData != nil && item.kind != .link
        case .links: item.kind == .link
        case .notes: item.kind == .text && item.imageData == nil
        case .files: item.kind == .file && item.imageData == nil
        }
    }
}

/// What a pile on the top wall stands for.
///
/// Kept separate from `ShelfImageCategory` on purpose: that enum is the visual
/// classifier's vocabulary and its raw values are persisted in every item's
/// extraction. "Link" is not something the classifier can ever decide, so it
/// gets its own case here rather than a fake category the model would then have
/// to pretend it recognises.
private enum ShelfAlbumKey: Hashable, Identifiable {
    case images(ShelfImageCategory)
    case links

    var id: String {
        switch self {
        case .images(let category): "images.\(category.rawValue)"
        case .links: "links"
        }
    }

    var title: String {
        switch self {
        case .images(let category): category.title
        case .links: "Links"
        }
    }

    var systemImage: String {
        switch self {
        case .images(let category): category.systemImage
        case .links: "link"
        }
    }
}

private struct ShelfImageAlbum: Identifiable {
    let key: ShelfAlbumKey
    let items: [ShelfItem]

    var id: ShelfAlbumKey { key }
    var latestDate: Date { items.map(\.createdAt).max() ?? .distantPast }
}

private struct AddLinkSheet: View {
    let onAdd: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var isFocused: Bool

    private var isValid: Bool { CoveWindowView.normalizedURL(from: text) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add a link")
                .font(.title3.weight(.semibold))

            TextField("example.com", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.body)
                .focused($isFocused)
                .onSubmit { if isValid { add() } }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .padding(24)
        .frame(width: 420)
        .onAppear { isFocused = true }
    }

    private func add() {
        onAdd(text)
        dismiss()
    }
}

private struct AddNoteSheet: View {
    let onAdd: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var isFocused: Bool

    private var isValid: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add a note")
                .font(.title3.weight(.semibold))

            TextEditor(text: $text)
                .font(.body)
                .focused($isFocused)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(CoveTheme.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .frame(minHeight: 180)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add", action: add)
                    .disabled(!isValid)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear { isFocused = true }
    }

    private func add() {
        onAdd(text)
        dismiss()
    }
}

/// Places each album or card in the shortest column. This is a layout rather
/// than a fixed grid so a stack of portraits can sit beside a wider landscape
/// stack without leaving a striped wall of gaps.
private struct MasonryLayout: Layout {
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

/// A visual category presented as an album rather than a list of cards. The
/// offset, rotation, and overlapping edges make the previews feel like a small
/// pile of real prints on a desk.
private struct ImageAlbumCard: View {
    let album: ShelfImageAlbum
    /// Reports the pile's own rect — not the cell's — so the album screen can
    /// land its images exactly on the prints they came from.
    var onPileFrame: (CGRect) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            ScatteredImageStack(items: album.items)
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .global)
                } action: { frame in
                    onPileFrame(frame)
                }

            Label(album.key.title, systemImage: album.key.systemImage)
                .font(.headline)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(album.key.title) album, \(album.items.count) items")
        .accessibilityHint("Opens the album")
    }
}

/// The picture that stands for one saved thing, wherever it is shown — heaped on
/// a pile, laid out on an album wall, or lifted under a right-click.
///
/// A captured image shows itself. A link shows the site's own artwork once a
/// preview lands, and until then a wash keyed to its domain: the same site looks
/// the same every time it is saved, and two different sites never match. The
/// fallback is a design rather than an apology — a grey rectangle would read as
/// a card that failed to load.
private struct ShelfCover: View {
    let item: ShelfItem

    private var host: String {
        item.linkHost ?? item.linkURL?.host() ?? "Link"
    }

    /// `linkTitle` holds the page's own title once a preview lands; before that
    /// it is the URL's last path component, worth showing only when it says
    /// something the host doesn't.
    private var caption: String {
        if let title = item.linkTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty,
           title.caseInsensitiveCompare(host) != .orderedSame {
            return title
        }
        return host
    }

    var body: some View {
        if let imageData = item.imageData {
            ShelfImageThumbnail(data: imageData)
        } else if item.kind == .link {
            drawnLinkCover
        } else {
            Color.secondary.opacity(0.12)
        }
    }

    private var drawnLinkCover: some View {
        ZStack {
            LinearGradient(
                colors: LinkPalette.colors(for: host),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(spacing: 9) {
                Image(systemName: "link")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))

                Text(caption)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.94))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 16)
            }
        }
    }
}

/// Colours a coverless link by its domain.
///
/// Derived from the host's own scalars rather than `hashValue`, which Swift
/// seeds per process — a card that changed colour on every launch would read as
/// a bug, and the whole point is that a site is recognisable at a glance.
private enum LinkPalette {
    static func colors(for host: String) -> [Color] {
        let hue = self.hue(for: host)

        return [
            Color(hue: hue, saturation: 0.52, brightness: 0.62),
            Color(hue: (hue + 0.09).truncatingRemainder(dividingBy: 1), saturation: 0.62, brightness: 0.40)
        ]
    }

    private static func hue(for host: String) -> Double {
        // FNV-1a over the scalars: stable across launches and machines, and it
        // scatters neighbouring domains rather than giving "a.com" and "b.com"
        // adjacent shades.
        var hash: UInt64 = 0xcbf29ce484222325
        for scalar in host.unicodeScalars {
            hash ^= UInt64(scalar.value)
            hash = hash &* 0x100000001b3
        }
        return Double(hash % 360) / 360
    }
}

/// A loose pile of the album's newest prints. Every card keeps the aspect ratio
/// of the image it shows, so a stack of portraits looks nothing like a stack of
/// panoramas — that difference is the whole point of an album preview. No card
/// is boxed into a shared frame and nothing sits on a background plate; the
/// images themselves are the card.
private struct ScatteredImageStack: View {
    let items: [ShelfItem]

    private var previews: [ShelfItem] { ScatterPlan.previews(of: items) }
    private var plan: ScatterPlan { ScatterPlan.pile(for: items) }

    var body: some View {
        let plan = plan

        ScatterStackLayout(plan: plan) {
            ForEach(Array(previews.enumerated()), id: \.element.id) { index, item in
                ShelfCover(item: item)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(.white.opacity(0.18), lineWidth: 1)
                    }
                    .rotationEffect(.degrees(plan.rotation(at: index)))
                    .shadow(color: .black.opacity(0.28), radius: 10, y: 6)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Sizes and places the pile from a `ScatterPlan`.
///
/// This is a `Layout` rather than a `GeometryReader` because the masonry asks
/// for a height given a width, and a `GeometryReader` has no height to report —
/// it would collapse to its placeholder size and take the whole pile with it.
/// A layout answers that question directly.
private struct ScatterStackLayout: Layout {
    let plan: ScatterPlan

    typealias Cache = Void

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) -> CGSize {
        let width = resolvedWidth(from: proposal)
        return CGSize(width: width, height: width / plan.aspectRatio)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) {
        let width = bounds.width

        for (index, subview) in subviews.enumerated() {
            guard index < plan.cards.count else { continue }
            let card = plan.cards[index]
            let size = CGSize(
                width: card.size.width * width,
                height: card.size.height * width
            )

            // Rotation is applied inside the subview, so placement works on the
            // upright card and the plan has already reserved room for the
            // corners the rotation swings out.
            subview.place(
                at: CGPoint(
                    x: bounds.midX + card.offset.width * width,
                    y: bounds.midY + card.offset.height * width
                ),
                anchor: .center,
                proposal: ProposedViewSize(size)
            )
        }
    }

    private func resolvedWidth(from proposal: ProposedViewSize) -> CGFloat {
        guard let width = proposal.width, width.isFinite, width > 0 else {
            return 260
        }
        return width
    }
}

private struct ScatterLayer {
    let width: CGFloat
    let rotation: Double
    let offset: CGSize
}

/// Resolves the pile's geometry in units of the container width, which makes it
/// resolution-independent: the caller only has to supply a width.
///
/// The pile is normalised so its widest rotated corner lands exactly on the
/// container edge — otherwise a steeply rotated landscape card would spill out
/// of the column and be clipped by the scroll view.
private struct ScatterPlan {
    struct Card {
        let size: CGSize
        let offset: CGSize
        let rotation: Double
    }

    let cards: [Card]
    /// Width over height, so a caller holding a width can derive the height.
    let aspectRatio: CGFloat

    /// Back-to-front. Widths and offsets are fractions of the container width,
    /// so the pile scales with the column instead of being pinned to a size.
    private static let layers: [ScatterLayer] = [
        ScatterLayer(width: 0.56, rotation: -13, offset: CGSize(width: -0.24, height: 0.055)),
        ScatterLayer(width: 0.54, rotation: 11, offset: CGSize(width: 0.25, height: 0.085)),
        ScatterLayer(width: 0.58, rotation: 6, offset: CGSize(width: 0.10, height: -0.075)),
        ScatterLayer(width: 0.62, rotation: -4, offset: CGSize(width: -0.05, height: 0.015))
    ]

    /// The prints the pile actually shows, newest last so the most recent
    /// capture ends up on top.
    static func previews(of items: [ShelfItem]) -> [ShelfItem] {
        Array(items.prefix(layers.count)).reversed()
    }

    /// The one description of the pile's geometry. The library draws from it and
    /// the album screen animates to it, so "where the images were" is a fact
    /// both screens read rather than two estimates that drift apart.
    static func pile(for items: [ShelfItem]) -> ScatterPlan {
        let previews = previews(of: items)
        return ScatterPlan(
            layers: Array(layers.suffix(previews.count)),
            aspectRatios: previews.map(ShelfImageAspect.ratio(for:))
        )
    }

    func rotation(at index: Int) -> Double {
        guard index < cards.count else { return 0 }
        return cards[index].rotation
    }

    /// Maps an album item's position (newest first) to the pile card it sits on.
    /// Items past the pile's depth take the front card's place, so they fly out
    /// from under the top print instead of from nowhere.
    func card(forItemAt order: Int) -> Card? {
        guard !cards.isEmpty else { return nil }
        guard order < cards.count else { return cards[cards.count - 1] }
        return cards[cards.count - 1 - order]
    }

    init(layers: [ScatterLayer], aspectRatios: [CGFloat]) {
        guard !layers.isEmpty else {
            cards = []
            aspectRatio = 1
            return
        }

        var boxes: [(size: CGSize, halfWidth: CGFloat, halfHeight: CGFloat)] = []

        for (index, layer) in layers.enumerated() {
            let imageAspect = max(aspectRatios[index], 0.01)
            let size = CGSize(width: layer.width, height: layer.width / imageAspect)
            let radians = layer.rotation * .pi / 180
            let cosine = abs(cos(radians))
            let sine = abs(sin(radians))
            // Bounding box of the rotated card, so the shape that is actually
            // drawn is the one that decides how much room the pile needs.
            let rotatedWidth = size.width * cosine + size.height * sine
            let rotatedHeight = size.width * sine + size.height * cosine

            boxes.append(
                (
                    size,
                    abs(layer.offset.width) + rotatedWidth / 2,
                    abs(layer.offset.height) + rotatedHeight / 2
                )
            )
        }

        let widest = boxes.map(\.halfWidth).max() ?? 0.5
        let scale = widest > 0 ? 0.5 / widest : 1

        cards = zip(layers, boxes).map { layer, box in
            Card(
                size: CGSize(width: box.size.width * scale, height: box.size.height * scale),
                offset: CGSize(
                    width: layer.offset.width * scale,
                    height: layer.offset.height * scale
                ),
                rotation: layer.rotation
            )
        }

        let height = 2 * (boxes.map(\.halfHeight).max() ?? 0.5) * scale
        aspectRatio = height > 0 ? 1 / height : 1
    }
}

/// Decoding an image only to read `size` is wasteful to repeat on every body
/// pass, and the pile re-reads the same handful of images constantly. Aspect
/// ratios never change for a stored capture, so one measurement per item is
/// enough for the life of the process.
@MainActor
private enum ShelfImageAspect {
    /// Close to the 1.91:1 most sites cut their share images to, pulled in a
    /// little so a coverless link doesn't dominate a column.
    static let drawnLinkRatio: CGFloat = 1.6

    private static var cache: [UUID: CGFloat] = [:]

    /// Width over height of whatever `ShelfCover` will actually draw — the real
    /// image when there is one, and the drawn card's own proportions when there
    /// isn't. Layout and rendering have to agree on this or the pile reserves
    /// room for a shape it never draws.
    static func ratio(for item: ShelfItem) -> CGFloat {
        if let cached = cache[item.id] { return cached }

        guard let data = item.imageData,
              let image = NSImage(data: data),
              image.size.width > 0,
              image.size.height > 0 else {
            return item.kind == .link ? drawnLinkRatio : 1.35
        }

        let ratio = image.size.width / image.size.height
        cache[item.id] = ratio
        return ratio
    }
}

/// The second screen: one album, pushed rather than presented. A sheet would
/// float the album above the library and keep the pile visible behind it, which
/// is the wrong story — the pile *becomes* this screen, so the images have to
/// arrive from where the pile was.
private struct ImageAlbumScreen: View {
    let items: [ShelfItem]
    /// Where the tapped pile sat on the library screen, in global space.
    let scatterFrame: CGRect?
    /// False heaps the images on the pile, true throws them to their slots.
    let isScattered: Bool
    /// Fades everything except the images, which stay solid all the way home.
    let chromeOpacity: Double
    let onSelect: (ShelfItem) -> Void
    var selection: Set<UUID> = []
    var onSecondaryClick: (ShelfItem, CGRect) -> Void = { _, _ in }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(CoveTheme.windowBackground)
                .opacity(chromeOpacity)
                .ignoresSafeArea()

            ScrollView {
                // No title in the content: the window's own title carries the
                // album's name, so the images get the whole screen.
                ScatterWall(
                    items: items,
                    scatterFrame: scatterFrame,
                    isScattered: isScattered,
                    onSelect: onSelect,
                    selection: selection,
                    onSecondaryClick: onSecondaryClick
                )
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            .scrollDisabled(!isScattered)
            .scrollEdgeEffectStyle(.soft, for: .top)
        }
    }
}

/// The album's images, packed into a masonry wall that they fly into.
///
/// On the first frame every card is heaped at the spot the pile occupied on the
/// library screen — same size, same tilts — and then springs out to its slot.
/// The stagger runs newest-first, so the card that was the top of the pile is
/// the first to leave it. Reversing `isScattered` runs the same motion the
/// other way, gathering the wall back into the pile it came from.
private struct ScatterWall: View {
    let items: [ShelfItem]
    let scatterFrame: CGRect?
    let isScattered: Bool
    let onSelect: (ShelfItem) -> Void
    var selection: Set<UUID> = []
    var onSecondaryClick: (ShelfItem, CGRect) -> Void = { _, _ in }

    private static let spacing: CGFloat = 16
    private static let minimumColumnWidth: CGFloat = 205
    /// Safety bounds only — cards keep the image's real proportions. The clamp
    /// guards degenerate files (extreme panoramas, corrupt headers) that would
    /// otherwise blow out a column.
    private static let heightRange: ClosedRange<CGFloat> = 0.35...3.0

    @State private var wallWidth: CGFloat = 0
    @State private var wallOrigin: CGPoint = .zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct PlacedItem: Identifiable {
        let item: ShelfItem
        /// Packing order across the whole wall; staggers the scatter.
        let order: Int
        let width: CGFloat
        let height: CGFloat
        /// Where the card rests, in the wall's own space.
        let center: CGPoint
        /// Vector from this card's slot to the print it came from.
        let delta: CGSize
        /// Size of that print, relative to the slot.
        let heapScale: CGFloat
        let tilt: Angle

        var id: UUID { item.id }
    }

    var body: some View {
        let columnWidth = columnWidth(for: wallWidth)
        let wall = layout(columnWidth: columnWidth)
        let count = items.count

        // Every card is a sibling in one container. Columns built from stacked
        // views would confine `zIndex` to each column, so a card from a later
        // column would cover the front print no matter what depth it claimed —
        // and the pile would rebuild with the wrong card on top.
        ZStack(alignment: .topLeading) {
            ForEach(wall.placed) { placed in
                card(placed)
                    .modifier(
                        ScatterEffect(
                            isScattered: isScattered || reduceMotion,
                            delta: placed.delta,
                            heapScale: placed.heapScale,
                            tilt: placed.tilt,
                            delay: Self.delay(order: placed.order, of: count, scattering: isScattered),
                            response: isScattered ? 0.55 : 0.42,
                            damping: isScattered ? 0.8 : 0.88
                        )
                    )
                    .position(placed.center)
                    // The heap stacks like the pile: newest on top, first out
                    // and last home.
                    .zIndex(-Double(placed.order))
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: wall.height)
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .global)
        } action: { frame in
            wallWidth = frame.width
            wallOrigin = frame.origin
        }
    }

    /// Flying out, the top print leads. Falling back, it lands last — the pile
    /// rebuilds from the bottom up, so nothing drops onto an empty spot and the
    /// card that ends up on top is the one that arrives last.
    private static func delay(order: Int, of count: Int, scattering: Bool) -> Double {
        let step = scattering ? order : max(0, count - 1 - order)
        return min(Double(step) * 0.03, 0.36)
    }

    private func card(_ placed: PlacedItem) -> some View {
        Button {
            onSelect(placed.item)
        } label: {
            ShelfCover(item: placed.item)
                .frame(width: placed.width, height: placed.height)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(
                            selection.contains(placed.id) ? CoveTheme.accent : .white.opacity(0.16),
                            lineWidth: selection.contains(placed.id) ? 3 : 1
                        )
                }
                .overlay(alignment: .topTrailing) {
                    if selection.contains(placed.id) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, CoveTheme.accent)
                            .padding(9)
                    }
                }
                .shadow(color: .black.opacity(0.22), radius: 8, y: 4)
        }
        .buttonStyle(.plain)
        .onSecondaryClick { frame in
            onSecondaryClick(placed.item, frame)
        }
        .accessibilityLabel(placed.item.title)
        .accessibilityHint("Opens item details")
    }

    /// Height over width, so a column knows how tall the card will draw.
    private static func heightRatio(of item: ShelfItem) -> CGFloat {
        let ratio = ShelfImageAspect.ratio(for: item)
        guard ratio > 0 else { return 1 }
        return min(max(1 / ratio, heightRange.lowerBound), heightRange.upperBound)
    }

    private func columnCount(for width: CGFloat) -> Int {
        guard width > 0 else { return 1 }
        return max(1, Int((width + Self.spacing) / (Self.minimumColumnWidth + Self.spacing)))
    }

    private func columnWidth(for width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        let count = CGFloat(columnCount(for: width))
        return (width - Self.spacing * (count - 1)) / count
    }

    /// Shortest-column-first packing, resolved to absolute centres so one flat
    /// container can hold the whole wall.
    private func layout(columnWidth: CGFloat) -> (placed: [PlacedItem], height: CGFloat) {
        guard columnWidth > 0 else { return ([], 0) }

        let count = columnCount(for: wallWidth)
        var placed: [PlacedItem] = []
        var heights = [CGFloat](repeating: 0, count: count)
        // The very same plan the library drew the pile from, so a card's resting
        // place on this screen and its print on the pile are one measurement,
        // not two guesses.
        let plan = ScatterPlan.pile(for: items)

        for (order, item) in items.enumerated() {
            let shortest = heights.enumerated().min { $0.element < $1.element }?.offset ?? 0
            let height = (Self.heightRatio(of: item) * columnWidth).rounded()
            let slotCenter = CGPoint(
                x: CGFloat(shortest) * (columnWidth + Self.spacing) + columnWidth / 2,
                y: heights[shortest] + height / 2
            )
            let print = printGeometry(for: order, in: plan, columnWidth: columnWidth)

            placed.append(
                PlacedItem(
                    item: item,
                    order: order,
                    width: columnWidth,
                    height: height,
                    center: slotCenter,
                    delta: CGSize(
                        width: print.center.x - slotCenter.x,
                        height: print.center.y - slotCenter.y
                    ),
                    heapScale: print.scale,
                    tilt: print.tilt
                )
            )
            heights[shortest] += height + Self.spacing
        }

        // The trailing spacing on the tallest column isn't content.
        let height = max(0, (heights.max() ?? 0) - Self.spacing)
        return (placed, height)
    }

    /// Where one card's print sits on the pile, in the wall's own space, and how
    /// big it is relative to the card's slot. Reproduces exactly what
    /// `ScatterStackLayout` did when it drew that print.
    private func printGeometry(
        for order: Int,
        in plan: ScatterPlan,
        columnWidth: CGFloat
    ) -> (center: CGPoint, scale: CGFloat, tilt: Angle) {
        guard let scatterFrame, let card = plan.card(forItemAt: order), columnWidth > 0 else {
            // No recorded pile: fall in from just above the wall.
            return (CGPoint(x: wallWidth / 2, y: -40), 0.6, .zero)
        }

        let pileWidth = scatterFrame.width
        let center = CGPoint(
            x: scatterFrame.midX + card.offset.width * pileWidth - wallOrigin.x,
            y: scatterFrame.midY + card.offset.height * pileWidth - wallOrigin.y
        )
        // Both the print and the slot hold the image's own ratio, so matching
        // width matches height too — one uniform scale lands it exactly.
        let scale = (card.size.width * pileWidth) / columnWidth

        return (center, scale, .degrees(card.rotation))
    }
}

/// Heaped state for one card: pulled back to the pile, tilted and shrunk. It
/// springs into place — offset, tilt, and scale all zeroing out — the moment
/// `isScattered` flips.
private struct ScatterEffect: ViewModifier {
    let isScattered: Bool
    let delta: CGSize
    let heapScale: CGFloat
    let tilt: Angle
    let delay: Double
    let response: Double
    let damping: Double

    func body(content: Content) -> some View {
        content
            .scaleEffect(isScattered ? 1 : heapScale)
            .rotationEffect(isScattered ? .zero : tilt)
            .offset(isScattered ? .zero : delta)
            .animation(
                .spring(response: response, dampingFraction: damping).delay(delay),
                value: isScattered
            )
    }
}

/// Non-image captures remain compact in the shelf too. Their information is
/// not lost; opening the card reveals the full source and captured content.
///
/// Like the albums, this carries no plate behind it: the glyph and the title
/// are the card, and the row takes only the height its own text needs.
private struct SavedItemCard: View {
    let item: ShelfItem
    var isSelected = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Image(systemName: item.kind.systemImage)
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(CoveTheme.accent)

                Spacer(minLength: 8)

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, CoveTheme.accent)
                }
            }

            Text(item.title)
                .font(.headline)
                .lineLimit(3)
                .multilineTextAlignment(.leading)

            Text(item.kind.label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityLabel("\(item.kind.label), \(item.title)")
        .accessibilityHint("Opens item details")
    }
}

private struct ShelfItemDetailView: View {
    let item: ShelfItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label(item.kind.label, systemImage: item.kind.systemImage)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Done") { dismiss() }
                    .buttonStyle(.glass)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let imageData = item.imageData {
                        ShelfImagePreview(data: imageData)
                            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    } else {
                        Image(systemName: item.kind.systemImage)
                            .font(.system(size: 44, weight: .light))
                            .foregroundStyle(CoveTheme.accent)
                            .frame(maxWidth: .infinity, minHeight: 160)
                            .background(CoveTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text(item.title)
                            .font(.title2.weight(.semibold))
                            .textSelection(.enabled)

                        processingStatus
                    }

                    if let detail = detail {
                        detailSection(title: "Captured content", value: detail)
                    }

                    if !item.tags.isEmpty {
                        VStack(alignment: .leading, spacing: 9) {
                            Text("Tags")
                                .font(.headline)

                            Text(item.tags.map { "#\($0)" }.joined(separator: "  "))
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(CoveTheme.accent)
                                .textSelection(.enabled)
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Details")
                            .font(.headline)

                        detailRow("Saved", value: item.createdAt.formatted(date: .abbreviated, time: .shortened))

                        if item.imageData != nil {
                            detailRow("Album", value: item.imageCategory.title)
                        }

                        if let sourceApp = item.sourceApp {
                            detailRow("Source", value: sourceApp)
                        }

                        if let link = item.linkURL?.absoluteString {
                            detailRow("Link", value: link)
                        }

                        if let failureMessage = item.failureMessage {
                            detailRow("Status", value: failureMessage, color: .red)
                        }
                    }
                }
                .padding(24)
            }
        }
        .frame(minWidth: 640, minHeight: 560)
        .background(CoveTheme.windowBackground)
    }

    @ViewBuilder
    private var processingStatus: some View {
        switch item.processingState {
        case .queued:
            Label("Queued", systemImage: "clock")
                .foregroundStyle(.secondary)
        case .processing:
            Label("Processing", systemImage: "sparkles")
                .foregroundStyle(CoveTheme.accent)
        case .ready:
            Label("Ready", systemImage: "checkmark")
                .foregroundStyle(.secondary)
        case .failed:
            Label("Needs attention", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        }
    }

    private var detail: String? {
        switch item.kind {
        case .text:
            item.userNote
        case .link:
            item.linkTitle ?? item.linkHost ?? item.linkURL?.absoluteString
        case .file:
            item.linkTitle ?? item.linkURL?.path
        case .image, .screenshot:
            [item.userNote, item.summary, item.extractedText]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first(where: { !$0.isEmpty })
        }
    }

    private func detailSection(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.headline)

            Text(value)
                .font(.body)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private func detailRow(_ label: String, value: String, color: Color = .secondary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(label)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)

            Text(value)
                .font(.subheadline)
                .foregroundStyle(color)
                .textSelection(.enabled)
        }
    }
}

private struct ShelfImageThumbnail: View {
    let data: Data?

    private var image: NSImage? { data.flatMap(NSImage.init(data:)) }

    var body: some View {
        if let image {
            // The frame handed to this view already matches the image's own
            // ratio, so filling it crops nothing — it only absorbs the rounding
            // error that would otherwise leave a hairline of empty card.
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
        } else {
            Color.secondary.opacity(0.10)
        }
    }
}

private struct ShelfImagePreview: View {
    let data: Data

    private var image: NSImage? { NSImage(data: data) }

    private var aspectRatio: CGFloat {
        guard let image, image.size.height > 0 else { return 1.35 }
        return image.size.width / image.size.height
    }

    var body: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .aspectRatio(aspectRatio, contentMode: .fit)
        } else {
            Color.secondary.opacity(0.08)
                .aspectRatio(aspectRatio, contentMode: .fit)
        }
    }
}

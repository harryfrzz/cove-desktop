import Foundation
import Observation

/// A moment's confirmation, sized for the notch.
///
/// The island has only the sliver either side of the camera housing to speak in,
/// and a sentence does not fit there — "3 items added" arrived clipped, which
/// reads as a bug rather than as a message. So a toast is a glyph and one word:
/// the glyph sits on one side of the notch and the word on the other, and the
/// count rides on the glyph when there is more than one.
struct NotchToast: Equatable, Sendable {
    var text: String
    var systemImage: String
    var isFailure = false
    /// Shown on the badge when a single drop carried several things.
    var count: Int?
    /// Whether this word is about something the pipeline is still working on,
    /// and so should wait its turn behind the band.
    ///
    /// Only a saved capture is: holding a file and failing to read one are both
    /// finished the moment they are announced, and a confirmation that arrived
    /// late for those would just read as lag.
    var awaitsProcessing = false

    static func saved(count: Int) -> NotchToast {
        NotchToast(
            text: "Added",
            systemImage: "checkmark.circle.fill",
            count: count > 1 ? count : nil,
            awaitsProcessing: true
        )
    }

    static func held(count: Int) -> NotchToast {
        NotchToast(text: "Held", systemImage: "tray.fill", count: count > 1 ? count : nil)
    }

    /// Not a confirmation that anything happened, because nothing has yet — the
    /// panel is about to open on a prompt bar with the thing attached, and this
    /// is what the island says on the way there.
    static let attached = NotchToast(text: "Ask about this", systemImage: "sparkles")

    static let nothingToSave = NotchToast(
        text: "Can't save",
        systemImage: "xmark.circle.fill",
        isFailure: true
    )
}

/// What the island shows when it is *not* open: the pipeline's current state,
/// as one line of status either side of the notch.
///
/// This is the desktop counterpart to the phone's Live Activity, and it is fed
/// the same way — value snapshots pushed from the processing actor, never model
/// objects. The island reads only from here, so the pipeline has no idea a UI
/// exists.
@MainActor
@Observable
final class NotchActivityCenter {
    static let shared = NotchActivityCenter()

    /// Items currently in flight, newest last.
    private(set) var inFlight: [ShelfActivitySnapshot] = []
    /// The last thing that finished, held briefly so a capture that takes 200 ms
    /// still shows the user it landed.
    private(set) var recentlyFinished: ShelfActivitySnapshot?
    /// A one-off word the island shows for a moment — "Added", "Held".
    private(set) var toast: NotchToast?

    /// A word that has been said but is waiting for the band to finish.
    ///
    /// Counted as activity even though nothing shows it yet. Without this the
    /// island has a gap between the drop and the pipeline's first phase where it
    /// has nothing to say, falls back into the notch, and immediately grows
    /// again — a flinch on every capture.
    private var pendingToast: NotchToast?

    /// Set while a drag is over the island, so the closed state can open into a
    /// drop target before the mouse gets there.
    var isDropTargeted = false {
        didSet { announce() }
    }

    /// The island's window has to resize when this becomes true or false, and
    /// that is AppKit's job rather than SwiftUI's. `NotchController` sets this.
    var onActivityChange: ((Bool) -> Void)?

    private var clearTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var holdTask: Task<Void, Never>?

    /// When the current run of work began, or `nil` if nothing is running.
    ///
    /// Exists so the band is allowed to finish crossing. Without embeddings
    /// installed a capture is queued, read and done inside a few hundred
    /// milliseconds — faster than one pass of the shimmer — so the status it
    /// belongs to appeared and vanished between two frames and the island simply
    /// never looked busy. This is what a sweep is measured against.
    private var workingSince: Date?

    /// Whether work — or the tail of the band drawn for it — is still running.
    var isBandRunning: Bool { workingSince != nil }

    /// How much of one sweep is left to draw. Zero when nothing is running.
    private var remainingBandTime: TimeInterval {
        guard let workingSince else { return 0 }
        return max(0, CoveShimmer.period - Date.now.timeIntervalSince(workingSince))
    }

    private init() {}

    /// Whether the island has anything to say while closed.
    ///
    /// Holding something counts, and it is the one entry here that does not
    /// expire. Everything else is a moment — a capture in flight, a word about
    /// one that landed — and falls back into the notch on its own. A parked file
    /// stays parked until it is taken somewhere or Cove quits, and an island
    /// that closed over it would be hiding the only evidence that it is there.
    var hasActivity: Bool {
        !inFlight.isEmpty
            || recentlyFinished != nil
            || toast != nil
            || pendingToast != nil
            || isDropTargeted
            || !TempTray.shared.isEmpty
    }

    /// What is being held, if anything. Read by the compact strip.
    var held: TempTray.Entry? { TempTray.shared.latest }
    var heldCount: Int { TempTray.shared.entries.count }

    /// Called by `TempTray` whenever what it holds changes, so the closed island
    /// can grow to say so or fall back into the notch once it is empty.
    func trayDidChange() {
        announce()
    }

    /// The one snapshot the compact strip shows when several are in flight: the
    /// newest, because that is the one the user just handed over.
    var headline: ShelfActivitySnapshot? {
        inFlight.last ?? recentlyFinished
    }

    func update(_ snapshot: ShelfActivitySnapshot) {
        switch snapshot.phase {
        case .done, .failed:
            // Work that outran the band is held at its last live phase until the
            // sweep has crossed once. The status stays honest — something did
            // happen, and this is the phase it was in — it is only allowed to
            // be seen.
            let remaining = remainingBandTime
            guard remaining <= 0 else {
                holdTask?.cancel()
                holdTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(remaining))
                    guard !Task.isCancelled else { return }
                    self?.settle(snapshot)
                }
                return
            }
            settle(snapshot)

        default:
            if workingSince == nil { workingSince = .now }
            if let index = inFlight.firstIndex(where: { $0.id == snapshot.id }) {
                inFlight[index] = snapshot
            } else {
                inFlight.append(snapshot)
            }
            clearTask?.cancel()
            announce()
        }
    }

    /// Applies a finished snapshot, once it is allowed to land.
    private func settle(_ snapshot: ShelfActivitySnapshot) {
        inFlight.removeAll { $0.id == snapshot.id }
        recentlyFinished = snapshot
        if inFlight.isEmpty { workingSince = nil }
        scheduleClear()
        announce()
    }

    /// Says a word, once the band has had its pass.
    ///
    /// A toast hides the status it would otherwise be shimmering over — the
    /// strip has one line and the word takes it — so a confirmation posted the
    /// instant a file is dropped silences the band for its whole 2.4 seconds,
    /// which is longer than the work takes. Letting it wait costs about a
    /// second and is the difference between an island that looks like it did
    /// something and one that blinks.
    ///
    /// Capped, because a stuck pipeline must not be able to swallow the
    /// confirmation entirely.
    func post(_ message: NotchToast) {
        toastTask?.cancel()
        pendingToast = message
        announce()

        toastTask = Task { [weak self] in
            if message.awaitsProcessing {
                await self?.waitForBand()
                guard !Task.isCancelled else { return }
            }
            self?.show(message)
        }
    }

    /// Waits for work to appear and then to finish.
    ///
    /// The grace at the top is not optional. `CaptureIngest.insert` hands the
    /// item to the processor in a detached task, so this is always called
    /// *before* the pipeline has announced anything — without a moment to let
    /// the first phase arrive, there is never any band to wait for.
    private func waitForBand(
        grace: Duration = .milliseconds(300),
        cap: Duration = .seconds(4)
    ) async {
        let deadline = ContinuousClock.now.advanced(by: cap)

        try? await Task.sleep(for: grace)
        guard !Task.isCancelled else { return }

        while isBandRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
        }
    }

    private func show(_ message: NotchToast) {
        pendingToast = nil
        toast = message
        announce()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.4))
            guard !Task.isCancelled else { return }
            self?.toast = nil
            self?.announce()
        }
    }

    private func scheduleClear() {
        clearTask?.cancel()
        clearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            guard let self, self.inFlight.isEmpty else { return }
            self.recentlyFinished = nil
            self.announce()
        }
    }

    private func announce() {
        onActivityChange?(hasActivity)
    }
}

import Foundation
import Observation

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
    /// A one-off line the island shows for a moment — "3 items added",
    /// "Nothing Cove can hold on the clipboard".
    private(set) var toast: String?

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

    private init() {}

    /// Whether the island has anything to say while closed.
    var hasActivity: Bool {
        !inFlight.isEmpty || recentlyFinished != nil || toast != nil || isDropTargeted
    }

    /// The one snapshot the compact strip shows when several are in flight: the
    /// newest, because that is the one the user just handed over.
    var headline: ShelfActivitySnapshot? {
        inFlight.last ?? recentlyFinished
    }

    func update(_ snapshot: ShelfActivitySnapshot) {
        switch snapshot.phase {
        case .done, .failed:
            inFlight.removeAll { $0.id == snapshot.id }
            recentlyFinished = snapshot
            scheduleClear()
        default:
            if let index = inFlight.firstIndex(where: { $0.id == snapshot.id }) {
                inFlight[index] = snapshot
            } else {
                inFlight.append(snapshot)
            }
            clearTask?.cancel()
        }
        announce()
    }

    func post(_ message: String) {
        toast = message
        announce()
        toastTask?.cancel()
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

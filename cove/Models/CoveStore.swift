import Foundation
import SwiftData

/// Cove's one local store. The container is `Sendable`; the main actor and the
/// background `ShelfProcessor` each derive their own context from it, so model
/// objects never cross an actor boundary.
///
/// The store lives in a shared App Group container, not the app's private one,
/// so the widget extension — a separate process — reads the same shelf the app
/// writes. Both sides resolve the same file through `appGroupID`.
nonisolated enum CoveStore {
    /// The App Group both the app and the widget are entitled to. Changing this
    /// means changing it in both `.entitlements` files too, or the widget reads
    /// an empty store.
    static let appGroupID = "group.com.loop.cove"

    /// The container, or `nil` if it could not be opened.
    ///
    /// For callers that have somewhere to go when there is no store — which
    /// means the widget, and only the widget. A timeline is built in a separate
    /// process that may not be able to reach the group container at all, and a
    /// widget that traps on that is a widget that goes blank and stays blank
    /// until it is removed. Showing an empty rack is a worse answer than showing
    /// the shelf and a much better one than showing nothing ever again.
    static let available: ModelContainer? = try? ModelContainer(
        for: ShelfItem.self, ChatThread.self,
        configurations: ModelConfiguration(url: storeURL)
    )

    /// The container, for callers that cannot proceed without one.
    ///
    /// Still fatal, and still deliberately so: the app *is* the shelf, and one
    /// that launched without it would be a window that silently loses
    /// everything dropped on it. Note this resolves `available` rather than
    /// building a second container — two on one file would be two caches over
    /// the same rows.
    static var shared: ModelContainer {
        guard let available else {
            fatalError("Could not create Cove’s local SwiftData store at \(storeURL)")
        }
        return available
    }

    /// The store file inside the shared container. Falls back to the app's own
    /// Application Support only if the group is somehow unavailable — better a
    /// working app with no widget than no app at all.
    static var storeURL: URL {
        let base = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
            ?? URL.applicationSupportDirectory
        return base.appending(path: "Cove.store")
    }
}

import Foundation
import SwiftData

/// Cove's one local store. The container is `Sendable`; the main actor and the
/// background `ShelfProcessor` each derive their own context from it, so model
/// objects never cross an actor boundary.
///
/// The store lives in a shared App Group container, not the app's private one,
/// so the widget extension — a separate process — reads the same shelf the app
/// writes. Both sides resolve the same file through `appGroupID`.
enum CoveStore {
    /// The App Group both the app and the widget are entitled to. Changing this
    /// means changing it in both `.entitlements` files too, or the widget reads
    /// an empty store.
    static let appGroupID = "group.com.loop.cove"

    static let shared: ModelContainer = {
        do {
            return try ModelContainer(
                for: ShelfItem.self, ChatThread.self,
                configurations: ModelConfiguration(url: storeURL)
            )
        } catch {
            fatalError("Could not create Cove’s local SwiftData store: \(error)")
        }
    }()

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

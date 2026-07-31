import Foundation
import SwiftData

/// Cove's one local store. The container is `Sendable`; the main actor and the
/// background `ShelfProcessor` each derive their own context from it, so model
/// objects never cross an actor boundary.
enum CoveStore {
    static let shared: ModelContainer = {
        do {
            return try ModelContainer(for: ShelfItem.self, ChatThread.self)
        } catch {
            fatalError("Could not create Cove’s local SwiftData store: \(error)")
        }
    }()
}

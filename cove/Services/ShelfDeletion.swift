import SwiftData

extension ModelContext {
    /// Removes items from the shelf permanently.
    ///
    /// `ShelfItem.imageData` is `@Attribute(.externalStorage)`, so SwiftData
    /// drops the backing file along with the model — deleting a screenshot does
    /// not leave its bitmap orphaned on disk.
    ///
    /// Work already queued in `ShelfProcessor` is safe to leave alone. The actor
    /// owns a separate context and looks every item up by id before touching it
    /// (`fetchItem`), so an item deleted here is simply not found when its turn
    /// comes and the stage returns.
    func deleteShelfItems(_ items: [ShelfItem]) {
        guard !items.isEmpty else { return }
        for item in items {
            delete(item)
        }
        try? save()
    }
}

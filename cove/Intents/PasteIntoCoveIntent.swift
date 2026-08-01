import AppIntents
import Foundation

/// What a widget button asks the app to do, announced the moment the intent
/// runs.
///
/// The stamp in the shared defaults is kept as well, but it cannot be the only
/// signal: `openAppWhenRun` activates the app *before* `perform()` runs, so
/// `applicationDidBecomeActive` has already read the old stamp by the time the
/// new one is written, and every tap left a note nobody came back for. The
/// notification is what actually gets the work done; the stamp is the fallback
/// for a cold launch where the app was not yet listening.
extension Notification.Name {
    static let coveIntentPaste = Notification.Name("cove.intent.paste")
    static let coveIntentOpen = Notification.Name("cove.intent.open")
    static let coveIntentImport = Notification.Name("cove.intent.import")
}

/// The widget's "Paste" button, run when the button is tapped.
///
/// This file is a member of **both** the app and the widget targets: the widget
/// needs the type to build the `Button(intent:)`, and the app needs it to run
/// `perform()` in its own process.
///
/// The capture itself is deliberately not done here. Turning a clipboard into a
/// shelf item pulls in the whole ingest-and-processing stack — image
/// downscaling, OCR, enrichment — none of which belongs in a widget extension.
/// So the intent opens the app and leaves a note; the app reads that note the
/// moment it comes forward and does the real paste, with the full pipeline
/// behind it. `openAppWhenRun` is what makes `perform()` run in the app.
struct PasteIntoCoveIntent: AppIntent {
    static let title: LocalizedStringResource = "Paste into Cove"
    static let description = IntentDescription(
        "Saves whatever is on the clipboard to your Cove shelf."
    )
    static let openAppWhenRun = true

    /// The shared App Group both processes reach. Kept in step with
    /// `CoveStore.appGroupID` and the `.entitlements` files.
    static let appGroupID = "group.com.loop.cove"
    /// The note the intent leaves and the app picks up. A change-count stamp
    /// rather than a bare flag, so a paste requested while the app was already
    /// frontmost is not mistaken for a stale one.
    static let pendingKey = "cove.pendingClipboardPaste"

    @MainActor
    func perform() async throws -> some IntentResult {
        UserDefaults(suiteName: Self.appGroupID)?
            .set(Date.now.timeIntervalSince1970, forKey: Self.pendingKey)
        NotificationCenter.default.post(name: .coveIntentPaste, object: nil)
        return .result()
    }
}

/// Tapping the widget — its wordmark, a capture, anywhere meaningful — brings
/// Cove's window up.
///
/// An intent rather than a `widgetURL`: Cove is an accessory app with a
/// generated Info.plist, so there is no registered URL scheme for a link to
/// land on, and a tap that silently did nothing is worse than no affordance at
/// all. `openAppWhenRun` gets the app frontmost; the stamp below is what tells
/// it to show the window rather than just come forward invisibly, which is all
/// activating an accessory app would otherwise do.
///
/// Lives in this file because it is already a member of both targets.
struct OpenCoveIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Cove"
    static let description = IntentDescription("Opens the Cove window.")
    static let openAppWhenRun = true

    static let pendingKey = "cove.pendingWindowOpen"

    @MainActor
    func perform() async throws -> some IntentResult {
        UserDefaults(suiteName: PasteIntoCoveIntent.appGroupID)?
            .set(Date.now.timeIntervalSince1970, forKey: Self.pendingKey)
        NotificationCenter.default.post(name: .coveIntentOpen, object: nil)
        return .result()
    }
}

/// Tapping one pass, rather than the widget in general.
///
/// Carries the item's id so the app can open that capture rather than just the
/// shelf. The window that will show it is still being built, so for now the id
/// is handed over and parked where that window can pick it up — opening Cove is
/// the visible half, and routing to the item is a change in one place once
/// there is somewhere to route to.
struct OpenCaptureIntent: AppIntent {
    static let title: LocalizedStringResource = "Open a capture in Cove"
    static let description = IntentDescription("Opens one saved item in Cove.")
    static let openAppWhenRun = true

    /// The id last asked for, in the shared defaults, for the window to read.
    static let requestedItemKey = "cove.requestedItemID"

    @Parameter(title: "Item")
    var itemID: String

    init() {}

    init(itemID: UUID) {
        self.itemID = itemID.uuidString
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let defaults = UserDefaults(suiteName: PasteIntoCoveIntent.appGroupID)
        defaults?.set(itemID, forKey: Self.requestedItemKey)
        defaults?.set(Date.now.timeIntervalSince1970, forKey: OpenCoveIntent.pendingKey)
        NotificationCenter.default.post(name: .coveIntentOpen, object: nil)
        return .result()
    }
}

/// The widget's "add a file" button.
///
/// Same shape as the paste: the extension cannot run an open panel, and a
/// sandboxed app's read access to a file comes from the panel itself, so the
/// work has to happen in the app. This leaves the note and the app puts the
/// panel up when it comes forward.
struct AddFileToCoveIntent: AppIntent {
    static let title: LocalizedStringResource = "Add a file to Cove"
    static let description = IntentDescription("Picks a file to keep on your Cove shelf.")
    static let openAppWhenRun = true

    static let pendingKey = "cove.pendingFileImport"

    @MainActor
    func perform() async throws -> some IntentResult {
        UserDefaults(suiteName: PasteIntoCoveIntent.appGroupID)?
            .set(Date.now.timeIntervalSince1970, forKey: Self.pendingKey)
        NotificationCenter.default.post(name: .coveIntentImport, object: nil)
        return .result()
    }
}

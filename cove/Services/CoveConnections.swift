import AppKit
import EventKit
import Foundation

/// What Cove is allowed to reach outside itself, and the one place that is
/// asked.
///
/// Three apps, three separate grants, and none of them is Cove's to assume. The
/// shelf works with all three switched off; these only exist so that "remind me
/// about this" can be a thing that happens rather than a thing the assistant
/// says happened.
///
/// Kept as one observable object rather than three, because every surface that
/// cares — Settings, the banner, the assistant deciding which tools to offer —
/// cares about all three at once.
@MainActor
@Observable
final class CoveConnections {
    static let shared = CoveConnections()

    enum Access: Equatable {
        /// Never asked. The only state in which asking will show a system
        /// prompt; every other one sends the user to System Settings.
        case notAsked
        case granted
        case denied

        var isGranted: Bool { self == .granted }
    }

    private(set) var calendar: Access = .notAsked
    private(set) var reminders: Access = .notAsked
    private(set) var notes: Access = .notAsked

    /// One store for the app. `EKEventStore` is expensive to build and holds the
    /// connection to the calendar database; making one per request is how an app
    /// ends up with a fistful of them.
    private let events = EKEventStore()

    private init() {
        refresh()
    }

    /// Whether anything is still worth asking about. Drives the banner, which
    /// has nothing to say once every answer is in — granted or refused.
    var hasUnasked: Bool {
        [calendar, reminders, notes].contains(.notAsked)
    }

    var anyGranted: Bool {
        [calendar, reminders, notes].contains(.granted)
    }

    /// Re-reads all three from the system.
    ///
    /// Worth calling whenever Cove comes forward: these are revocable in System
    /// Settings, and a grant taken away while the app was in the background is
    /// otherwise believed until relaunch — which would mean offering the model a
    /// tool that can no longer work.
    func refresh() {
        calendar = Self.eventKitAccess(for: .event)
        reminders = Self.eventKitAccess(for: .reminder)
        notes = Self.automationAccess(for: Self.notesBundleID, askIfNeeded: false)
    }

    private static func eventKitAccess(for entity: EKEntityType) -> Access {
        switch EKEventStore.authorizationStatus(for: entity) {
        case .fullAccess: .granted
        // Write-only is enough for everything Cove does with a calendar, which
        // is add one event.
        case .writeOnly: entity == .event ? .granted : .denied
        case .notDetermined: .notAsked
        default: .denied
        }
    }

    // MARK: - Asking

    /// Why the last attempt to connect did not end in a grant, in words meant
    /// for the person who pressed the button. `nil` when nothing has been tried,
    /// or the last try worked.
    ///
    /// This exists because the failure used to be silent. Every path that was
    /// not a grant — the request throwing, macOS declining to show a prompt at
    /// all — landed in an empty `if` block, `refresh()` put the state back to
    /// exactly what it already was, and the button went on saying "Connect".
    /// Pressing it did nothing and said nothing, which is indistinguishable
    /// from the button not being wired up.
    private(set) var problem: String?

    func connectCalendar() async {
        problem = nil
        _ = try? await events.requestFullAccessToEvents()
        refresh()
        problem = Self.problem(asking: "Calendar", ended: calendar)
        sessionNeedsRebuilding()
    }

    func connectReminders() async {
        problem = nil
        _ = try? await events.requestFullAccessToReminders()
        refresh()
        problem = Self.problem(asking: "Reminders", ended: reminders)
        sessionNeedsRebuilding()
    }

    /// Notes has no framework, so this is an Apple event and the grant is the
    /// Automation one. `AEDeterminePermissionToAutomateTarget` is what asks for
    /// it without also sending a command — the alternative is firing a script
    /// and reading the failure, which launches Notes to find out.
    func connectNotes() async {
        problem = nil
        notes = Self.automationAccess(for: Self.notesBundleID, askIfNeeded: true)
        problem = Self.problem(asking: "Notes", ended: notes)
        sessionNeedsRebuilding()
    }

    /// What to say when asking did not end in a grant.
    ///
    /// The third case is the interesting one and the reason this is worded
    /// rather than logged. Coming back still `notAsked` means macOS did not put
    /// the prompt on screen — which it does not when the app was launched by a
    /// debugger, because the request is attributed to the debugger's process
    /// instead. Nothing is broken and nothing the user does inside Cove will
    /// fix it, so the only useful thing to say is where the switch actually
    /// lives.
    private static func problem(asking app: String, ended access: Access) -> String? {
        switch access {
        case .granted:
            nil
        case .denied:
            "\(app) access was refused. You can change that in System Settings › Privacy & Security › \(app)."
        case .notAsked:
            "macOS didn’t show the prompt for \(app). Add Cove yourself in System Settings › Privacy & Security › \(app), or quit Cove, open it from Finder, and try again."
        }
    }

    /// Somewhere to send them, for either problem above.
    static func openPrivacySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    /// The model is handed only the tools that currently work, so rebuilding the
    /// session is how a new grant reaches it. Dropping the transcript is the
    /// cost, and it is the right one: the alternative is a conversation that
    /// keeps insisting it cannot reach Calendar for the rest of its life.
    private func sessionNeedsRebuilding() {
        CoveAssistant.shared.startNewConversation()
    }

    // MARK: - Automation

    private static let notesBundleID = "com.apple.Notes"

    private static func automationAccess(for bundleID: String, askIfNeeded: Bool) -> Access {
        var target = AEAddressDesc()
        let bytes = Array(bundleID.utf8)
        guard AECreateDesc(typeApplicationBundleID, bytes, bytes.count, &target) == noErr else {
            return .denied
        }
        defer { AEDisposeDesc(&target) }

        switch AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, askIfNeeded) {
        case noErr:
            return .granted
        // -1744. Consent has not been asked for yet, which is only reported when
        // this was called without permission to ask.
        case OSStatus(errAEEventWouldRequireUserConsent):
            return .notAsked
        default:
            // -1743 and anything else: refused, or Notes is not installed.
            return .denied
        }
    }

    /// Sends one AppleScript to Notes and reports what happened.
    ///
    /// Off the main actor: `NSAppleScript` blocks until the target app answers,
    /// and Notes launching cold takes long enough to drop frames on the island.
    nonisolated static func runNotesScript(_ source: String) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            var error: NSDictionary?
            let script = NSAppleScript(source: source)
            let result = script?.executeAndReturnError(&error)

            if let error {
                let message = error[NSAppleScript.errorMessage] as? String
                throw ConnectionError.scriptFailed(message ?? "Notes refused the request.")
            }
            return result?.stringValue ?? ""
        }.value
    }

    enum ConnectionError: LocalizedError {
        case notConnected(String)
        case scriptFailed(String)
        case badDate(String)

        var errorDescription: String? {
            switch self {
            case .notConnected(let app):
                "Cove is not connected to \(app). Turn the connection on in Cove's settings first."
            case .scriptFailed(let reason):
                reason
            case .badDate(let raw):
                "“\(raw)” is not a date Cove could read."
            }
        }
    }
}

// MARK: - Doing the thing

/// The three actions Cove can take outside itself.
///
/// Each returns a sentence describing what actually happened, and throws when it
/// did not. Nothing here reports success it did not achieve — which is the whole
/// reason these exist as functions rather than as instructions to a model.
@MainActor
enum SystemActions {
    private static let store = EKEventStore()

    /// Parses what the model wrote into a date.
    ///
    /// The model is asked for ISO 8601 and mostly obliges, but "2026-08-06 18:00"
    /// and a bare "2026-08-06" both turn up. Each accepted format is one the
    /// user's intent survives; anything else throws rather than being rounded to
    /// a plausible moment, because a meeting silently filed on the wrong day is
    /// worse than one that was refused.
    static func date(from raw: String) throws -> Date {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if let parsed = try? Date(cleaned, strategy: .iso8601) { return parsed }

        let formats = [
            "yyyy-MM-dd'T'HH:mm:ssZZZZZ",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd HH:mm",
            "yyyy-MM-dd"
        ]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current

        for format in formats {
            formatter.dateFormat = format
            if let parsed = formatter.date(from: cleaned) { return parsed }
        }

        throw CoveConnections.ConnectionError.badDate(cleaned)
    }

    static func addEvent(
        title: String,
        start: Date,
        minutes: Int,
        notes: String?
    ) async throws -> String {
        guard CoveConnections.shared.calendar.isGranted else {
            throw CoveConnections.ConnectionError.notConnected("Calendar")
        }
        guard let calendar = store.defaultCalendarForNewEvents else {
            throw CoveConnections.ConnectionError.scriptFailed(
                "This Mac has no calendar to add events to."
            )
        }

        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = start.addingTimeInterval(TimeInterval(max(minutes, 5) * 60))
        event.notes = notes
        event.calendar = calendar

        try store.save(event, span: .thisEvent, commit: true)

        return "Added “\(title)” to \(calendar.title) on "
            + start.formatted(date: .abbreviated, time: .shortened) + "."
    }

    static func addReminder(title: String, due: Date?, notes: String?) async throws -> String {
        guard CoveConnections.shared.reminders.isGranted else {
            throw CoveConnections.ConnectionError.notConnected("Reminders")
        }
        guard let list = store.defaultCalendarForNewReminders() else {
            throw CoveConnections.ConnectionError.scriptFailed(
                "This Mac has no list to add reminders to."
            )
        }

        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.notes = notes
        reminder.calendar = list
        if let due {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: due
            )
        }

        try store.save(reminder, commit: true)

        guard let due else { return "Added “\(title)” to \(list.title)." }
        return "Added “\(title)” to \(list.title), due "
            + due.formatted(date: .abbreviated, time: .shortened) + "."
    }

    static func createNote(title: String, body: String) async throws -> String {
        guard CoveConnections.shared.notes.isGranted else {
            throw CoveConnections.ConnectionError.notConnected("Notes")
        }

        // Notes takes HTML for the body and the first line becomes the note's
        // title in its own list, so the title is written into the body too.
        let script = """
            tell application "Notes"
                make new note at folder "Notes" of default account ¬
                    with properties {name:"\(escaped(title))", body:"\(escaped(html(title: title, body: body)))"}
                return "ok"
            end tell
            """

        _ = try await CoveConnections.runNotesScript(script)
        return "Saved “\(title)” to Notes."
    }

    /// AppleScript string literals take double quotes and backslashes badly, and
    /// a note whose text contains either is not an edge case.
    private static func escaped(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func html(title: String, body: String) -> String {
        let paragraphs = body
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { "<div>\($0)</div>" }
            .joined()
        return "<div><b>\(title)</b></div>" + paragraphs
    }
}

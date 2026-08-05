import FoundationModels
import Foundation

/// The three things Cove can do outside its own shelf, as tools.
///
/// Each one returns a sentence saying what happened — including, and especially,
/// when nothing did. That is the point of the shape: a model told "you may add
/// calendar events" will say it added one, because saying so is the likeliest
/// continuation of the sentence. A model that has to call something and read the
/// answer has a fact to report instead.
///
/// The failures are deliberately worded as things to relay rather than as error
/// codes. "Cove is not connected to Calendar" is a sentence the assistant can
/// pass on unchanged; `EKErrorDomain error 3` is one it would paraphrase, and
/// paraphrasing a failure is how "I couldn't" becomes "I have".

struct AddCalendarEventTool: Tool {
    let name = "addCalendarEvent"
    let description = "Adds one event to the user's calendar. Only for events they ask you to add."

    @Generable
    struct Arguments {
        @Guide(description: "What the event is called.")
        var title: String
        @Guide(description: "When it starts, ISO 8601, e.g. 2026-08-06T18:00:00. Never guess a date the user did not give.")
        var start: String
        @Guide(description: "How long it lasts in minutes. Use 60 if unsaid.")
        var minutes: Int
        @Guide(description: "Anything else worth keeping with it, or an empty string.")
        var notes: String
    }

    func call(arguments: Arguments) async throws -> String {
        do {
            let start = try await MainActor.run { try SystemActions.date(from: arguments.start) }
            return try await SystemActions.addEvent(
                title: arguments.title,
                start: start,
                minutes: arguments.minutes,
                notes: arguments.notes.isEmpty ? nil : arguments.notes
            )
        } catch {
            // Handed back rather than thrown. A thrown tool error becomes a
            // generation failure and the whole turn is lost; returned, the model
            // reads why it did not work and can say so.
            return failure(error)
        }
    }
}

struct AddReminderTool: Tool {
    let name = "addReminder"
    let description = "Adds one reminder to the user's Reminders app."

    @Generable
    struct Arguments {
        @Guide(description: "What to be reminded of.")
        var title: String
        @Guide(description: "When it is due, ISO 8601, or an empty string for no date.")
        var due: String
        @Guide(description: "Anything else worth keeping with it, or an empty string.")
        var notes: String
    }

    func call(arguments: Arguments) async throws -> String {
        do {
            let due = arguments.due.isEmpty
                ? nil
                : try await MainActor.run { try SystemActions.date(from: arguments.due) }
            return try await SystemActions.addReminder(
                title: arguments.title,
                due: due,
                notes: arguments.notes.isEmpty ? nil : arguments.notes
            )
        } catch {
            return failure(error)
        }
    }
}

struct CreateNoteTool: Tool {
    let name = "createNote"
    let description = "Writes one note into the user's Notes app."

    @Generable
    struct Arguments {
        @Guide(description: "The note's title.")
        var title: String
        @Guide(description: "The note's text.")
        var body: String
    }

    func call(arguments: Arguments) async throws -> String {
        do {
            return try await SystemActions.createNote(title: arguments.title, body: arguments.body)
        } catch {
            return failure(error)
        }
    }
}

/// One wording for every failure, so a tool that could not do its job always
/// hands back a sentence beginning the same way. The model is told that a reply
/// starting like this means it must not claim the thing was done.
private func failure(_ error: Error) -> String {
    "FAILED — nothing was created. \(error.localizedDescription)"
}

import Foundation
import SwiftUI

/// The date inside a capture, if it has one.
///
/// Read with `NSDataDetector` rather than by asking the model, and that is the
/// point rather than a shortcut. The model is the part of Cove that gets dates
/// wrong: with no clock of its own it answered "tomorrow" with a day eight
/// months past, and asked for "the day before the concert" it counted back from
/// today instead of from the concert. The detector does not reason, which is
/// exactly what is wanted — it reads what the poster says and nothing else.
///
/// It is also what makes the offer possible at all. Cove can only put "Add to
/// Calendar" on a screenshot if it already knows there is a date in it, and
/// running the model over every capture on the chance one turns up would be a
/// great deal of work to answer a question `NSDataDetector` answers for free.
enum CaptureDates {
    /// The first date in anything the capture carries.
    ///
    /// First rather than earliest or nearest-future, because a poster reads top
    /// to bottom and what it is *about* comes before its small print — the
    /// concert before the early-bird deadline. Measured across posters, boarding
    /// passes, invitations and appointment confirmations, the first match was
    /// the right one every time.
    /// The title is searched last and only if nothing else has a date, because
    /// a screenshot's title *is* a date — "Screenshot 2026-08-05 at 18.02.11" —
    /// and it is the moment the file was written, never the moment the poster
    /// is about. Searched together with the content it won, every time, and the
    /// button offered to put the screenshot's own timestamp in the calendar.
    static func first(in item: ShelfItem) -> Date? {
        content(of: [item.userNote, item.extractedText, item.summary])
            ?? content(of: [item.title])
    }

    private static func content(of fields: [String?]) -> Date? {
        let text = fields.compactMap { $0 }.joined(separator: "\n")
        guard !text.isEmpty,
              let detector = try? NSDataDetector(
                  types: NSTextCheckingResult.CheckingType.date.rawValue
              )
        else { return nil }

        let range = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, range: range).compactMap(\.date).first
    }

    /// What to call the event.
    ///
    /// A screenshot's title is "Screenshot 2026-08-05 at 18.02.11", which is a
    /// filename and not a thing that happens. The first real line of what was
    /// read off it is the poster's headline — "THE NATIONAL" — which is what
    /// someone would have typed themselves.
    static func title(for item: ShelfItem) -> String {
        let candidates = [item.userNote, item.extractedText, item.summary]
        for candidate in candidates {
            guard let line = candidate?
                .components(separatedBy: .newlines)
                .map({ $0.trimmingCharacters(in: .whitespaces) })
                .first(where: { $0.count >= 3 && $0.rangeOfCharacter(from: .letters) != nil })
            else { continue }
            return String(line.prefix(60))
        }
        return item.title
    }
}

/// The offer Cove makes when it finds a date in something you saved.
///
/// Deterministic all the way through: the date comes from the detector, the
/// title from the capture's own text, and the write from `SystemActions`. No
/// model is involved, so there is nothing here that can claim to have added an
/// event it did not add — which is the failure this whole area is built around
/// avoiding.
struct CaptureScheduleSection: View {
    let item: ShelfItem

    @State private var connections = CoveConnections.shared
    @State private var outcome: Outcome?
    @State private var isWorking = false

    private struct Outcome {
        let text: String
        let isFailure: Bool
    }

    private var date: Date? { CaptureDates.first(in: item) }

    var body: some View {
        if let date {
            VStack(alignment: .leading, spacing: 10) {
                Text("Found a date")
                    .font(.headline)

                // Shown before it is used, and that is deliberate. The detector
                // is good but a poster can carry two dates, so the one Cove is
                // about to write is on screen next to the button that writes it.
                Text(date.formatted(date: .complete, time: .shortened))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(CoveTheme.accent)
                    .textSelection(.enabled)

                HStack(spacing: 10) {
                    action("Add to Calendar", systemImage: "calendar") {
                        await addEvent(at: date)
                    }
                    action("Remind Me", systemImage: "bell") {
                        await addReminder(at: date)
                    }
                }

                if let outcome {
                    Label(outcome.text, systemImage: outcome.isFailure ? "exclamationmark.triangle" : "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(outcome.isFailure ? .red : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func action(
        _ title: String,
        systemImage: String,
        perform: @escaping () async -> Void
    ) -> some View {
        Button {
            Task {
                isWorking = true
                defer { isWorking = false }
                await perform()
            }
        } label: {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.medium))
        }
        .buttonStyle(.glass)
        .disabled(isWorking)
    }

    /// Asks for the grant on first use rather than sending the user to Settings.
    ///
    /// The button is what made them want this, so it is the right moment to
    /// ask — and a permission sheet that arrives because someone just clicked
    /// "Add to Calendar" needs no explaining.
    private func addEvent(at date: Date) async {
        if connections.calendar == .notAsked { await connections.connectCalendar() }
        await run {
            try await SystemActions.addEvent(
                title: CaptureDates.title(for: item),
                start: date,
                minutes: 60,
                notes: notes
            )
        }
    }

    private func addReminder(at date: Date) async {
        if connections.reminders == .notAsked { await connections.connectReminders() }
        await run {
            try await SystemActions.addReminder(
                title: CaptureDates.title(for: item),
                due: date,
                notes: notes
            )
        }
    }

    /// Where it came from, so the event is traceable back to the capture rather
    /// than being a bare line in a calendar.
    private var notes: String {
        var lines = ["Saved in Cove on \(item.createdAt.formatted(date: .abbreviated, time: .shortened))."]
        if let link = item.linkURL?.absoluteString { lines.append(link) }
        return lines.joined(separator: "\n")
    }

    /// One place for both, so a refusal reads the same however it happened.
    /// `SystemActions` already words its successes and failures for a person.
    private func run(_ work: () async throws -> String) async {
        do {
            outcome = Outcome(text: try await work(), isFailure: false)
        } catch {
            outcome = Outcome(text: error.localizedDescription, isFailure: true)
        }
    }
}

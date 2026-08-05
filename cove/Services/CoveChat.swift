import Foundation
import SwiftData

/// Asking Cove something.
///
/// Two surfaces ask now — the island's prompt bar and the window's chat screen —
/// and they have to mean the same thing. What a question is grounded in, when a
/// new thread is started, and what a failed answer leaves behind are decided
/// here rather than answered twice and drifting apart.
///
/// `CoveAssistant` owns the model and the conversation; this owns what asking
/// does to the store. The split matters because the assistant deliberately
/// throws rather than returning an apology, and exactly one place should decide
/// what a thrown answer looks like in a transcript.
@MainActor
enum CoveChat {
    /// A completed turn: where it landed, and what came back.
    struct Exchange {
        let thread: ChatThread
        let reply: String
    }

    /// Asks the on-device model, grounded in the captures that best match the
    /// question, and stores both sides in `thread` — starting a new one when
    /// none is given.
    ///
    /// The question is still saved when the answer fails, and the failure is
    /// saved as the reply. Whatever went wrong with the model, the user typed
    /// something and the history should show it alongside what it got back.
    ///
    /// Threads are only made by asking. A "new chat" that inserted an empty
    /// thread the moment it was clicked would fill the history with
    /// conversations nobody had.
    static func ask(
        _ question: String,
        in thread: ChatThread?,
        shelf items: [ShelfItem],
        context: ModelContext
    ) async -> Exchange? {
        let cleaned = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }

        let reply = await answer(to: cleaned, shelf: items)

        return Exchange(
            thread: record(cleaned, reply: reply, in: thread, context: context),
            reply: reply
        )
    }

    /// Retrieval, then the model. Split out because it is the half with no
    /// store in it: nothing is written until there is something to write.
    ///
    /// Retrieval runs first and runs unconditionally, and that ordering is the
    /// whole reason asking still works on a Mac without Apple Intelligence. The
    /// two halves are separate stacks — MobileCLIP's encoders and the shelf's
    /// own index are local files that have nothing to do with Apple's language
    /// model — so losing the second one costs the prose, not the search.
    private static func answer(to question: String, shelf items: [ShelfItem]) async -> String {
        // The same search the library runs, which since the embeddings landed
        // means a question can reach a capture that never contained its words:
        // keyword, query-to-text vector and query-to-image vector, fused.
        let matches = (try? await AIServices.current.search.search(question, in: items)) ?? []
        let assistant = CoveAssistant.shared

        switch assistant.readiness {
        case .unavailable(let reason):
            return retrieved(matches, unavailable: reason)

        case .ready:
            // Topped up with what is recent when the search came back thin, so
            // the model is never asked about a shelf it cannot see.
            let grounding = assistant.grounding(matches: matches, recent: items)

            do {
                return try await assistant.answer(
                    to: question,
                    grounding: grounding,
                    matched: !matches.isEmpty
                )
            } catch {
                // Said in Cove's voice, and true: no answer was produced. The
                // one thing it must not do is read like one.
                return error.localizedDescription
            }
        }
    }

    /// What the shelf found, when there is no model to say it in sentences.
    ///
    /// This is a search result wearing a reply's clothes, and it says so. The
    /// temptation is to write around the missing model — to answer in Cove's
    /// voice from the matches alone — but every sentence that would do that is
    /// either a template pretending to be an answer or a claim about captures
    /// nothing actually read. Listing what matched is the most that can be said
    /// truthfully, and on the evidence it is also the useful part: the user
    /// asked where something was, and this is where it is.
    ///
    /// No top-up with recent captures here, unlike the grounded path. Recency
    /// is context for a model that will weigh it; presented directly to a user
    /// it is a list of unrelated things under the heading of their question.
    private static func retrieved(_ matches: [ShelfItem], unavailable reason: String) -> String {
        guard !matches.isEmpty else {
            return "\(reason) Cove searched your shelf anyway and found nothing matching that."
        }

        // One flowing sentence rather than a numbered list. The island shows
        // this centred and cuts it at four lines, where a list loses its last
        // item mid-row and reads as a rendering fault; a sentence just ends
        // early. The chat screen shows the whole thing either way.
        let named = matches
            .prefix(retrievalLimit)
            .map { "“\($0.title)”" }
            .joined(separator: ", ")
        let more = matches.count > retrievalLimit
            ? " …and \(matches.count - retrievalLimit) more."
            : ""
        let count = matches.count == 1 ? "1 match" : "\(matches.count) matches"

        return "\(reason) Cove searched your shelf and found \(count): \(named).\(more)"
    }

    /// How many matches the retrieval-only reply names.
    ///
    /// Smaller than the model's grounding limit on purpose: those eight are read
    /// by a model that picks one, these are read by a person.
    private static let retrievalLimit = 5

    private static func record(
        _ question: String,
        reply: String,
        in thread: ChatThread?,
        context: ModelContext
    ) -> ChatThread {
        let target: ChatThread
        if let thread {
            target = thread
        } else {
            target = ChatThread()
            context.insert(target)
        }

        context.insert(target.append(role: .user, text: question))
        context.insert(target.append(role: .assistant, text: reply))
        try? context.save()

        return target
    }
}

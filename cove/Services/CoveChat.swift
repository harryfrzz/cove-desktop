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
    /// An exchange under way: where it landed, and the turn being written into.
    struct Exchange {
        let thread: ChatThread
        /// Cove's turn. Created empty and filled in as the answer arrives, so
        /// both surfaces watch the store rather than each keeping their own copy
        /// of a reply in flight.
        let reply: ChatTurn
    }

    /// Stores the question and an empty reply, and returns both.
    ///
    /// Split from answering because the two happen at different times and the
    /// user should not wait for the second to see the first. This is
    /// synchronous, so a caller can put the question on screen in the same frame
    /// the return key was pressed.
    ///
    /// Threads are only made by asking. A "new chat" that inserted an empty
    /// thread the moment it was clicked would fill the history with
    /// conversations nobody had.
    static func begin(
        _ question: String,
        in thread: ChatThread?,
        context: ModelContext
    ) -> Exchange? {
        let cleaned = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }

        let target: ChatThread
        if let thread {
            target = thread
        } else {
            target = ChatThread()
            context.insert(target)
        }

        // Before the new turns land, and that ordering is load-bearing: the
        // session is rebuilt by replaying the thread's stored turns, so resuming
        // afterwards would hand the model this very question plus an empty reply
        // it never gave.
        let assistant = CoveAssistant.shared
        if assistant.isReady { assistant.resume(target) }

        context.insert(target.append(role: .user, text: cleaned))
        let reply = target.append(role: .assistant, text: "")
        context.insert(reply)
        try? context.save()

        return Exchange(thread: target, reply: reply)
    }

    /// Fills in the reply, writing each partial answer straight into the stored
    /// turn.
    ///
    /// Writing to the model object rather than to view state is what makes this
    /// stream in both places at once: the island and the window both read the
    /// same thread through `@Query`, so neither needs to know the other exists.
    /// The context is saved once at the end — the in-memory object is what the
    /// views observe, and saving on every snapshot would put a disk write in the
    /// middle of an animation for nothing.
    ///
    /// The question stays saved when the answer fails, and the failure is saved
    /// as the reply. Whatever went wrong, the user typed something and the
    /// history should show it alongside what it got back.
    static func answer(
        _ exchange: Exchange,
        to question: String,
        shelf items: [ShelfItem],
        context: ModelContext
    ) async {
        // The same search the library runs, which since the embeddings landed
        // means a question can reach a capture that never contained its words:
        // keyword, query-to-text vector and query-to-image vector, fused.
        let matches = (try? await AIServices.current.search.search(question, in: items)) ?? []
        let assistant = CoveAssistant.shared

        switch assistant.readiness {
        case .unavailable(let reason):
            exchange.reply.text = retrieved(matches, unavailable: reason)
            // The captures are offered here too. Without a model to name them
            // there is all the more reason to make them clickable, and these are
            // search results rather than anything Cove claimed about them.
            exchange.reply.linkedItemIDs = matches.prefix(retrievalLimit).map(\.id)

        case .ready:
            // Falls back to what is recent when a *question* finds nothing, so
            // the model is never asked about a shelf it cannot see — and to
            // nothing at all when the message was never a question.
            let grounding = assistant.grounding(for: question, matches: matches, recent: items)

            do {
                let reply = try await assistant.answer(
                    to: question,
                    grounding: grounding,
                    matched: !matches.isEmpty
                ) { partial in
                    exchange.reply.text = partial
                }
                exchange.reply.text = reply.text
                exchange.reply.linkedItemIDs = reply.offered
            } catch {
                // Said in Cove's voice, and true: no answer was produced. The
                // one thing it must not do is read like one — and it offers
                // nothing, because nothing was found.
                exchange.reply.text = error.localizedDescription
                exchange.reply.linkedItemIDs = []
            }
        }

        exchange.thread.updatedAt = .now
        try? context.save()
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
}

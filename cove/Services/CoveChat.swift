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
        /// The captures Cove is holding out for the user to pick from, by shelf
        /// id. Empty for most turns; a lookup is where they come from.
        let links: [UUID]
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
            reply: reply.text,
            links: reply.offered
        )
    }

    /// Retrieval, then the model. Split out because it is the half with no
    /// store in it: nothing is written until there is something to write.
    private static func answer(
        to question: String,
        shelf items: [ShelfItem]
    ) async -> CoveAssistant.Reply {
        // Retrieval first, so the model reads the shelf rather than improvising
        // about it. This is the same search the library runs, which since the
        // embeddings landed means a question can reach a capture that never
        // contained its words.
        let matches = (try? await AIServices.current.search.search(question, in: items)) ?? []
        let assistant = CoveAssistant.shared
        // Topped up with what is recent when the search came back thin, so the
        // model is never asked about a shelf it cannot see.
        let grounding = assistant.grounding(matches: matches, recent: items)

        do {
            return try await assistant.answer(
                to: question,
                grounding: grounding,
                matched: !matches.isEmpty
            )
        } catch {
            // Said in Cove's voice, and true: no answer was produced. The one
            // thing it must not do is read like one — and it offers nothing,
            // because nothing was found.
            return CoveAssistant.Reply(text: error.localizedDescription, offered: [])
        }
    }

    private static func record(
        _ question: String,
        reply: CoveAssistant.Reply,
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
        context.insert(target.append(role: .assistant, text: reply.text, links: reply.offered))
        try? context.save()

        return target
    }
}

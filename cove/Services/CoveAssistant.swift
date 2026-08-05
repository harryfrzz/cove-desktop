import AppKit
import FoundationModels
import Foundation

/// The model behind "Ask Cove", and the honest answer about whether there is
/// one.
///
/// The prompt bar used to accept a question, shimmer for 900ms, and reply that
/// the model "isn't wired up yet". That is worse than having no prompt bar: it
/// spends the user's attention, stores a turn in their chat history, and
/// performs thinking that never happened. A control that cannot do its job
/// should not be on screen — so `readiness` is what the panel asks before it
/// draws the bar at all, and this type never fabricates a reply.
///
/// The model is Apple's on-device one. That keeps the promise the rest of Cove
/// makes: the shelf is local, the encoders are local, and a question about a
/// capture does not become a network request. It also means it is genuinely
/// absent on some Macs, which is why `readiness` is a real state and not a
/// formality.
@MainActor
@Observable
final class CoveAssistant {
    static let shared = CoveAssistant()

    /// Whether there is a model, and if not, what to say about it.
    enum Readiness: Equatable {
        case ready
        /// Written for the user rather than the log: each of these is something
        /// they can act on, or at least understand, from the panel.
        case unavailable(String)
    }

    /// Observable, so the panel follows the model appearing without being told.
    /// `SystemLanguageModel` is itself `Observable` and its availability moves —
    /// most obviously from `.modelNotReady` to `.available` while Apple
    /// Intelligence finishes downloading — and a bar that stayed hidden until
    /// the next launch would look like it had simply never worked.
    private let model = SystemLanguageModel.default

    /// Kept between questions, which is what makes this a conversation.
    ///
    /// A fresh session per question was the first shape of this, and it meant
    /// "and the second one?" arrived with no idea what the first one was. The
    /// transcript lives in the session, so holding it is the whole feature.
    private var session: LanguageModelSession?

    /// Which stored conversation the live session is carrying, so a switch can
    /// be noticed. `nil` means an unsaved conversation — one that has been
    /// started but not yet spoken into, which has no thread behind it yet.
    ///
    /// Without this there was one session for the life of the app and many
    /// threads in the store, and the two had nothing to do with each other:
    /// "New Chat" cleared the screen while the model went on remembering the
    /// last conversation, and opening an old thread to ask a follow-up put the
    /// question to a model holding somebody else's transcript. The history
    /// looked like several conversations and behaved like one.
    private var sessionThreadID: UUID?

    /// What "open it" is currently allowed to mean. Refreshed before every
    /// turn; see `ShelfOpenTargets`.
    private let openTargets = ShelfOpenTargets()

    var readiness: Readiness {
        switch model.availability {
        case .available:
            .ready
        case .unavailable(.deviceNotEligible):
            .unavailable("This Mac doesn’t support Apple Intelligence.")
        case .unavailable(.appleIntelligenceNotEnabled):
            .unavailable("Apple Intelligence is turned off in System Settings.")
        case .unavailable(.modelNotReady):
            .unavailable("Apple Intelligence is still downloading its model.")
        @unknown default:
            .unavailable("Apple Intelligence isn’t available right now.")
        }
    }

    var isReady: Bool { readiness == .ready }

    /// How many captures are put in front of the model.
    ///
    /// Small on purpose. The context window is finite and shared with the
    /// answer, and a question about a shelf is almost always about something
    /// near the top of what the search returned — twenty loosely-related
    /// captures crowd out the two that matter.
    private static let groundingLimit = 8

    /// The longest any single capture's text may contribute. One screenshot of
    /// a full page of OCR can otherwise be the entire prompt.
    private static let excerptLimit = 400

    /// Replies to whatever was typed — a question about the shelf, or just
    /// hello.
    ///
    /// `grounding` is expected to be search results, best first, and may be
    /// empty. Empty is not an error and not a refusal: most of what gets typed
    /// here is not a lookup at all.
    ///
    /// Throws rather than returning an apology string. The caller has to
    /// distinguish "no answer" from "no model", and a function that always
    /// returns something readable is how the fake reply happened in the first
    /// place.
    func answer(
        to question: String,
        grounding items: [ShelfItem],
        matched: Bool
    ) async throws -> String {
        guard isReady else { throw AssistantError.noModel }

        let prompt = Self.prompt(question: question, items: items, matched: matched)
        // What `openCapture` may reach, for this turn only. Set before the
        // model runs, because the tool can be called during the response.
        openTargets.replace(with: Array(items.prefix(Self.groundingLimit)))

        do {
            return try await respond(to: prompt)
        } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
            // The conversation has outgrown the window. Start a fresh one and
            // answer this turn rather than handing back an error the user can
            // do nothing about — losing the transcript is a smaller loss than
            // an assistant that stops working until relaunch.
            startNewConversation()
            return try await respond(to: prompt)
        } catch LanguageModelSession.GenerationError.guardrailViolation {
            // Apple's safety filter, and it fires on innocuous things — asking
            // for the URL of a saved video tripped it in testing while asking
            // to open the same video did not. The user has done nothing wrong
            // and there is nothing to fix, so this says so briefly instead of
            // showing them a Swift error description.
            throw AssistantError.declined
        } catch let error as LanguageModelSession.GenerationError {
            throw Self.described(error)
        }
    }

    /// Turns the framework's remaining generation failures into something worth
    /// showing someone.
    ///
    /// Everything not caught above used to fall through to whatever
    /// `localizedDescription` produced, which for these is the Foundation
    /// default: "The operation couldn't be completed. (…GenerationError error
    /// -1.)". That is bad enough on screen, and this is stored — a chat history
    /// keeps it forever, in the same bubble a real answer would occupy.
    ///
    /// Each of these is either a wait-and-retry or a fact about the Mac, and is
    /// said as such.
    private static func described(_ error: LanguageModelSession.GenerationError) -> AssistantError {
        switch error {
        case .assetsUnavailable:
            .unavailable("Apple Intelligence hasn’t finished installing its model.")
        case .rateLimited:
            .unavailable("Cove has asked the model too many times just now — try again in a moment.")
        case .concurrentRequests:
            .unavailable("Cove is still answering the last question.")
        case .unsupportedLanguageOrLocale:
            .unavailable("Apple Intelligence doesn’t support this Mac’s language yet.")
        case .refusal:
            .declined
        // `decodingFailure`, `unsupportedGuide` and anything added later. These
        // are faults in how Cove asked rather than anything the user did, so
        // this says the true and useful part without inventing a cause.
        default:
            .unavailable("The model couldn’t answer that one — try asking it again.")
        }
    }

    private func respond(to prompt: String) async throws -> String {
        let response = try await resolvedSession().respond(
            to: prompt,
            options: GenerationOptions(
                // Low, but not at the floor. This carries both halves now: a
                // lookup, where the failure worth avoiding is an invented
                // detail that reads as though it came off the shelf, and a
                // greeting, where a model pinned at zero answers like a form.
                temperature: 0.5,
                // The answer sits in a 34pt-tall panel under the wordmark, and
                // shows four lines. Anything longer is truncated on screen, so
                // asking for it only spends time.
                maximumResponseTokens: 200
            )
        )

        let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AssistantError.emptyAnswer }
        return text
    }

    // MARK: - What the model is told

    /// Two jobs, in this order: be someone to talk to, and be accurate about
    /// the shelf.
    ///
    /// The first version of this said only the second, and the result was an
    /// assistant that could not say hello — "hii" came back as "There is
    /// nothing on the shelf matching this question", because a shelf lookup was
    /// the only thing it had been told it was for. Most of what anyone types
    /// into a small bar under a wordmark is not a database query, and refusing
    /// all of it is not caution, it is just being broken.
    ///
    /// The restraint that actually matters is narrower than "only answer from
    /// the shelf": never invent a *specific* — a price, a date, an order
    /// number, a name — and attribute it to something the user saved. Ordinary
    /// conversation costs nothing and is what makes the bar worth having.
    private static let instructions = """
        You are Cove, a friendly assistant living in a small panel on the \
        user's Mac. Cove is a shelf where they keep screenshots, images, \
        links, notes and files.

        Talk to them normally. Greetings, small talk, and general questions \
        all deserve a real, warm reply — never repeat their message back to \
        them.

        When they ask about something they saved, answer from the captures you \
        are shown. A capture's title may be in any language; read it as it is. \
        If they ask for a link, give them the address exactly as it appears. If \
        they ask to open, fetch, play or go to one, call openCapture with its \
        number.

        Ambiguity is never resolved by guessing. If two or more captures could \
        be the one they mean — two links, two screenshots, anything — do not \
        open one and do not hand over one address. Name them in a few words \
        each on a single line and ask which they want. If the captures do not contain what was asked, say plainly that \
        you could not find it on their shelf. Never invent a specific detail — \
        a price, a date, an order number, a name — and never present a guess as \
        something they saved.

        Keep replies to one or two short sentences. No preamble, no bullet \
        points.
        """

    /// What the model is allowed to read: the search's answer, topped up with
    /// whatever is most recent.
    ///
    /// Search alone was not enough, and a saved Korean YouTube video is why.
    /// Its title is Korean, so an English question touches nothing but the
    /// host; on a Mac without the encoders there is no semantic bridge either.
    /// The search returned nothing, the model was handed nothing, and it
    /// truthfully reported that there was no such link — about a shelf that
    /// had one.
    ///
    /// So a thin result is filled out with recent captures. On a small shelf
    /// that means the model simply sees the shelf, which is the right answer
    /// for a question like "what was that video?" — and it can read the Korean
    /// title perfectly well once it is actually looking at it.
    ///
    /// `matches` keeps its order and its priority; the top-up only ever fills
    /// the space underneath.
    func grounding(matches: [ShelfItem], recent: [ShelfItem]) -> [ShelfItem] {
        var chosen = Array(matches.prefix(Self.groundingLimit))
        guard chosen.count < Self.groundingLimit else { return chosen }

        var seen = Set(chosen.map(\.id))
        for item in recent where !seen.contains(item.id) {
            chosen.append(item)
            seen.insert(item.id)
            if chosen.count == Self.groundingLimit { break }
        }
        return chosen
    }

    /// The question, with the shelf attached.
    ///
    /// The heading is not decoration. When the search found these, they are
    /// what was asked for; when they are only what is recent, saying so is what
    /// stops "hii" being answered with a summary of the user's files. The model
    /// is told which it is holding and behaves accordingly.
    private static func prompt(question: String, items: [ShelfItem], matched: Bool) -> String {
        guard !items.isEmpty else { return question }

        let captures = items.prefix(groundingLimit).enumerated().map { index, item in
            described(item, number: index + 1)
        }
        let heading = matched
            ? "The captures from the user's shelf that best match what they are asking, most relevant first:"
            : "For reference, the user's most recent saved items. Do not mention them unless they are relevant:"

        // The closing line earns its place. With the captures simply followed
        // by `Message: hii`, the model answered "hii" — it mirrored the last
        // thing on the page instead of replying to it. Naming the speaker and
        // asking for a reply is what turns a block of context back into a
        // conversation, and it is the difference between a greeting being
        // greeted and being echoed.
        return """
            \(heading)

            \(captures.joined(separator: "\n\n"))

            The user says: "\(question)"

            Reply to them.
            """
    }

    /// Points the model at `thread`, rebuilding the session from what was
    /// stored when it is currently carrying a different conversation.
    ///
    /// Called before every question rather than when the user switches threads.
    /// Switching is a thing they may do to read, and rebuilding a session for a
    /// conversation nobody goes on to continue is work spent on nothing; asking
    /// is the moment the model's memory has to be right.
    ///
    /// Rebuilding replays the stored turns, so returning to an old thread and
    /// asking a follow-up works the way the screen implies it does. The replay
    /// is not perfectly faithful and cannot be: a turn Cove answered while
    /// Apple Intelligence was off is stored as an assistant reply and comes
    /// back as one, so the model is handed a sentence it never said. That is
    /// the honest record of what the user was shown, which is the thing worth
    /// preserving here.
    func resume(_ thread: ChatThread?) {
        guard session == nil || thread?.id != sessionThreadID else { return }
        session = makeSession(replaying: thread)
        sessionThreadID = thread?.id
    }

    /// The running session, started on first use.
    private func resolvedSession() -> LanguageModelSession {
        if let session { return session }
        let created = makeSession(replaying: nil)
        session = created
        return created
    }

    private func makeSession(replaying thread: ChatThread?) -> LanguageModelSession {
        let tool = OpenCaptureTool(targets: openTargets)

        guard let thread, !thread.turns.isEmpty else {
            return LanguageModelSession(tools: [tool], instructions: Self.instructions)
        }

        // Instructions have to be an entry rather than the initialiser's
        // argument on this path: the transcript initialiser takes the whole
        // conversation, and one that opened with a prompt would be a model
        // that had never been told what it is.
        var entries: [Transcript.Entry] = [
            .instructions(
                Transcript.Instructions(
                    segments: [.text(Transcript.TextSegment(content: Self.instructions))],
                    toolDefinitions: [Transcript.ToolDefinition(tool: tool)]
                )
            )
        ]

        // Only the tail. The window is finite, and an old thread long enough to
        // fill it would arrive already overflowing — the recovery below would
        // then fire on the first question and throw away the very transcript
        // this was rebuilt to restore.
        for turn in thread.orderedTurns.suffix(Self.replayLimit) {
            let segment = Transcript.Segment.text(Transcript.TextSegment(content: turn.text))
            switch turn.role {
            case .user:
                entries.append(.prompt(Transcript.Prompt(segments: [segment])))
            case .assistant:
                entries.append(.response(Transcript.Response(assetIDs: [], segments: [segment])))
            }
        }

        return LanguageModelSession(tools: [tool], transcript: Transcript(entries: entries))
    }

    /// How many stored turns a rebuilt session replays.
    ///
    /// Turns, not exchanges, so this is roughly the last eight questions and
    /// their answers.
    private static let replayLimit = 16

    /// Forgets the conversation. The shelf is unaffected; only the transcript
    /// the model is carrying goes.
    ///
    /// Deliberately empties the session rather than dropping it: this is the
    /// cure for a full context window, and a `nil` that the next question
    /// rebuilt from the same thread would replay its way straight back into the
    /// overflow it was called to escape. `sessionThreadID` is left alone for
    /// the same reason — the session still belongs to this conversation, it has
    /// simply forgotten it.
    func startNewConversation() {
        session = makeSession(replaying: nil)
    }

    /// One capture, flattened to the few facts worth spending tokens on.
    private static func described(_ item: ShelfItem, number: Int) -> String {
        var lines = [
            "\(number). \(item.kind.label) — \(item.title)",
            "   saved \(item.createdAt.formatted(date: .abbreviated, time: .shortened))"
        ]
        if let app = item.sourceApp, !app.isEmpty {
            lines.append("   from \(app)")
        }
        if let host = item.linkHost, !host.isEmpty {
            lines.append("   link: \(host)")
        }
        // The address itself, and not only the host. Without it the assistant
        // could say "yes, you have a YouTube link saved" and then had nothing to
        // hand over when asked to fetch it — it was answering about something it
        // had only been told the domain of. A file's path lands here too, which
        // is what lets one be opened by name.
        if let address = item.linkURL?.absoluteString, !address.isEmpty {
            lines.append("   address: \(address)")
        }
        if let note = excerpt(item.userNote) {
            lines.append("   note: \(note)")
        }
        if let summary = excerpt(item.summary) {
            lines.append("   summary: \(summary)")
        }
        if let text = excerpt(item.extractedText) {
            lines.append("   text in the image: \(text)")
        }
        if !item.tags.isEmpty {
            lines.append("   tags: \(item.tags.joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }

    private static func excerpt(_ value: String?) -> String? {
        guard let cleaned = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cleaned.isEmpty else {
            return nil
        }
        let flattened = cleaned.replacingOccurrences(of: "\n", with: " ")
        guard flattened.count > excerptLimit else { return flattened }
        return String(flattened.prefix(excerptLimit)) + "…"
    }

    enum AssistantError: LocalizedError {
        case noModel
        case emptyAnswer
        case declined
        /// A generation failure already phrased for the user. See `described`.
        case unavailable(String)

        var errorDescription: String? {
            switch self {
            case .noModel: "Cove’s on-device model isn’t available on this Mac."
            case .emptyAnswer: "The model didn’t return an answer."
            case .declined: "The model wouldn’t answer that one — try asking it a different way."
            case .unavailable(let reason): reason
            }
        }
    }
}

// MARK: - Opening what was found

/// The captures the assistant is currently allowed to open, by their number in
/// the prompt.
///
/// A separate box rather than state on the tool, because the session — and so
/// the tool inside it — is built once and kept, while the captures change with
/// every question. Updating this before each turn is what keeps "open it"
/// pointing at what "it" currently means.
@MainActor
final class ShelfOpenTargets {
    struct Target: Sendable {
        let number: Int
        let title: String
        let url: URL?
    }

    private var targets: [Target] = []

    func replace(with items: [ShelfItem]) {
        targets = items.enumerated().map { index, item in
            Target(number: index + 1, title: item.title, url: item.linkURL)
        }
    }

    func target(numbered number: Int) -> Target? {
        targets.first { $0.number == number }
    }
}

/// Lets the assistant actually open something, rather than only describe it.
///
/// The safety property is the whole design: the tool takes a *number* into the
/// list the model was shown, never a URL. The model cannot open an address it
/// invented or one that came from the text of a capture — only something
/// already on the user's shelf, resolved here from the shelf's own record.
struct OpenCaptureTool: Tool {
    let targets: ShelfOpenTargets

    let name = "openCapture"
    let description = """
        Opens one of the numbered captures from the user's shelf, in whichever \
        app handles it. Use this when the user asks to open, fetch, play, watch \
        or go to something they saved.
        """

    @Generable
    struct Arguments {
        @Guide(description: "The number of the capture to open, exactly as listed in the prompt.")
        var number: Int
    }

    func call(arguments: Arguments) async throws -> String {
        guard let target = await targets.target(numbered: arguments.number) else {
            return "There is no capture numbered \(arguments.number)."
        }
        guard let url = target.url else {
            return "“\(target.title)” is not a link or a file, so there is nothing to open outside Cove."
        }
        // `open` reports whether a handler took it. Worth telling the model:
        // "Opened" for a link whose app never came forward is the same shape of
        // lie as the reply this whole type was written to remove.
        let opened = await MainActor.run { NSWorkspace.shared.open(url) }
        guard opened else {
            return "Nothing on this Mac would open “\(target.title)”."
        }
        return "Opened “\(target.title)”."
    }
}

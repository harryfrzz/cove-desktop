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

    /// What the model is currently allowed to put in front of the user, and
    /// what it has asked for this turn. Refreshed before every one; see
    /// `ShelfCaptureOffers`.
    private let offers = ShelfCaptureOffers()

    /// What came back from a question: what Cove said, and the captures it is
    /// holding out for the user to choose from.
    ///
    /// Two fields rather than one string because a saved link is not prose. An
    /// address typed into a reply is unreadable at this size, unclickable, and
    /// — once the panel truncates it — not even copyable. The captures travel
    /// as ids so that whatever draws them resolves the title and the address
    /// from the shelf's own record rather than from anything the model wrote.
    struct Reply {
        let text: String
        let offered: [UUID]
    }

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
    /// Small on purpose, and smaller than it was. The context window is 4096
    /// tokens, shared between these captures, the instructions, the running
    /// transcript and the answer — and eight captures described in full came to
    /// around 2000 of them before the conversation had started.
    ///
    /// What that cost was not obvious, which is why it stayed wrong for a
    /// while. A model under context pressure does not fail loudly; it stops
    /// calling its tools and starts *typing what the call would have been* —
    /// the panel showed the user the literal text "showCaptures(numbers: [2,
    /// 3])" instead of two links. Five captures leaves it room to work.
    private static let groundingLimit = 5

    /// The longest any single capture's text may contribute.
    ///
    /// Also much shorter than it was, for the same reason: a page of OCR at 400
    /// characters, three fields deep, eight captures wide, *is* the context
    /// window. This is enough to tell two similar captures apart, which is all
    /// it was ever needed for.
    private static let excerptLimit = 120

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
    /// `onPartial` receives the prose so far, as often as the model produces a
    /// snapshot. Each call carries the whole answer to that point rather than
    /// the piece just added, so a caller assigns it and never appends — which is
    /// also what makes the retry below harmless, since a second attempt simply
    /// overwrites what the first had shown.
    ///
    /// Only the prose streams. The captures are settled once at the end, because
    /// what is offered is decided by reading the finished text — a call the model
    /// typed rather than made is only recognisable whole, and rows appearing and
    /// vanishing as a half-written call is parsed would be worse than rows that
    /// arrive a moment late.
    func answer(
        to question: String,
        grounding items: [ShelfItem],
        matched: Bool,
        onPartial: @escaping @MainActor (String) -> Void = { _ in }
    ) async throws -> Reply {
        guard isReady else { throw AssistantError.noModel }

        let shown = Array(items.prefix(Self.groundingLimit))
        let prompt = Self.prompt(question: question, items: items, matched: matched)
        // What `showCaptures` may reach, for this turn only. Set before the
        // model runs, because the tool can be called during the response.
        offers.replace(with: shown)

        do {
            return try reply(from: await respond(to: prompt, onPartial: onPartial), shown: shown)
        } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
            // The conversation has outgrown the window. Start a fresh one and
            // answer this turn rather than handing back an error the user can
            // do nothing about — losing the transcript is a smaller loss than
            // an assistant that stops working until relaunch.
            startNewConversation()
            return try reply(from: await respond(to: prompt, onPartial: onPartial), shown: shown)
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

    /// Streams rather than waits.
    ///
    /// The whole answer arrives in a handful of snapshots — four for a couple of
    /// sentences, in testing — so this is not a typewriter. It is the difference
    /// between a panel that sits still for several seconds and one that is
    /// visibly filling in, which is what a wait needs to be legible.
    private func respond(
        to prompt: String,
        onPartial: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        var latest = ""
        for try await snapshot in resolvedSession().streamResponse(
            to: prompt,
            options: GenerationOptions(
                // Low, but not at the floor. This carries both halves now: a
                // lookup, where the failure worth avoiding is an invented
                // detail that reads as though it came off the shelf, and a
                // greeting, where a model pinned at zero answers like a form.
                temperature: 0.5,
                // Enough for an answer that names a few captures. It was set for
                // four lines under a wordmark, and the same answer is now read in
                // a window with room for it.
                maximumResponseTokens: 400
            )
        ) {
            latest = snapshot.content
            // Shown without the parts that are not prose, so a half-written
            // `showCaptures(...)` never appears on screen on its way past.
            let shown = Self.stripped(latest)
            // Nothing yet is not worth showing: an empty bubble replacing the
            // working indicator would read as an answer that came back blank.
            if !shown.isEmpty { onPartial(shown) }
        }

        let text = latest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AssistantError.emptyAnswer }
        return text
    }

    /// A partial answer with any typed call — whole or half-written — taken out
    /// of it, for display while the rest is still arriving. `reply(from:shown:)`
    /// does the real version of this on the finished text.
    private static func stripped(_ text: String) -> String {
        guard let start = text.range(of: "showCaptures") else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(text[text.startIndex..<start.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Prose and links, told apart

    /// Splits what came back into the sentence the user reads and the captures
    /// they can click.
    ///
    /// The captures the model asked for are the first source and the reliable
    /// one. The second is a recovery: the model is told not to type addresses,
    /// and usually doesn't, but when it does the address is matched back to the
    /// capture it belongs to and lifted out of the prose into a row like any
    /// other. That is not politeness about formatting — a URL printed into a
    /// 460pt panel that shows four lines is truncated to "https://www.youtube…"
    /// and there is nothing the user can do with it.
    ///
    /// An address that matches nothing on the shelf is left exactly where the
    /// model put it, unlinked. Cove will not make something clickable on the
    /// strength of the model having typed it.
    private func reply(from text: String, shown: [ShelfItem]) throws -> Reply {
        var prose = text

        // A call the model typed instead of made. See `typedCalls`. Routed
        // through the same box a real call goes through rather than writing the
        // ids straight in — otherwise every rule `offer` enforces, including
        // refusing to hold out the entire shelf at a greeting, is one typed
        // parenthesis away from being bypassed.
        for (written, numbers) in Self.typedCalls(in: text) {
            _ = offers.offer(numbered: numbers)
            prose = prose.replacingOccurrences(of: written, with: "")
        }

        var offered = offers.offered

        for (address, item) in Self.savedAddresses(in: text, among: shown) {
            if !offered.contains(item.id) { offered.append(item.id) }
            prose = prose.replacingOccurrences(of: address, with: "")
        }

        var sentence = Self.tidied(prose, from: text)
        // A reply that was *only* a typed call has nothing left in it once the
        // call has been lifted out. The rows carry the answer at that point, so
        // they get a plain label rather than a blank panel above them. It
        // claims nothing the model said — these came off the shelf.
        if sentence.isEmpty, !offered.isEmpty {
            sentence = offered.count == 1
                ? "Here's what I found on your shelf."
                : "Here's what I found on your shelf — take your pick."
        }
        // Nothing said and nothing to show: a typed call whose numbers were all
        // outside the list. Better to report no answer than to draw an empty
        // panel that looks like one.
        guard !sentence.isEmpty || !offered.isEmpty else { throw AssistantError.emptyAnswer }

        return Reply(text: sentence, offered: offered)
    }

    /// Tool calls the model wrote out as prose, and the capture numbers in them.
    ///
    /// This exists because of what a small model does when it runs out of room
    /// rather than because of anything it does wrong. Under context pressure it
    /// stops emitting a *structured* call the framework can intercept and
    /// starts emitting the text of one, and the panel dutifully showed the user
    /// `showCaptures(numbers: [2, 3])` where two links should have been. The
    /// prompt was cut down so it has the room — that is the actual fix, and it
    /// is upstream of here — but the failure is silent and gradual, and one
    /// long conversation can walk back into it.
    ///
    /// So a typed call is honoured as though it had been made. That is safe for
    /// the same reason the tool is: these are indices into the list the model
    /// was shown, resolved against `shown` by position, and a number outside it
    /// is dropped. Nothing here can name a capture that was not already on the
    /// user's shelf and already in front of the model.
    private static func typedCalls(in text: String) -> [(String, [Int])] {
        // Deliberately case-insensitive on the name: the model has been seen
        // writing both `showCaptures` and `ShowCaptures`.
        // Permissive inside the brackets, because the model is improvising the
        // syntax rather than following one: `[2, 3]`, `['1','2','3']` and `[]`
        // have all come back. Anything that is not a digit is ignored.
        guard let regex = try? NSRegularExpression(
            pattern: #"\bshowCaptures\s*\(\s*(?:numbers\s*:)?\s*\[([^\]]*)\]\s*\)"#,
            options: .caseInsensitive
        ) else { return [] }

        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let whole = Range(match.range, in: text),
                  let list = Range(match.range(at: 1), in: text)
            else { return nil }

            let numbers = text[list]
                .split(whereSeparator: { !$0.isNumber })
                .compactMap { Int($0) }
            // Returned even when there are no usable numbers in it. This is the
            // difference between the user seeing a greeting and seeing the text
            // "showCaptures([])" — an empty call is still a call, and still has
            // to come out of the sentence.
            return (String(text[whole]), numbers)
        }
    }

    /// Every address in `text` that belongs to one of the captures the model
    /// was shown, paired with the capture it belongs to.
    private static func savedAddresses(
        in text: String,
        among items: [ShelfItem]
    ) -> [(String, ShelfItem)] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return []
        }

        let range = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, range: range).compactMap { match in
            guard let written = match.url,
                  let span = Range(match.range, in: text),
                  let item = items.first(where: { saved in
                      guard let url = saved.linkURL else { return false }
                      return matches(written, url)
                  })
            else { return nil }
            return (String(text[span]), item)
        }
    }

    /// Whether two addresses are the same saved thing.
    ///
    /// Loose on purpose, in both directions. What the model types is often a
    /// shortened version of what was saved — the host without the scheme, the
    /// path without the query — and a shortened address is still an address the
    /// user should be able to click rather than read.
    private static func matches(_ written: URL, _ saved: URL) -> Bool {
        guard let a = key(for: written), let b = key(for: saved) else { return false }
        return a.hasPrefix(b) || b.hasPrefix(a)
    }

    private static func key(for url: URL) -> String? {
        guard let host = url.host()?.lowercased() else {
            // A file, which has no host. Its path is the whole of its identity.
            return url.isFileURL ? url.path() : nil
        }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let query = url.query().map { "?\($0)" } ?? ""
        return bare + url.path() + query
    }

    /// Closes the gaps that lifting a link out of the prose left behind.
    ///
    /// A line that was only ever an address — "1. https://youtube.com/…" — is
    /// left holding nothing but its own bullet, so it goes with the address it
    /// was carrying.
    ///
    /// `original` is what decides that, and it is not fussiness. Dropping every
    /// wordless line unconditionally also drops a wordless *answer*: asked what
    /// an order number was, the model replied "4471" and the panel went blank.
    /// So a line is only ever discarded when it lost something here and what
    /// remains has no words in it. A line nothing was taken from is kept
    /// whatever it says.
    private static func tidied(_ text: String, from original: String) -> String {
        let before = original.components(separatedBy: .newlines).map(collapsed)
        let after = text.components(separatedBy: .newlines).map(collapsed)

        return after
            .enumerated()
            .compactMap { index, line -> String? in
                guard !line.isEmpty else { return nil }
                let untouched = index < before.count && before[index] == line
                guard untouched || line.rangeOfCharacter(from: .letters) != nil else { return nil }
                return line
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func collapsed(_ line: String) -> String {
        line
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
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
    ///
    /// The other restraint is newer, and it is about who does the opening. This
    /// used to end a lookup by launching a browser — you asked whether you had
    /// a video saved and a tab appeared. Even when it picked correctly that is
    /// the wrong shape: a question was answered with an action, on a shelf
    /// where two captures often fit the same question equally well, and the
    /// only way to see the other one was to ask again. So the model hands over
    /// candidates and the user does the clicking.
    /// Short, and that is a requirement rather than a style. Instructions sit
    /// in the context of every turn for the life of the session, so a paragraph
    /// spent explaining a rule twice is a paragraph the conversation cannot
    /// use — and a model out of room stops calling its tools before it stops
    /// producing sentences.
    private static let instructions = """
        You are Cove, a warm and brief assistant on the user's Mac. Cove is a \
        shelf where they keep screenshots, images, links, notes and files.

        Greetings and small talk get a real reply, never an echo.

        For anything they saved, answer only from the captures listed. A title \
        may be in any language; read it as it is. Never type out a web address \
        or a file path — call showCaptures with the number of every capture \
        that could be the one they mean, and say in words what you showed. \
        Never open anything yourself. If two could fit, show both and let them \
        pick.

        If the captures do not hold the answer, say so plainly. Never invent a \
        price, date, order number or name.

        You cannot touch Calendar, Reminders or Notes yourself. The only way \
        anything is added to them is a tool call that comes back saying it \
        worked. Never say you have added, created, saved or scheduled \
        something unless a tool told you so in this turn. If a tool replies \
        FAILED, tell them plainly it did not happen and why. If you have no \
        tool for what they asked, say Cove is not connected to that app. \
        Never invent a date they did not give you — ask.

        One or two short sentences. No preamble, no bullet points.
        """

    /// What the model is allowed to read: the search's answer, and nothing else.
    ///
    /// This used to top a thin result up with whatever was recent, and the
    /// reason was a saved Korean YouTube video — Korean title, English
    /// question, so the search touched nothing and the model truthfully
    /// reported there was no such link about a shelf that had one. Filling the
    /// space with recent captures fixed that case.
    ///
    /// It also meant every message arrived with a list of the user's shelf
    /// attached, including the ones that were not questions. Typing "hi" got
    /// back four links and a summary of their captures, because a greeting plus
    /// a visible list is all it takes for a model this size to start reading the
    /// list out. Blocking the links alone was not enough — the prose listed them
    /// too. Nothing to see is the only reliable way to have nothing said.
    ///
    /// The original bug is covered elsewhere now: the address is part of
    /// `searchableText`, so the Korean video matches on "youtube" through its
    /// own URL, and above a dozen captures the vector half reaches it without
    /// sharing a word at all. A lookup that still finds nothing is answered with
    /// "I couldn't find that", which is honest, and the user's next message is
    /// usually specific enough to match.
    ///
    /// So the fallback is kept, and what changed is *when* it fires. A message
    /// that is only hello, or thanks, or how are you, is not a lookup that
    /// missed — it is not a lookup — and it gets no captures. Anything else that
    /// finds nothing still gets the recent ones, because "what was that video I
    /// saved" deserves a better answer than a shrug.
    ///
    /// A match is never topped up any more, though. Filling the space under two
    /// real results with three unrelated ones only gave the model three more
    /// things it might hold out by mistake.
    func grounding(for question: String, matches: [ShelfItem], recent: [ShelfItem]) -> [ShelfItem] {
        let found = Array(matches.prefix(Self.groundingLimit))
        guard found.isEmpty else { return found }
        guard !Self.isSmallTalk(question) else { return [] }
        return Array(recent.prefix(Self.groundingLimit))
    }

    /// Whether the message is conversation rather than a question about the
    /// shelf.
    ///
    /// Deliberately a closed list and a strict test — *every* word has to be in
    /// it — so the failure it can have is letting a greeting through as a
    /// lookup, never turning a lookup into a greeting. One unrecognised word is
    /// enough to treat the message as a question, which is the side worth
    /// failing on: the cost is a few recent captures the model was told not to
    /// mention, and the cost of the other side is being unable to find anything.
    private static func isSmallTalk(_ question: String) -> Bool {
        let words = question
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)

        // Nothing but punctuation. Not a lookup either.
        guard !words.isEmpty else { return true }
        return words.allSatisfy { conversational.contains($0) }
    }

    /// Greetings, courtesies, and the function words that keep them company.
    /// Nothing here names anything that could be on a shelf.
    private static let conversational: Set<String> = [
        "hi", "hii", "hiii", "hey", "heya", "hello", "helo", "yo", "sup",
        "hola", "namaste", "morning", "afternoon", "evening", "night", "good",
        "thanks", "thank", "thankyou", "thx", "ty", "cheers", "welcome",
        "please", "sorry", "bye", "goodbye", "later", "ok", "okay", "kk",
        "cool", "nice", "great", "awesome", "lol", "haha", "hmm", "yes", "yeah",
        "yep", "yup", "no", "nope", "nah", "sure", "how", "are", "you", "your",
        "there", "is", "it", "im", "i", "am", "doing", "today", "day", "up",
        "whats", "what", "who", "me", "my", "we", "and", "the", "a", "to", "do"
    ]

    /// The question, with the shelf attached — or, when nothing matched, with
    /// an explanation of why there is no shelf attached.
    ///
    /// The empty case needs its own framing rather than passing the message
    /// through bare. Sent on its own, "hi" came back as nothing at all: the
    /// instructions are mostly about captures, and a model given a greeting and
    /// no context to reply to has nothing to be. Naming the speaker and asking
    /// for a reply is what turns text into a conversation, and both branches
    /// need it.
    ///
    /// It also has to cover two different silences — a greeting, which never had
    /// an answer on the shelf, and a lookup that genuinely missed — so it says
    /// what happened and lets the model tell them apart.
    private static func prompt(question: String, items: [ShelfItem], matched: Bool) -> String {
        guard !items.isEmpty else {
            return """
                Nothing on the user's shelf matched this message.

                The user says: "\(question)"

                Reply to them. If they were asking about something they saved, \
                say plainly that you could not find it. Otherwise just talk to \
                them — do not mention their shelf at all.

                There is nothing to show, so do not call showCaptures.
                """
        }

        let captures = items.prefix(groundingLimit).enumerated().map { index, item in
            described(item, number: index + 1)
        }
        let heading = matched
            ? "Captures from the user's shelf, best match first:"
            : "The user's most recent captures. Do not mention them unless relevant:"

        // The closing line earns its place. With the captures simply followed
        // by `Message: hii`, the model answered "hii" — it mirrored the last
        // thing on the page instead of replying to it. Naming the speaker and
        // asking for a reply is what turns a block of context back into a
        // conversation, and it is the difference between a greeting being
        // greeted and being echoed.
        return """
            \(heading)

            \(captures.joined(separator: "\n"))

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
        // No thread yet always means a conversation that is starting, so it
        // always gets an empty session. Comparing ids here instead would make
        // two consecutive new conversations look identical — both nil — and the
        // second would inherit the first one's memory, which is the exact bug
        // this method exists to prevent.
        guard let thread else {
            session = makeSession(replaying: nil)
            sessionThreadID = nil
            return
        }

        guard session == nil || thread.id != sessionThreadID else { return }
        session = makeSession(replaying: thread)
        sessionThreadID = thread.id
    }

    /// The running session, started on first use.
    private func resolvedSession() -> LanguageModelSession {
        if let session { return session }
        let created = makeSession(replaying: nil)
        session = created
        return created
    }

    /// What the model may call this session.
    ///
    /// The system tools are included only when their connection is actually
    /// granted, and that is a context decision before it is a safety one: the
    /// window is 4096 tokens and every tool definition is spent before the
    /// conversation starts. A user who has connected nothing should not pay for
    /// three descriptions of things Cove cannot do.
    ///
    /// It is not the anti-hallucination mechanism. That is the instructions plus
    /// the tools' own failure wording — a missing tool does not stop a model
    /// claiming it added an event, so the rule has to be stated either way.
    ///
    /// Both lists are built together, and they have to be:
    /// `Transcript.ToolDefinition.init(tool:)` is generic over a concrete `Tool`,
    /// so it cannot be mapped over `[any Tool]` after the fact — the existential
    /// has already thrown away the type it needs. Adding each one through a
    /// generic function is what keeps that type in hand for both uses.
    private func toolset() -> (tools: [any Tool], definitions: [Transcript.ToolDefinition]) {
        var tools: [any Tool] = []
        var definitions: [Transcript.ToolDefinition] = []

        func add(_ tool: some Tool) {
            tools.append(tool)
            definitions.append(Transcript.ToolDefinition(tool: tool))
        }

        add(ShowCapturesTool(offers: offers))

        let connections = CoveConnections.shared
        if connections.calendar.isGranted { add(AddCalendarEventTool()) }
        if connections.reminders.isGranted { add(AddReminderTool()) }
        if connections.notes.isGranted { add(CreateNoteTool()) }

        return (tools, definitions)
    }

    private func makeSession(replaying thread: ChatThread?) -> LanguageModelSession {
        let (tools, definitions) = toolset()

        guard let thread, !thread.turns.isEmpty else {
            return LanguageModelSession(tools: tools, instructions: Self.instructions)
        }

        // Instructions have to be an entry rather than the initialiser's
        // argument on this path: the transcript initialiser takes the whole
        // conversation, and one that opened with a prompt would be a model
        // that had never been told what it is.
        var entries: [Transcript.Entry] = [
            .instructions(
                Transcript.Instructions(
                    segments: [.text(Transcript.TextSegment(content: Self.instructions))],
                    toolDefinitions: definitions
                )
            )
        ]

        // Only the tail, and only turns with something in them. The window is
        // finite, and an old thread long enough to fill it would arrive already
        // overflowing — the recovery would then fire on the first question and
        // throw away the very transcript this was rebuilt to restore.
        let stored = thread.orderedTurns.filter { !$0.text.isEmpty }
        for turn in stored.suffix(Self.replayLimit) {
            let segment = Transcript.Segment.text(Transcript.TextSegment(content: turn.text))
            switch turn.role {
            case .user:
                entries.append(.prompt(Transcript.Prompt(segments: [segment])))
            case .assistant:
                entries.append(.response(Transcript.Response(assetIDs: [], segments: [segment])))
            }
        }

        return LanguageModelSession(tools: tools, transcript: Transcript(entries: entries))
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
    /// overflow it was called to escape. `sessionThreadID` is left alone for the
    /// same reason — the session still belongs to this conversation, it has
    /// simply forgotten it.
    func startNewConversation() {
        session = makeSession(replaying: nil)
    }

    /// One capture, in as few tokens as will still tell it apart from the one
    /// under it.
    ///
    /// This used to run to seven lines — kind, date, source app, host, note,
    /// summary, OCR text, tags — and every one of them looked individually
    /// worth having. Together, across eight captures, they were half the
    /// context window, and what that bought was a model with no room left to
    /// call a tool. Two lines each is the version that works.
    ///
    /// The address is deliberately absent. `showCaptures` resolves that from
    /// the shelf's own record, so putting it here would only spend tokens and
    /// tempt the model to answer with an address instead of a link.
    private static func described(_ item: ShelfItem, number: Int) -> String {
        var headline = "\(number). \(item.title)"
        if let host = item.linkHost, !host.isEmpty {
            headline += " — \(host)"
        } else {
            headline += " — \(item.kind.label.lowercased())"
        }

        // One excerpt, not three, and the most deliberate one available: what
        // the user wrote beats what Cove summarised, which beats what the OCR
        // happened to catch.
        guard let detail = excerpt(item.userNote)
                ?? excerpt(item.summary)
                ?? excerpt(item.extractedText)
        else {
            return headline
        }
        return headline + "\n   \(detail)"
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

// MARK: - Holding out what was found

/// The captures the assistant may put in front of the user, by their number in
/// the prompt — and which of them it has asked for this turn.
///
/// A separate box rather than state on the tool, because the session — and so
/// the tool inside it — is built once and kept, while the captures change with
/// every question. Refreshing this before each turn is what keeps "show me"
/// pointing at what the model was actually shown.
@MainActor
final class ShelfCaptureOffers {
    private struct Target {
        let number: Int
        let id: UUID
        let title: String
        let isOpenable: Bool
    }

    private var targets: [Target] = []

    /// The ids the model asked to show, in the order it asked for them. Read
    /// once the turn is over.
    private(set) var offered: [UUID] = []

    func replace(with items: [ShelfItem]) {
        targets = items.enumerated().map { index, item in
            Target(
                number: index + 1,
                id: item.id,
                title: item.title,
                isOpenable: item.linkURL != nil
            )
        }
        offered = []
    }

    /// Records what to hold out, and answers with the titles so the model can
    /// name them without inventing one.
    ///
    /// Duplicates and unknown numbers are dropped silently — the same capture
    /// asked for twice is one row — but a capture with nothing behind it is
    /// reported, because a note or a screenshot has no address to open and the
    /// model would otherwise tell the user to click something that isn't there.
    func offer(numbered numbers: [Int]) -> (shown: [String], unopenable: [String]) {
        var shown: [String] = []
        var unopenable: [String] = []

        for number in numbers {
            guard let target = targets.first(where: { $0.number == number }) else { continue }
            guard target.isOpenable else {
                unopenable.append(target.title)
                continue
            }
            guard !offered.contains(target.id) else { continue }
            offered.append(target.id)
            shown.append(target.title)
        }

        return (shown, unopenable)
    }
}

/// Hands captures to the user as things to click, rather than opening one for
/// them.
///
/// This replaced a tool that called `NSWorkspace.open` directly, and the reason
/// is worth keeping: on a shelf, "the YouTube link" is routinely two links.
/// Opening the model's pick spent the user's screen on a guess and hid the
/// alternative, and there was no way back to it except asking again. Offering
/// is the same information with the choice left where it belongs.
///
/// The safety property survives the change intact, and it is why the argument
/// is a *number* into the list the model was shown rather than a URL. Nothing
/// the model wrote can become a link: every address the user can click is
/// resolved from the shelf's own record, keyed by an id that came from there.
struct ShowCapturesTool: Tool {
    let offers: ShelfCaptureOffers

    let name = "showCaptures"
    let description = """
        Puts captures from the user's shelf in front of them as links they can \
        click. Use it whenever your reply is about something they saved — \
        whether they asked to open it, asked for its address, or only asked \
        whether they have it. Pass every capture that could be the one they \
        mean; the user picks between them.
        """

    @Generable
    struct Arguments {
        @Guide(description: "The numbers of the captures to show, exactly as listed in the prompt.")
        var numbers: [Int]
    }

    func call(arguments: Arguments) async throws -> String {
        let result = await offers.offer(numbered: arguments.numbers)

        var lines: [String] = []
        if !result.shown.isEmpty {
            lines.append(
                "Now on screen as links the user can click: "
                    + result.shown.map { "“\($0)”" }.joined(separator: ", ")
                    + ". Tell them what these are, in a few words each. Do not type their addresses."
            )
        }
        if !result.unopenable.isEmpty {
            lines.append(
                result.unopenable.map { "“\($0)”" }.joined(separator: ", ")
                    + " could not be shown: there is nothing to open outside Cove."
            )
        }
        guard !lines.isEmpty else {
            // Either the numbers were not on the list, or they were all of it.
            // The model does not need to know which — it needs to know that
            // nothing is on screen, so that it answers in words instead of
            // describing links the user cannot see.
            return """
                Nothing is on screen. Reply in words only, and do not tell the \
                user to click or open anything.
                """
        }
        return lines.joined(separator: " ")
    }
}

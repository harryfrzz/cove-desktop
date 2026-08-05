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
    func answer(
        to question: String,
        grounding items: [ShelfItem],
        matched: Bool
    ) async throws -> Reply {
        guard isReady else { throw AssistantError.noModel }

        let shown = Array(items.prefix(Self.groundingLimit))
        let prompt = Self.prompt(question: question, items: items, matched: matched)
        // What `showCaptures` may reach, for this turn only. Set before the
        // model runs, because the tool can be called during the response.
        offers.replace(with: shown)

        do {
            return try reply(from: await respond(to: prompt), shown: shown)
        } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
            // The conversation has outgrown the window. Start a fresh one and
            // answer this turn rather than handing back an error the user can
            // do nothing about — losing the transcript is a smaller loss than
            // an assistant that stops working until relaunch.
            startNewConversation()
            return try reply(from: await respond(to: prompt), shown: shown)
        } catch LanguageModelSession.GenerationError.guardrailViolation {
            // Apple's safety filter, and it fires on innocuous things — asking
            // for the URL of a saved video tripped it in testing while asking
            // to open the same video did not. The user has done nothing wrong
            // and there is nothing to fix, so this says so briefly instead of
            // showing them a Swift error description.
            throw AssistantError.declined
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
        var offered = offers.offered
        var prose = text

        // A call the model typed instead of made. See `typedCalls`.
        for (written, numbers) in Self.typedCalls(in: text) {
            for number in numbers {
                let index = number - 1
                guard shown.indices.contains(index) else { continue }
                let id = shown[index].id
                if !offered.contains(id) { offered.append(id) }
            }
            prose = prose.replacingOccurrences(of: written, with: "")
        }

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
        guard let regex = try? NSRegularExpression(
            pattern: #"\bshowCaptures\s*\(\s*(?:numbers\s*:)?\s*\[([0-9,\s]*)\]\s*\)"#,
            options: .caseInsensitive
        ) else { return [] }

        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let whole = Range(match.range, in: text),
                  let list = Range(match.range(at: 1), in: text)
            else { return nil }

            let numbers = text[list]
                .split(separator: ",")
                .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard !numbers.isEmpty else { return nil }
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

        One or two short sentences. No preamble, no bullet points.
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

    /// The running session, started on first use.
    ///
    /// Also the recovery point: a long enough conversation eventually fills the
    /// context window, and the only cure is a new session. That is handled in
    /// `answer(to:grounding:)` by dropping this and retrying once, which costs
    /// the transcript and keeps the assistant answering — the alternative is a
    /// panel that works all day and then refuses everything until relaunch.
    private func resolvedSession() -> LanguageModelSession {
        if let session { return session }
        let created = LanguageModelSession(
            tools: [ShowCapturesTool(offers: offers)],
            instructions: Self.instructions
        )
        session = created
        return created
    }

    /// Forgets the conversation. The shelf is unaffected; only the transcript
    /// the model is carrying goes.
    func startNewConversation() {
        session = nil
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

        var errorDescription: String? {
            switch self {
            case .noModel: "Cove’s on-device model isn’t available on this Mac."
            case .emptyAnswer: "The model didn’t return an answer."
            case .declined: "The model wouldn’t answer that one — try asking it a different way."
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
            return "None of those numbers are on the list you were shown, so nothing is on screen."
        }
        return lines.joined(separator: " ")
    }
}

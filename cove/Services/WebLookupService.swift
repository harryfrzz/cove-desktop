import Foundation

/// A page Cove read off the web, cut down to what the context window can hold.
///
/// Carries only `String` and `URL` because it crosses from wherever the fetch
/// ran into the main actor, where the prompt is built.
struct WebPage: Sendable {
    let url: URL
    let title: String?
    /// The readable body, already stripped of markup and truncated. Never the
    /// whole page: see `WebLookupService.excerptLimit`.
    let text: String

    /// What the page is named by in the prompt and, later, in the reply. The
    /// host rather than the address, because the address is the thing the model
    /// is told never to type back.
    var host: String { url.host() ?? url.absoluteString }

    var isEmpty: Bool { title == nil && text.isEmpty }
}

/// Reads a link the user pasted into a question, so the answer can be about
/// what is on the page rather than about the address.
///
/// This is Cove's second network call, and the first one that sends anything
/// the user typed anywhere. It is deliberately narrow: it fetches exactly the
/// address in their message, over HTTP, and nothing else — no search engine, no
/// query, no referrer. Ask "what does this say?" with a link and the page is
/// fetched; ask anything without a link and Cove stays entirely on the Mac.
///
/// Off is a real option and lives next to link previews in Settings. On is the
/// default, because a link pasted into a prompt bar is a request to look at it.
enum WebLookupService {
    /// Defaults key backing the opt-out. Absent means on, matching
    /// `LinkPreviewService` — an existing install picks this up without needing
    /// to be told about it, and the Privacy section says what it does.
    nonisolated static let defaultsKey = "cove.readPastedLinks"

    nonisolated static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
    }

    nonisolated static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: defaultsKey)
    }

    /// Long enough for a slow page, short enough that a dead host does not make
    /// the assistant look hung. The question is not answered until this
    /// finishes, and the user is watching a working indicator the whole time.
    private static let timeout: TimeInterval = 8

    /// How much of the page is downloaded before Cove stops listening.
    ///
    /// The readable part of an article is a few kilobytes; the rest is scripts.
    /// Capping the *read* rather than trusting `Content-Length` is what makes
    /// this safe against a page that never ends.
    private static let byteLimit = 512 * 1024

    /// How much of the page reaches the model.
    ///
    /// The context window is 4096 tokens, shared with the instructions, the
    /// captures and the running transcript — the same budget that forced
    /// captures down to 120 characters each. 800 is roughly the opening of an
    /// article, which is where a page says what it is.
    private static let excerptLimit = 800

    /// Web addresses in what the user typed, first one first.
    ///
    /// Only `http` and `https`: a `file:` or `mailto:` in a message is not a
    /// page, and following the first would read the user's disk on the strength
    /// of a string in a chat bar.
    static func links(in text: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return [] }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var found: [URL] = []

        for match in detector.matches(in: text, range: range) {
            guard let url = match.url else { continue }
            guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
            else { continue }
            // The same link twice in one message is one page.
            guard !found.contains(url) else { continue }
            found.append(url)
        }

        return found
    }

    /// Reads the page, or returns `nil` if there is nothing worth reading.
    ///
    /// Best effort by the same reasoning as `LinkPreviewService`: a page that
    /// will not load, answers with an image, or turns out to be a login wall is
    /// not an error the caller has to handle. It means the answer is grounded in
    /// the shelf alone, which is what it would have been anyway.
    static func read(_ url: URL) async -> WebPage? {
        guard isEnabled else { return nil }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("text/html,text/plain;q=0.9", forHTTPHeaderField: "Accept")
        // Sites that reject an unnamed client are common enough that omitting
        // this reads as "Cove can't open half the web".
        request.setValue("Mozilla/5.0 (Macintosh) Cove/1.0", forHTTPHeaderField: "User-Agent")
        // Nothing about the user goes with the request.
        request.httpShouldHandleCookies = false

        guard let (data, response) = try? await load(request) else { return nil }
        guard (response as? HTTPURLResponse)?.statusCode ?? 200 < 400 else { return nil }

        // A PDF or an image decoded as UTF-8 is a page of replacement
        // characters, and a page of those in the prompt is worse than no page.
        let type = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Type")?
            .lowercased() ?? "text/html"
        guard type.contains("html") || type.contains("text/plain") else { return nil }

        let html = String(data: data, encoding: .utf8)
            ?? String(decoding: data, as: UTF8.self)

        let page = WebPage(
            url: response.url ?? url,
            title: title(in: html),
            text: excerpt(from: html)
        )
        return page.isEmpty ? nil : page
    }

    /// The bytes of a picture at a web address, for an image the user attached
    /// rather than saved.
    ///
    /// Dragging an image out of a browser puts an `http` URL on the pasteboard,
    /// not a file — so the thing the user pointed at is not on disk and there is
    /// nothing to open. `read(_:)` refuses it, correctly, because it is not a
    /// page; without this the attachment arrived at the model as a bare link and
    /// the answer was about nothing.
    ///
    /// Same switch, same cap. Fetching a picture the user dropped is the same
    /// request as fetching a page they pasted.
    static func imageData(at url: URL) async -> Data? {
        guard isEnabled else { return nil }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0 (Macintosh) Cove/1.0", forHTTPHeaderField: "User-Agent")
        request.httpShouldHandleCookies = false

        guard let (data, response) = try? await load(request) else { return nil }
        guard (response as? HTTPURLResponse)?.statusCode ?? 200 < 400 else { return nil }

        // A page served where a picture was expected — a login wall, or a link
        // that only looked like an image. Decoding it would produce nothing.
        let type = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Type")?
            .lowercased() ?? ""
        guard type.isEmpty || type.contains("image") else { return nil }

        return data.isEmpty ? nil : data
    }

    /// Whether an address is worth trying as a picture before trying it as a
    /// page. Only the extension — the real answer is the response's own content
    /// type, which `imageData(at:)` checks.
    static func looksLikeImage(_ url: URL) -> Bool {
        ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tiff", "bmp"]
            .contains(url.pathExtension.lowercased())
    }

    /// Downloads at most `byteLimit`, then stops.
    private static func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let (stream, response) = try await URLSession.shared.bytes(for: request)
        var data = Data()
        data.reserveCapacity(min(byteLimit, 64 * 1024))

        for try await byte in stream {
            data.append(byte)
            if data.count >= byteLimit { break }
        }

        return (data, response)
    }

    // MARK: - Markup, removed

    private static func title(in html: String) -> String? {
        guard let match = first(of: "<title[^>]*>(.*?)</title>", in: html, group: 1)
        else { return nil }

        let cleaned = decoded(match).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// The page as prose.
    ///
    /// A real reader would find the article element and drop the navigation.
    /// This does the crude version — throw away the parts that are definitely
    /// not prose, then throw away the tags — because the alternative is an HTML
    /// parser in an app whose whole point is what it does *not* ship, and 800
    /// characters of a slightly noisy page still tells the model what the page
    /// is about.
    private static func excerpt(from html: String) -> String {
        var text = readable(html)

        // Script and style bodies first: their contents survive tag-stripping
        // and would otherwise be the bulk of what the model reads.
        //
        // Through `NSRegularExpression` rather than `replacingOccurrences`,
        // because the option that matters cannot be passed to that one. Without
        // `dotMatchesLineSeparators`, `.*?` stops at the first newline — and a
        // `<script>` block is nothing but newlines, so every one of them
        // survived. Wikipedia came back as three hundred characters of
        // `vector-feature-language-in-header-enabled`, which is what the model
        // would have been asked to answer from.
        text = removing("<(script|style|noscript|svg|head)\\b[^>]*>.*?</\\1>", from: text)
        // A page cut off at `byteLimit` can end inside one of those, leaving an
        // opening tag with no partner for the pattern above to match. What
        // follows is the same unreadable minified soup, so it goes too.
        text = removing("<(script|style|noscript|svg)\\b[^>]*>.*", from: text)
        text = removing("<!--.*?-->", from: text)

        // Block-level tags become spaces so two paragraphs do not run into one
        // word; the rest simply go.
        text = removing("<[^>]+>", from: text, with: " ")
        text = decoded(text)

        // Whatever markup left behind — runs of spaces, blank lines — collapsed
        // to single spaces. Layout is not information here.
        text = removing("\\s+", from: text, with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // A page whose prose could not be found at all — an app that draws
        // itself with JavaScript, a paywall, a page whose markup this is simply
        // too crude for. Its own summary of itself is a better answer than a
        // sentence of leftovers, and far better than nothing.
        if text.count < thinnessLimit, let summary = description(in: html) {
            text = summary
        }

        guard text.count > excerptLimit else { return text }
        // Cut on a word rather than mid-token, so the last thing the model reads
        // is not half a name.
        let cut = text.prefix(excerptLimit)
        let end = cut.lastIndex(of: " ") ?? cut.endIndex
        return String(cut[cut.startIndex..<end]) + "…"
    }

    /// Below this, what came out of the markup is not an excerpt of the page.
    /// Roughly a sentence — enough to tell "the article starts here" from "the
    /// article is drawn by a script this cannot see".
    private static let thinnessLimit = 160

    /// The part of the page that is the page.
    ///
    /// Without this step the first 800 characters of any real site are its
    /// navigation: the Wikipedia article on otters began "Jump to content Main
    /// menu move to sidebar hide Navigation Main page Contents Current events
    /// Random article", which is 300 characters that describe Wikipedia and say
    /// nothing about otters. The model would have answered from it, and been
    /// right to.
    ///
    /// `<article>` and `<main>` are the two elements that mean "this is the
    /// content" — greedy to their last close, so a page of several articles
    /// gives all of them rather than only the first. Failing both, the chrome
    /// is named and dropped instead. A page that uses none of these is read
    /// whole, as before.
    private static func readable(_ html: String) -> String {
        let body = first(of: "<article\\b[^>]*>(.*)</article>", in: html, group: 1)
            ?? first(of: "<main\\b[^>]*>(.*)</main>", in: html, group: 1)
            ?? first(of: "<body\\b[^>]*>(.*)</body>", in: html, group: 1)
            ?? html

        return removing("<(nav|header|footer|aside|form|menu)\\b[^>]*>.*?</\\1>", from: body)
    }

    /// What the page says it is about, from the metadata every share sheet and
    /// search engine reads. Open Graph first — it is written for a human to
    /// read, where `meta description` is often keywords.
    private static func description(in html: String) -> String? {
        let patterns = [
            "<meta[^>]+property=[\"']og:description[\"'][^>]+content=[\"']([^\"']*)[\"']",
            "<meta[^>]+content=[\"']([^\"']*)[\"'][^>]+property=[\"']og:description[\"']",
            "<meta[^>]+name=[\"']description[\"'][^>]+content=[\"']([^\"']*)[\"']",
            "<meta[^>]+content=[\"']([^\"']*)[\"'][^>]+name=[\"']description[\"']"
        ]

        for pattern in patterns {
            guard let found = first(of: pattern, in: html, group: 1) else { continue }
            let cleaned = decoded(found).trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty { return cleaned }
        }
        return nil
    }

    /// `NSRegularExpression` with the two options every pattern here needs:
    /// tag names are matched whatever their case, and `.` crosses newlines,
    /// which is the whole reason this exists rather than
    /// `String.replacingOccurrences(options: .regularExpression)`.
    private static func removing(
        _ pattern: String,
        from text: String,
        with replacement: String = ""
    ) -> String {
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return text }

        return expression.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..<text.endIndex, in: text),
            withTemplate: replacement
        )
    }

    /// One capture group out of the first match, or `nil` if there isn't one.
    private static func first(of pattern: String, in text: String, group: Int) -> String? {
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return nil }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = expression.firstMatch(in: text, range: range),
              let captured = Range(match.range(at: group), in: text)
        else { return nil }

        return String(text[captured])
    }

    /// The entities that actually turn up in prose. Not a full table on purpose:
    /// an unrecognised entity reads as itself, which is untidy, while a wrong
    /// expansion changes what the page said.
    private static func decoded(_ text: String) -> String {
        var out = text
        for (entity, character) in [
            ("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&hellip;", "…"),
            ("&mdash;", "—"), ("&ndash;", "–"), ("&rsquo;", "’"), ("&lsquo;", "‘"),
            ("&ldquo;", "“"), ("&rdquo;", "”")
        ] {
            out = out.replacingOccurrences(of: entity, with: character, options: .caseInsensitive)
        }
        return out
    }
}

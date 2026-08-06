import AppKit
import Foundation
import UniformTypeIdentifiers

/// A thing the user pointed at, once something has read it.
///
/// Carries nothing but strings, and that is a requirement rather than tidiness:
/// `TempTray.Entry` holds `NSImage` and lives on the main actor, so none of it
/// may cross into the assistant as it stands. This is what crosses instead —
/// the same reasoning that gave `LinkPreview` its shape.
struct HeldReading: Sendable {
    /// What to call it in the prompt. A filename, a host, or the first words of
    /// a sentence.
    let name: String
    /// What kind of thing it is, in the words the model should use for it.
    let kind: String
    /// What it says, already bounded. Empty when nothing could be read from it,
    /// which is a normal outcome — a held spreadsheet has a name and no text
    /// Cove is willing to open it to find.
    let text: String

    var isEmpty: Bool { text.isEmpty }
}

/// Reads whatever is attached to the next question, on the user's say-so.
///
/// Everything here is on-device: Vision for a picture's text, the string itself
/// for a sentence, and — only for a web address, and only behind its own switch
/// — `WebLookupService`. Nothing is stored. The reading is built for one
/// question and thrown away with it, which is what keeps the holding shelf's
/// promise intact: a thing that was asked about is not a thing that was saved.
@MainActor
enum HeldReader {
    /// How much of the attached thing reaches the model.
    ///
    /// Between a capture's 120 and a scheduling capture's 600, and nearer the
    /// top of that range because this is the one thing on the page the user
    /// explicitly pointed at. The context window is still 4096 tokens, so the
    /// room comes out of the shelf — see `CoveAssistant.heldGroundingLimit`.
    private static let limit = 600

    /// What a held file is worth reading directly, as opposed to describing.
    ///
    /// A short list on purpose. Cove will open a file the user attached, but it
    /// will not go looking inside formats it would have to guess at — a PDF read
    /// as UTF-8 is a page of replacement characters, and handing the model those
    /// is worse than handing it a filename.
    private static let readableTypes: [UTType] = [.plainText, .sourceCode, .json, .commaSeparatedText, .yaml]

    static func read(_ entry: TempTray.Entry) async -> HeldReading? {
        switch entry.pasteboardItem() {
        case let image as NSImage:
            return await read(image, named: entry.name)

        case let text as NSString:
            return HeldReading(
                name: entry.name,
                kind: "a note",
                text: String(String(text).prefix(limit))
            )

        case let url as NSURL:
            guard let url = url as URL? else { return nil }
            return await read(url, named: entry.name)

        default:
            return nil
        }
    }

    private static func read(_ url: URL, named name: String) async -> HeldReading? {
        guard url.isFileURL else {
            // An image dragged out of a browser is an `http` URL, not a file,
            // and it is the commonest way an image reaches Ask Cove. Sent down
            // the page path it came back as "a link" with nothing in it, and the
            // model — handed a name and no content — answered from the shelf
            // captures underneath instead. That is the whole of the bug: an
            // attachment that could not be read did not read as unreadable, it
            // read as a question about something else.
            if WebLookupService.looksLikeImage(url),
               let data = await WebLookupService.imageData(at: url),
               let image = NSImage(data: data) {
                return await read(image, named: url.lastPathComponent)
            }

            // A web address goes through the same path a pasted link does, and
            // is off when that is off. Attaching a link is asking Cove to look
            // at the page, which is the request the switch governs.
            guard let page = await WebLookupService.read(url) else {
                // One more try as a picture, for an address that carries no
                // extension to guess from. Content type settles it.
                if let data = await WebLookupService.imageData(at: url),
                   let image = NSImage(data: data) {
                    return await read(image, named: name)
                }
                return HeldReading(name: url.host() ?? name, kind: "a link", text: "")
            }
            return HeldReading(
                name: page.title ?? page.host,
                kind: "a page on \(page.host)",
                text: page.text
            )
        }

        let type = UTType(filenameExtension: url.pathExtension)

        if type?.conforms(to: .image) == true, let image = NSImage(contentsOf: url) {
            return await read(image, named: name)
        }

        if let type, readableTypes.contains(where: { type.conforms(to: $0) }),
           let contents = try? String(contentsOf: url, encoding: .utf8) {
            return HeldReading(
                name: name,
                kind: "a file",
                text: String(contents.prefix(limit))
            )
        }

        // Named but unread. Still worth attaching: "what is this?" about a file
        // Cove cannot open is answered by its name and type, and saying nothing
        // would be answering it with silence.
        return HeldReading(name: name, kind: "a file", text: "")
    }

    /// A picture, read every way Cove can read one.
    ///
    /// Apple's language model takes text and nothing else — there is no vision
    /// here, and pretending otherwise is what made this feature look broken. So
    /// a picture is turned into the two true things Cove can say about it: the
    /// words in it, through the same Vision recogniser every capture goes
    /// through, and what it appears to be, through the same classifier that
    /// files captures into albums.
    ///
    /// The classification matters most for the pictures OCR cannot help with.
    /// A photo of a meal has no text in it at all, and "a photo (Food)" is a
    /// small thing to know and infinitely more than nothing — which is what the
    /// model had before, and what it filled in for itself.
    private static func read(_ image: NSImage, named name: String) async -> HeldReading {
        let recognised = await text(in: image)
        let category = ImageSemanticClassifier.category(for: image, recognizedText: recognised)

        return HeldReading(
            name: name,
            kind: category == .other ? "an image" : "an image (\(category.title))",
            text: recognised
        )
    }

    /// The words in a picture. A screenshot is the thing most often held, and
    /// its text is the whole of what a question about it is asking.
    private static func text(in image: NSImage) async -> String {
        guard let ocr = AIServices.current.ocr,
              let recognised = try? await ocr.recognizeText(in: image)
        else { return "" }

        return String(
            recognised
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(limit)
        )
    }
}

import Foundation

/// The byte-pair tokenizer CLIP's text tower was trained with.
///
/// Every CLIP-family text encoder — MobileCLIP included — expects token ids from
/// this exact vocabulary, so this is not a detail that can be approximated. A
/// tokenizer that splits differently produces ids the encoder has never seen,
/// and the vector that comes back is confident nonsense rather than an error.
///
/// The vocabulary and merge table ship as resources rather than being derived at
/// runtime: they are fixed artefacts of the trained model, and reading them is
/// cheaper than rebuilding them.
nonisolated final class CLIPTokenizer: @unchecked Sendable {
    /// Loaded once. Building the merge table means parsing 48k lines, which is
    /// fast but pointless to repeat for every prompt Cove encodes.
    static let shared: CLIPTokenizer? = CLIPTokenizer()

    /// `<|startoftext|>`, prepended to every sequence.
    private let startToken: Int32
    /// `<|endoftext|>`. The encoder reads its position as the sentence vector,
    /// so it has to survive truncation — see `encode(_:contextLength:)`.
    private let endToken: Int32

    private let encoder: [String: Int32]
    /// Merge priority: the lower the rank, the earlier the pair is joined.
    private let ranks: [BytePair: Int]
    private let byteEncoder: [UInt8: Character]
    private let pattern: NSRegularExpression

    /// Already-tokenized words. Cove encodes the same album prompts on every
    /// launch and the same words recur across captures, so the BPE loop is worth
    /// running once per distinct word.
    private var cache: [String: [Int32]] = [:]
    private let cacheLock = NSLock()

    private struct BytePair: Hashable {
        let first: String
        let second: String
    }

    init?(
        vocabularyURL: URL? = Bundle.main.url(forResource: "clip_vocab", withExtension: "json"),
        mergesURL: URL? = Bundle.main.url(forResource: "clip_merges", withExtension: "txt")
    ) {
        guard let vocabularyURL,
              let mergesURL,
              let vocabularyData = try? Data(contentsOf: vocabularyURL),
              let decoded = try? JSONDecoder().decode([String: Int32].self, from: vocabularyData),
              let mergesText = try? String(contentsOf: mergesURL, encoding: .utf8),
              let start = decoded["<|startoftext|>"],
              let end = decoded["<|endoftext|>"] else {
            return nil
        }

        encoder = decoded
        startToken = start
        endToken = end

        var table: [BytePair: Int] = [:]
        // The first line is a `#version:` header, and the file ends with a blank
        // line; both are skipped by requiring exactly two fields.
        for (index, line) in mergesText.split(separator: "\n").dropFirst().enumerated() {
            let parts = line.split(separator: " ")
            guard parts.count == 2 else { continue }
            table[BytePair(first: String(parts[0]), second: String(parts[1]))] = index
        }
        ranks = table

        byteEncoder = Self.bytesToUnicode()

        guard let regex = try? NSRegularExpression(
            pattern: #"<\|startoftext\|>|<\|endoftext\|>|'s|'t|'re|'ve|'m|'ll|'d|[\p{L}]+|[\p{N}]|[^\s\p{L}\p{N}]+"#,
            options: [.caseInsensitive]
        ) else {
            return nil
        }
        pattern = regex
    }

    /// Token ids padded to `contextLength`, as the text encoder expects.
    ///
    /// Padding is zero rather than the end token: CLIP pads with 0 and reads the
    /// *highest* end-token position, so padding with the end token would move
    /// the read to the tail of the padding and return the embedding of nothing.
    func encode(_ text: String, contextLength: Int) -> [Int32] {
        var tokens: [Int32] = [startToken]

        for word in words(in: normalize(text)) {
            tokens.append(contentsOf: tokenize(word))
            // One over the limit is enough to know the rest is unreachable; the
            // truncation below reclaims the final slot for the end token.
            if tokens.count >= contextLength { break }
        }

        if tokens.count >= contextLength {
            tokens = Array(tokens.prefix(contextLength - 1))
        }
        tokens.append(endToken)

        return tokens + Array(repeating: 0, count: contextLength - tokens.count)
    }

    // MARK: - Pre-tokenizing

    /// Lowercased, with runs of whitespace collapsed — the normalization CLIP's
    /// own tokenizer applies before it splits anything.
    private func normalize(_ text: String) -> String {
        text
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private func words(in text: String) -> [String] {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return pattern.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }

    // MARK: - Byte-pair encoding

    private func tokenize(_ word: String) -> [Int32] {
        cacheLock.lock()
        let cached = cache[word]
        cacheLock.unlock()
        if let cached { return cached }

        // Bytes, not characters. Mapping through `byteEncoder` first is what
        // lets one fixed vocabulary cover every language and every emoji: any
        // byte the model has not seen as part of a merge still resolves to a
        // single known symbol rather than falling out of the vocabulary.
        var symbols = Array(word.utf8).compactMap { byteEncoder[$0] }.map(String.init)
        guard !symbols.isEmpty else { return [] }
        // The word-final marker is part of the last symbol, which is how BPE
        // distinguishes "in" inside a word from "in" that ends one.
        symbols[symbols.count - 1] += "</w>"

        while symbols.count > 1 {
            guard let best = lowestRankedPair(in: symbols) else { break }
            symbols = merging(best, in: symbols)
        }

        let ids = symbols.compactMap { encoder[$0] }
        cacheLock.lock()
        cache[word] = ids
        cacheLock.unlock()
        return ids
    }

    private func lowestRankedPair(in symbols: [String]) -> BytePair? {
        var best: BytePair?
        var bestRank = Int.max

        for index in 0..<(symbols.count - 1) {
            let pair = BytePair(first: symbols[index], second: symbols[index + 1])
            guard let rank = ranks[pair], rank < bestRank else { continue }
            best = pair
            bestRank = rank
        }
        return best
    }

    /// Joins every occurrence of `pair`, left to right. Non-overlapping by
    /// construction: a merged symbol is never re-examined as the left half of
    /// the same pass.
    private func merging(_ pair: BytePair, in symbols: [String]) -> [String] {
        var merged: [String] = []
        merged.reserveCapacity(symbols.count)

        var index = 0
        while index < symbols.count {
            if index < symbols.count - 1,
               symbols[index] == pair.first,
               symbols[index + 1] == pair.second {
                merged.append(pair.first + pair.second)
                index += 2
            } else {
                merged.append(symbols[index])
                index += 1
            }
        }
        return merged
    }

    /// The reversible byte-to-symbol map GPT-2 introduced and CLIP reuses.
    ///
    /// Printable ASCII and printable Latin-1 stand for themselves; the remaining
    /// 68 byte values are lifted into an unused block above U+0100. The point is
    /// that every byte maps to exactly one printable, non-whitespace character,
    /// so BPE can run over text without control bytes or spaces ever splitting a
    /// symbol.
    private static func bytesToUnicode() -> [UInt8: Character] {
        var bytes: [UInt8] = []
        bytes.append(contentsOf: UInt8(ascii: "!")...UInt8(ascii: "~"))
        bytes.append(contentsOf: UInt8(0xA1)...UInt8(0xAC))
        bytes.append(contentsOf: UInt8(0xAE)...UInt8(0xFF))

        var scalars = bytes.map { UInt32($0) }
        var next: UInt32 = 0
        for byte in UInt8.min...UInt8.max where !bytes.contains(byte) {
            bytes.append(byte)
            scalars.append(256 + next)
            next += 1
        }

        return Dictionary(
            uniqueKeysWithValues: zip(bytes, scalars).compactMap { byte, scalar in
                Unicode.Scalar(scalar).map { (byte, Character($0)) }
            }
        )
    }
}

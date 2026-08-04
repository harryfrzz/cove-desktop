import AppIntents
import AppKit
import SwiftData
import SwiftUI
import WidgetKit

// MARK: - Theme
//
// A rack of passes. Each capture is printed as a ticket: solid saturated
// stock, white ink, monospaced micro-labels, and a stub torn off along a
// perforation.
//
// The stock is deliberately *solid*. An earlier pass laid each capture's own
// screenshot behind its card, and the result was noise: a busy thumbnail under
// white type, four times over. The picture belongs in the app. What a pass
// carries is a name, a time, and a colour you can recognise across the rack.
//
// Neither the canvas nor the passes follow the system appearance. The passes
// are artwork, printed white-on-colour; the rack behind them is dark so they
// sit in relief — see `Cove.canvas`.

private enum Cove {
    /// The rack is dark in both appearances, like the island is.
    ///
    /// It followed the system until the passes were printed edge to edge, and
    /// then the canvas had nowhere left to hide: on medium it is only the seam
    /// between two passes, and in the light appearance that seam was a white
    /// stripe splitting the widget in half. Behind the large rack it washed the
    /// stock out the same way.
    ///
    /// A pass is saturated artwork and reads best on something dark, which is
    /// also the argument the island already makes. So the widget commits, and
    /// what was a bright seam is now a shadowed gap between two tickets — which
    /// is what the gap was always meant to look like.
    /// `CoveTheme.surface` exactly — the pure black the island is. It was a very
    /// dark grey, which was a third surface nothing else in Cove had, and on the
    /// large rack it is the only place the canvas shows.
    static let canvas = Color.black
    /// `CoveTheme.ink` exactly — the app's warm cream rather than the neutral
    /// off-white this was. A hundredth of a point of blue is all that separated
    /// them, and it was enough to make the widget read cool beside an island
    /// that reads warm.
    static let ink = Color(red: 0.96, green: 0.94, blue: 0.90)
    static let inkSecondary = ink.opacity(0.5)
    static let chip = Color.white.opacity(0.09)
}

/// The stock every capture is printed on. One colour, not five.
///
/// Five saturated stocks were a legend that had to be learned before it paid
/// anything back, and the price was paid on every card at once: four passes on
/// the large rack meant four competing fields of colour, and on a desktop whose
/// own furniture is neutral glass over a wallpaper, that read as a widget from
/// another operating system.
///
/// So the stock is graphite and the kind is a mark on it — see `KindTint`. The
/// colour is still there and still means the same thing; it is a dot rather
/// than the whole card, which is the size the information was always worth.
///
/// The stock a capture is printed on: the accent the user chose, which is the
/// same colour the island's controls are.
///
/// Nothing here is a constant any more, and that is the whole feature. What it
/// costs is that the card's *ink* is not a constant either — Deep Water and
/// Sahara are not the same kind of colour to print on, and a face hardcoded in
/// white is legible on one and unreadable on the other. Everything drawn on a
/// pass therefore asks `\.coveAccent` what colour it is rather than assuming.
private extension CoveAccent {
    /// What may be printed on this stock.
    var ink: Color {
        prefersDarkInk ? Color(red: 0.11, green: 0.10, blue: 0.09) : Cove.ink
    }

    /// The same ink at the weight the card's quieter marks want. A single
    /// helper because there are eight of them and they were eight separate
    /// `.white.opacity(_:)` calls that all had to change together.
    func ink(_ opacity: Double) -> Color { ink.opacity(opacity) }
}

private struct CoveAccentKey: EnvironmentKey {
    static let defaultValue = CoveAccent.deepWater
}

private extension EnvironmentValues {
    var coveAccent: CoveAccent {
        get { self[CoveAccentKey.self] }
        set { self[CoveAccentKey.self] = newValue }
    }
}

/// The one mark a pass carries, keyed to what the capture is.
///
/// The coastline the app icon is sampled from — deep water through shallow,
/// then the sand and the stone above it — ordered by how far out to sea the
/// thing came from: what Cove saw is water, what you wrote is shore.
///
/// Every one is a pale tint rather than a saturated one, because these are
/// printed *on* the stock rather than being it. Two rules came out of that and
/// both are load-bearing: nothing here may be violet, or it vanishes into the
/// card; and the commonest kind takes the ink, because a shelf is mostly
/// screenshots and the mark you see most should be the quietest one.
private enum KindTint {
    /// Screenshots — the deep blue the icon's horizon fades from.
    case deepWater
    /// Images — shallower, greener, still unmistakably sea.
    case shallows
    /// Links — the indigo where water meets dusk.
    case tideline
    /// Notes — the warm sand the icon's lower half is.
    case shore
    /// Files — the stone above the waterline, inert on purpose.
    case stone

    init(_ kind: ShelfItemKind) {
        switch kind {
        case .screenshot: self = .deepWater
        case .image: self = .shallows
        case .link: self = .tideline
        case .text: self = .shore
        case .file: self = .stone
        }
    }

    /// The mark's colour on a given stock.
    ///
    /// Two sets, because the card is now whichever of six colours the user
    /// picked and they are not all the same kind of surface. Pale marks read on
    /// Deep Water and disappear on Champagne; deep ones do the reverse. Which
    /// set applies is the same question the card's ink already answers, so it is
    /// asked once, of the accent, rather than guessed here.
    func color(on accent: CoveAccent) -> Color {
        // A screenshot is the commonest thing on a shelf, so its mark is simply
        // the ink — the default kind rather than a missing one. It is also the
        // only one that needs no second version.
        guard self != .deepWater else { return accent.ink }
        return accent.prefersDarkInk ? onLightStock : onDarkStock
    }

    private var onDarkStock: Color {
        switch self {
        case .deepWater: Color(red: 0.96, green: 0.94, blue: 0.90)
        case .shallows: Color(red: 0.55, green: 0.91, blue: 0.87)
        // The dusk rather than the indigo under it. The lavender this was is
        // the one hue a violet card leaves nowhere to stand, so the tideline is
        // read at the moment the sky over it goes pink instead.
        case .tideline: Color(red: 0.98, green: 0.68, blue: 0.82)
        case .shore: Color(red: 1.00, green: 0.79, blue: 0.56)
        // Neutral rather than the cool grey it was, which read as a weaker
        // version of `shallows`.
        case .stone: Color(red: 0.86, green: 0.86, blue: 0.87)
        }
    }

    /// The same coastline at depth, for the warm and light stocks.
    private var onLightStock: Color {
        switch self {
        case .deepWater: Color(red: 0.11, green: 0.10, blue: 0.09)
        case .shallows: Color(red: 0.04, green: 0.40, blue: 0.42)
        case .tideline: Color(red: 0.60, green: 0.15, blue: 0.36)
        case .shore: Color(red: 0.62, green: 0.29, blue: 0.08)
        case .stone: Color(red: 0.22, green: 0.25, blue: 0.30)
        }
    }
}

// MARK: - What a pass says
//
// The shelf stores what macOS called a file: "Screenshot 2026-08-01 at
// 12.43.28 AM". Printed whole that wraps to two lines and swamps the card, so
// each pass is given a headline short enough to read at a glance and a line of
// context under it.

private extension CaptureSnapshot {
    /// The large line: what this capture *is*.
    ///
    /// An earlier version printed the time here, which was the wrong fact —
    /// a rack of cards reading "12:43 AM" tells you when something landed and
    /// nothing about what it was, which is useless for finding anything again.
    ///
    /// What OCR read comes first, because for a screenshot that is the only
    /// honest answer. Failing that, the name macOS gave the file with its
    /// timestamp stripped off — "Screen Recording" rather than "11:33 PM".
    var headline: String {
        switch kind {
        case .link:
            // A dragged tab. Its page title says what it is; the host is the
            // fallback, and both beat the URL.
            let name = linkTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let name, !name.isEmpty, name != "/" { return Self.clip(name) }
            if let host = linkHost, !host.isEmpty {
                return Self.clip(host.replacingOccurrences(of: "www.", with: ""))
            }
            return Self.clip(title)

        case .text:
            // A dragged selection. The words *are* the item.
            let note = userNote?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let note, !note.isEmpty { return Self.clip(note.replacingOccurrences(of: "\n", with: " ")) }
            return Self.clip(title)

        case .screenshot, .image:
            if let digest = ocrDigest { return digest }
            return Self.clip(Self.strippedName(from: title), fallback: kind.label)

        case .file:
            return Self.clip(Self.strippedName(from: title), fallback: kind.label)
        }
    }

    /// The small line under it: for a link its host, for anything else when it
    /// landed and where from.
    var subhead: String {
        if kind == .link, let host = linkHost, !host.isEmpty {
            return host.replacingOccurrences(of: "www.", with: "")
        }
        let time = Self.timestamp(in: title) ?? createdAt.formatted(date: .omitted, time: .shortened)
        guard let source = sourceApp, !source.isEmpty else { return time }
        return "\(time) · \(source)"
    }

    /// "Screenshot 2026-08-01 at 12.43.28 AM" → "Screenshot".
    static func strippedName(from title: String) -> String {
        let stem = (title as NSString).deletingPathExtension
        let name = stem.range(of: " at ").map { String(stem[..<$0.lowerBound]) } ?? stem
        return stripDate(from: name)
    }

    static func clip(_ text: String, fallback: String = "") -> String {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return fallback }
        return cleaned.count > 17 ? String(cleaned.prefix(16)) + "…" : cleaned
    }

    /// The first few words OCR read that are worth printing.
    ///
    /// Screenshots of a Mac almost always open with the menu bar, so the raw
    /// text starts "Safari File Edit View History Bookmarks…". The app's own
    /// name is the useful part of that and the menus are not, so the first word
    /// is kept and known menu titles are dropped from everything after it.
    var ocrDigest: String? {
        guard let raw = extractedText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }

        var kept: [String] = []
        for (index, word) in raw.split(whereSeparator: { $0.isWhitespace }).enumerated() {
            let clean = String(word).trimmingCharacters(in: .punctuationCharacters)
            guard clean.count > 1, clean.contains(where: \.isLetter) else { continue }
            if index > 0, Self.menuWords.contains(clean.lowercased()) { continue }
            kept.append(clean)
            if kept.count == 3 { break }
        }

        guard !kept.isEmpty else { return nil }
        let joined = kept.joined(separator: " ")
        return joined.count > 17 ? String(joined.prefix(16)) + "…" : joined
    }

    /// Menu titles common to almost every Mac app, worth nothing on a card.
    static let menuWords: Set<String> = [
        "file", "edit", "view", "window", "help", "history", "bookmarks",
        "develop", "format", "go", "tools", "find", "navigate", "editor",
        "product", "debug", "integrate", "insert", "arrange", "share", "table"
    ]

    /// Drops a trailing "2026-08-01" style date from a file's name.
    static func stripDate(from name: String) -> String {
        name.split(whereSeparator: { $0.isWhitespace })
            .filter { part in !(part.contains("-") && part.contains(where: \.isNumber)) }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Pulls "12:43 AM" out of the names macOS gives screenshots and
    /// recordings. Returns nil for anything that isn't one, so real filenames
    /// are left alone.
    private static func timestamp(in title: String) -> String? {
        guard let atRange = title.range(of: " at ") else { return nil }
        let tail = title[atRange.upperBound...]

        // "12.43.28 AM" / "12.43.28AM" — hours and minutes are all that fit.
        let parts = tail.split(separator: ".")
        guard parts.count >= 2, let hour = Int(parts[0]) else { return nil }
        let minute = parts[1].prefix(2)
        guard minute.count == 2, minute.allSatisfy(\.isNumber) else { return nil }

        let upper = tail.uppercased()
        let suffix = upper.contains("PM") ? "PM" : (upper.contains("AM") ? "AM" : "")
        return "\(hour):\(minute)\(suffix.isEmpty ? "" : " \(suffix)")"
    }
}

/// Compact relative age — "now", "4m", "3h", "2d".
private func shortAge(_ date: Date, now: Date = .now) -> String {
    let seconds = max(0, now.timeIntervalSince(date))
    switch seconds {
    case ..<60: return "now"
    case ..<3600: return "\(Int(seconds / 60))m"
    case ..<86400: return "\(Int(seconds / 3600))h"
    default: return "\(Int(seconds / 86400))d"
    }
}

/// A short serial, derived from the item's own id so it is stable across
/// refreshes. Decorative — but it is what makes a pass read as issued.
private func serial(_ id: UUID) -> String {
    String(id.uuidString.prefix(3)).uppercased()
}

// MARK: - Ticket furniture

/// A rounded card with a bite taken out of each side where the stub tears off.
private struct TicketShape: Shape {
    var cornerRadius: CGFloat = 16
    var notchRadius: CGFloat = 5.5
    /// Distance from the bottom edge up to the perforation.
    var stubHeight: CGFloat

    func path(in rect: CGRect) -> Path {
        let tearY = rect.maxY - stubHeight
        let body = Path(roundedRect: rect, cornerRadius: cornerRadius)
        var notches = Path()
        for x in [rect.minX, rect.maxX] {
            notches.addEllipse(
                in: CGRect(
                    x: x - notchRadius,
                    y: tearY - notchRadius,
                    width: notchRadius * 2,
                    height: notchRadius * 2
                )
            )
        }
        return body.subtracting(notches)
    }
}

/// The halftone field printed across the shoulder of the stock. Drawn rather
/// than tiled so it stays crisp at any card size.
private struct DotField: View {
    @Environment(\.coveAccent) private var accent

    var body: some View {
        let dots = accent.ink(0.34)

        return Canvas { context, size in
            let spacing: CGFloat = 7
            let dot = CGSize(width: 1.2, height: 1.2)
            var y: CGFloat = 0
            while y < size.height {
                var x: CGFloat = 0
                while x < size.width {
                    context.fill(
                        Path(ellipseIn: CGRect(origin: CGPoint(x: x, y: y), size: dot)),
                        with: .color(dots)
                    )
                    x += spacing
                }
                y += spacing
            }
        }
        .allowsHitTesting(false)
    }
}

/// Three shadows, because that is what lift is made of: a tight contact shadow
/// where the card meets the rack, a mid one for the body of the gap, and a wide
/// ambient one that gives the whole thing somewhere to sit. One shadow reads as
/// a sticker; two as a card; three as a card you could pick up.
private struct PassShadow: ViewModifier {
    var lift: CGFloat = 1
    func body(content: Content) -> some View {
        content
            .shadow(color: .black.opacity(0.24 * lift), radius: 1 * lift, y: 1 * lift)
            .shadow(color: .black.opacity(0.20 * lift), radius: 6 * lift, y: 4 * lift)
            .shadow(color: .black.opacity(0.16 * lift), radius: 17 * lift, y: 11 * lift)
    }
}

/// The lit edge of a raised card: bright along the top where the light lands,
/// fading to almost nothing underneath. A single flat stroke draws a box around
/// the card; this one gives it a thickness.
///
/// A `ShapeStyle` rather than a view because `resolve(in:)` hands it the
/// environment, which is how it reads the accent without being passed one — the
/// lit edge of a dark card and of a light one are not the same colour.
private struct Bevel: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> LinearGradient {
        let ink = environment.coveAccent.ink

        return LinearGradient(
            colors: [ink.opacity(0.55), ink.opacity(0.22), ink.opacity(0.08)],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

/// Monospaced micro-label — the caption stock every pass is annotated in.
private struct Micro: View {
    @Environment(\.coveAccent) private var accent

    let text: String
    var size: CGFloat = 6.5
    var opacity: Double = 0.62

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: size, weight: .bold, design: .monospaced))
            .tracking(0.7)
            // Always the card's ink: every one of these is printed on a pass.
            // The rack's own chrome uses plain `Text` on `Cove.ink`, because it
            // sits on the canvas and the accent has no say over it.
            .foregroundStyle(accent.ink(opacity))
            .lineLimit(1)
    }
}

// MARK: - Entry

struct CoveEntry: TimelineEntry {
    let date: Date
    /// Read when the timeline is built rather than when a view draws, so the
    /// whole entry is printed on one stock. The app reloads timelines the moment
    /// the choice changes — otherwise this would be up to an hour stale.
    ///
    /// Declared here, ahead of the contents, only so the memberwise initialiser
    /// takes it in the order the call sites read best; it is defaulted, so
    /// `placeholder` can still leave it out.
    var accent: CoveAccent = .deepWater
    let items: [CaptureSnapshot]
    let total: Int
    let todayCount: Int
}

struct CaptureSnapshot: Identifiable {
    let id: UUID
    let title: String
    let kind: ShelfItemKind
    let sourceApp: String?
    let extractedText: String?
    let linkHost: String?
    let linkTitle: String?
    let userNote: String?
    let imageData: Data?
    let createdAt: Date
}

// MARK: - Provider

/// Reads the most-recent captures each time the timeline is rebuilt. The app
/// nudges this with `WidgetCenter.reloadAllTimelines()` after a capture; the
/// hourly refresh below is only a fallback for the day rolling over.
struct CoveProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> CoveEntry {
        CoveEntry(date: .now, items: [], total: 0, todayCount: 0)
    }

    func snapshot(
        for configuration: SelectCoveAccentIntent,
        in context: Context
    ) async -> CoveEntry {
        readEntry(accent: configuration.colour.accent)
    }

    func timeline(
        for configuration: SelectCoveAccentIntent,
        in context: Context
    ) async -> Timeline<CoveEntry> {
        let entry = readEntry(accent: configuration.colour.accent)
        let next = Calendar.current.date(byAdding: .hour, value: 1, to: .now) ?? .now
        return Timeline(entries: [entry], policy: .after(next))
    }

    /// The accent is handed in rather than read from a shared default: it is a
    /// property of *this* widget, which is what lets two Cove tiles on one
    /// desktop be two different colours.
    private func readEntry(accent: CoveAccent) -> CoveEntry {
        let context = ModelContext(CoveStore.shared)

        var recent = FetchDescriptor<ShelfItem>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        recent.fetchLimit = 8
        let items = (try? context.fetch(recent)) ?? []

        let total = (try? context.fetchCount(FetchDescriptor<ShelfItem>())) ?? items.count

        let startOfDay = Calendar.current.startOfDay(for: .now)
        let todayDescriptor = FetchDescriptor<ShelfItem>(
            predicate: #Predicate { $0.createdAt >= startOfDay }
        )
        let todayCount = (try? context.fetchCount(todayDescriptor)) ?? 0

        return CoveEntry(
            date: .now,
            accent: accent,
            items: items.map {
                CaptureSnapshot(
                    id: $0.id,
                    title: $0.title,
                    kind: $0.kind,
                    sourceApp: $0.sourceApp,
                    extractedText: $0.extractedText,
                    linkHost: $0.linkHost,
                    linkTitle: $0.linkTitle,
                    userNote: $0.userNote,
                    imageData: $0.imageData,
                    createdAt: $0.createdAt
                )
            },
            total: total,
            todayCount: todayCount
        )
    }
}

// MARK: - The pass

/// One capture, printed as a ticket: serial and mark along the top, the
/// halftone shoulder, the headline, then the stub.
private struct PassFace: View {
    @Environment(\.coveAccent) private var accent

    let snapshot: CaptureSnapshot
    var headlineSize: CGFloat = 22
    /// Extra room for a pass printed edge to edge — without it the type sits
    /// against the rounded corner the system clips to.
    var inset: CGFloat = 0

    private var tint: Color { KindTint(snapshot.kind).color(on: accent) }

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: accent.gradient, startPoint: .top, endPoint: .bottom)

            DotField()
                .frame(height: 40)
                .padding(.top, 26)
                .mask {
                    LinearGradient(
                        colors: [.white, .white.opacity(0)],
                        startPoint: .top, endPoint: .bottom
                    )
                }

            // The sheen where the light lands on the card's own face, just
            // inside the lit edge. Stops short of the perforation — a stub is
            // the part that has been torn off and handled, not polished.
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [accent.ink(0.20), .clear],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 22)
                Spacer(minLength: 0)
            }
            .allowsHitTesting(false)

            content
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(snapshot.kind.label): \(snapshot.headline), from \(snapshot.subhead), saved \(shortAge(snapshot.createdAt)) ago"
        )
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Micro(text: "no. \(serial(snapshot.id))")
                Spacer(minLength: 0)
                // The kind's colour, now that the card no longer carries it.
                // Beside the word rather than instead of it: a dot alone is the
                // legend the five stocks were, and this way the first card you
                // ever see teaches what the colour means.
                Circle()
                    .fill(tint)
                    .frame(width: 5, height: 5)
                Micro(text: "cove · \(snapshot.kind.label)")
            }

            Spacer(minLength: 6)

            HStack(alignment: .bottom, spacing: 7) {
                // The capture itself, stamped small. Full-bleed it was
                // wallpaper and the card became noise; at this size it is what
                // makes a pass recognisable in one glance, before a word of it
                // is read.
                Group {
                    if let data = snapshot.imageData, let image = NSImage(data: data) {
                        Color.clear
                            .overlay { Image(nsImage: image).resizable().scaledToFill() }
                            .clipped()
                    } else {
                        // A link or a note has no picture, so the stamp carries
                        // its glyph instead. Leaving the slot empty made those
                        // cards sit a step out of line with the rest of the rack.
                        //
                        // Tinted rather than plain white. A capture with a
                        // picture is recognisable from the picture; one without
                        // has only its kind to go on, so the stamp is where that
                        // kind is said loudest.
                        tint.opacity(0.22)
                            .overlay {
                                Image(systemName: snapshot.kind.systemImage)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(tint)
                            }
                    }
                }
                .frame(width: 26, height: 26)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(accent.ink(0.35), lineWidth: 0.75)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.headline)
                        .font(.system(size: headlineSize, weight: .heavy))
                        .tracking(-0.5)
                        .foregroundStyle(accent.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    Micro(text: snapshot.subhead, size: 7, opacity: 0.78)
                }
            }

            perforation
                .padding(.top, 9)

            HStack(alignment: .bottom, spacing: 8) {
                fact("saved", shortAge(snapshot.createdAt))
                Spacer(minLength: 0)
                fact("kind", snapshot.kind.label, alignment: .trailing)
            }
            .padding(.top, 7)
        }
        .padding(.horizontal, 12 + inset)
        .padding(.vertical, 11 + inset)
    }

    private var perforation: some View {
        Line()
            .stroke(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .foregroundStyle(accent.ink(0.35))
            .frame(height: 1)
    }

    private func fact(
        _ label: String,
        _ value: String,
        alignment: HorizontalAlignment = .leading
    ) -> some View {
        VStack(alignment: alignment, spacing: 1) {
            Micro(text: label, size: 6, opacity: 0.58)
            Text(value.uppercased())
                .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                .foregroundStyle(accent.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            return path
        }
    }
}

/// One capture on its own ticket.
private struct PassCard: View {
    let snapshot: CaptureSnapshot
    var headlineSize: CGFloat = 22
    var stubHeight: CGFloat = 30
    /// Matched to the widget's own corner when the pass fills the tile, and
    /// kept tighter when it is one card sitting on a rack.
    var cornerRadius: CGFloat = 16
    var inset: CGFloat = 0

    private var shape: TicketShape {
        TicketShape(cornerRadius: cornerRadius, stubHeight: stubHeight)
    }

    var body: some View {
        PassFace(snapshot: snapshot, headlineSize: headlineSize, inset: inset)
            .compositingGroup()
            .clipShape(shape)
            .overlay { shape.stroke(Bevel(), lineWidth: 1) }
            .modifier(PassShadow())
    }
}

/// One ticket, torn down the middle, with a capture printed either side.
///
/// Medium used to be two separate cards with a gap between them, and the gap
/// was the problem: it is the only place the canvas showed, so it read as two
/// things that had been put next to each other rather than one thing. This is a
/// single ticket instead — the halves meet, the tear between them is a
/// perforation with a bite out of each end, and the card is what fills the tile.
///
/// Both halves are now printed on the same stock, so the tear is the only thing
/// telling them apart — which is what a real ticket's perforation does anyway.
/// Each half still carries its own kind dot up in the corner.
private struct SplitPass: View {
    let left: CaptureSnapshot
    let right: CaptureSnapshot
    var headlineSize: CGFloat = 19
    var cornerRadius: CGFloat = 22
    var inset: CGFloat = 3

    private var shape: SplitTicketShape {
        SplitTicketShape(cornerRadius: cornerRadius)
    }

    var body: some View {
        HStack(spacing: 0) {
            PassFace(snapshot: left, headlineSize: headlineSize, inset: inset)
            PassFace(snapshot: right, headlineSize: headlineSize, inset: inset)
        }
        .overlay(alignment: .center) { perforation }
        .compositingGroup()
        .clipShape(shape)
        .overlay { shape.stroke(Bevel(), lineWidth: 1) }
        .modifier(PassShadow())
    }

    /// The tear. Drawn over the seam rather than between the halves, so the two
    /// stocks stay touching and the line reads as printed on the ticket instead
    /// of as a gap left between two of them.
    ///
    /// White, not black. A dark dash was legible when the stock was saturated;
    /// on graphite it disappears, and with it the only thing saying the medium
    /// is two captures rather than one wide card.
    private var perforation: some View {
        VerticalLine()
            .stroke(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .foregroundStyle(.white.opacity(0.22))
            .frame(width: 1)
            .padding(.vertical, 10)
    }

    private struct VerticalLine: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            return path
        }
    }
}

/// A rounded card with a bite taken out of the top and bottom edges, where the
/// tear between its two halves meets them.
private struct SplitTicketShape: Shape {
    var cornerRadius: CGFloat = 22
    var notchRadius: CGFloat = 6

    func path(in rect: CGRect) -> Path {
        let body = Path(roundedRect: rect, cornerRadius: cornerRadius)
        var notches = Path()
        for y in [rect.minY, rect.maxY] {
            notches.addEllipse(
                in: CGRect(
                    x: rect.midX - notchRadius,
                    y: y - notchRadius,
                    width: notchRadius * 2,
                    height: notchRadius * 2
                )
            )
        }
        return body.subtracting(notches)
    }
}

// MARK: - Chrome

/// The rack's masthead: the mark, the name, what is in it, and the one control.
private struct Masthead: View {
    let entry: CoveEntry

    var body: some View {
        HStack(spacing: 7) {
            Button(intent: OpenCoveIntent()) {
                HStack(spacing: 7) {
                    Text("C")
                        .font(.system(size: 12, weight: .bold, design: .serif))
                        .foregroundStyle(Cove.canvas)
                        .frame(width: 22, height: 22)
                        .background(Cove.ink, in: Circle())
                    Text("Cove")
                        .font(.system(size: 15, weight: .semibold, design: .serif))
                        .foregroundStyle(Cove.ink)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            Text("\(entry.total) total".uppercased())
                .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                .tracking(0.5)
                .foregroundStyle(Cove.inkSecondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Cove.chip, in: Capsule())
                .lineLimit(1)

            // The utilities. Both do their real work in the app — the
            // extension can neither run an open panel nor put a capture
            // through the ingest pipeline — but from here they are one tap.
            Utility(
                symbol: "doc.on.clipboard",
                label: "Paste into Cove",
                intent: PasteIntoCoveIntent()
            )
            Utility(
                symbol: "plus",
                label: "Add a file to Cove",
                intent: AddFileToCoveIntent()
            )
        }
    }
}

/// One round action button in the masthead.
private struct Utility<I: AppIntent>: View {
    let symbol: String
    let label: String
    let intent: I

    var body: some View {
        Button(intent: intent) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Cove.canvas)
                .frame(width: 22, height: 22)
                .background(Cove.ink, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// The footer: which kinds are in the rack, and where they live.
private struct RackFooter: View {
    let entry: CoveEntry

    /// Drawn on the canvas rather than on a pass, so the marks are taken from
    /// the dark-stock set whatever the card is doing — the rack behind the
    /// passes is black in every theme.
    private var kinds: [Color] {
        var seen: [Color] = []
        for item in entry.items {
            let colour = KindTint(item.kind).color(on: .deepWater)
            if !seen.contains(where: { $0 == colour }) { seen.append(colour) }
        }
        return Array(seen.prefix(3))
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(kinds.enumerated()), id: \.offset) { index, colour in
                Circle()
                    .fill(colour)
                    .frame(width: 13, height: 13)
                    .overlay(Circle().strokeBorder(Cove.canvas, lineWidth: 1.5))
                    .offset(x: CGFloat(index) * -4)
            }
            Spacer(minLength: 0)
            Text("on device".uppercased())
                .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                .tracking(0.6)
                .foregroundStyle(Cove.inkSecondary)
            Image(systemName: "lock.fill")
                .font(.system(size: 7.5, weight: .bold))
                .foregroundStyle(Cove.inkSecondary)
                .padding(.leading, 4)
        }
    }
}

private struct EmptyRack: View {
    @Environment(\.coveAccent) private var accent

    var body: some View {
        VStack(spacing: 8) {
            // The one place the accent shows on an empty shelf. Without it,
            // someone who installs Cove and opens the colour drawer before
            // saving anything picks six colours and watches nothing happen.
            // The tint rather than the ink: this is drawn on the black rack,
            // never on stock, and all six tints carry there.
            Image(systemName: "tray")
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(accent.tint)
            Text("drop something\ninto the notch".uppercased())
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .tracking(0.5)
                .lineSpacing(3)
                .multilineTextAlignment(.center)
                .foregroundStyle(Cove.inkSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Wraps a card so tapping it opens that capture in Cove.
private struct PassButton<Content: View>: View {
    let itemID: UUID
    @ViewBuilder let content: Content
    var body: some View {
        Button(intent: OpenCaptureIntent(itemID: itemID)) {
            content.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Sizes

/// Sizing shared by the three families.
///
/// The widget turns WidgetKit's default content margins off, so a pass can be
/// the tile rather than a card floating in the middle of one — the margins were
/// what put a band of canvas around the blue on every side. Everything that
/// still wants breathing room asks for it here instead.
private enum Layout {
    /// Close to the corner macOS rounds a widget to. A pass printed edge to
    /// edge has to match it, or the canvas shows through at the corners.
    static let tileCorner: CGFloat = 22
    /// Padding put back for the large rack, which has a masthead and a footer
    /// that would otherwise sit against the edge.
    static let rackPadding: CGFloat = 14
    /// Breathing room inside a pass that has no margin outside it.
    static let bleedInset: CGFloat = 3
    static let passGap: CGFloat = 9
}

struct CoveWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: CoveEntry

    var body: some View {
        Group {
            switch family {
            case .systemSmall: SmallView(entry: entry)
            case .systemLarge: LargeView(entry: entry)
            default: MediumView(entry: entry)
            }
        }
        // Planted once, here, rather than passed down. A pass is drawn by six
        // small views — the halftone, the bevel, every micro-label — and each of
        // them needs to know what it is being printed on. Threading a parameter
        // through all six is how one of them ends up still hardcoded in white.
        .environment(\.coveAccent, entry.accent)
    }
}

/// Small: the widget *is* the pass, edge to edge.
private struct SmallView: View {
    let entry: CoveEntry

    var body: some View {
        if let first = entry.items.first {
            PassButton(itemID: first.id) {
                PassCard(
                    snapshot: first,
                    headlineSize: 21,
                    stubHeight: 30,
                    cornerRadius: Layout.tileCorner,
                    inset: Layout.bleedInset
                )
            }
        } else {
            EmptyRack().padding(Layout.rackPadding)
        }
    }
}

/// Medium: one ticket, torn down the middle, a capture either side.
private struct MediumView: View {
    let entry: CoveEntry

    var body: some View {
        if entry.items.isEmpty {
            EmptyRack().padding(Layout.rackPadding)
        } else if entry.items.count == 1, let only = entry.items.first {
            // Nothing to tear against. One capture gets the whole ticket rather
            // than half of one beside an empty half.
            PassButton(itemID: only.id) {
                PassCard(
                    snapshot: only,
                    headlineSize: 21,
                    stubHeight: 30,
                    cornerRadius: Layout.tileCorner,
                    inset: Layout.bleedInset
                )
            }
        } else {
            let pair = Array(entry.items.prefix(2))
            // Each half opens its own capture, so the ticket being one object
            // does not cost the two halves their separate destinations.
            ZStack {
                SplitPass(
                    left: pair[0],
                    right: pair[1],
                    headlineSize: 19,
                    cornerRadius: Layout.tileCorner,
                    inset: Layout.bleedInset
                )
                HStack(spacing: 0) {
                    ForEach(pair) { item in
                        PassButton(itemID: item.id) {
                            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
            }
        }
    }
}

/// Large: the full rack — masthead, four passes, footer.
///
/// Every card is a ticket here, as on the smaller sizes. An earlier version
/// gave the newest capture a full-bleed photo card, which was wrong twice
/// over: a desktop shelf is mostly screenshots of interfaces, and a screenshot
/// of an interface shrunk to a hero image is clutter rather than a picture —
/// and the picture pushed the rack's own footer off the tile.
private struct LargeView: View {
    let entry: CoveEntry

    var body: some View {
        VStack(spacing: 11) {
            Masthead(entry: entry)

            if entry.items.isEmpty {
                EmptyRack()
            } else {
                LazyVGrid(
                    columns: [GridItem(spacing: Layout.passGap), GridItem(spacing: Layout.passGap)],
                    spacing: Layout.passGap
                ) {
                    ForEach(entry.items.prefix(4)) { item in
                        PassButton(itemID: item.id) {
                            PassCard(snapshot: item, headlineSize: 18, stubHeight: 28)
                        }
                        .frame(height: 116)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)

                RackFooter(entry: entry)
            }
        }
        // The rack keeps its margin: unlike small and medium, this size is a
        // board with chrome on it rather than one pass filling the tile.
        .padding(Layout.rackPadding)
    }
}

// MARK: - Widget

struct CoveWidget: Widget {
    var body: some WidgetConfiguration {
        // Configurable, so the colour belongs to the tile: right-click the
        // widget, Edit Widget, pick one of six. The app itself is always Deep
        // Water — this is the only place a colour is chosen.
        //
        // `kind` is the original, and going back to it is the fix rather than
        // an oversight. Renaming it was an attempt to dodge a descriptor cache
        // that turned out not to be the problem, and each rename orphaned every
        // placed tile — "CoveShelf", "CoveRack", "CovePassRack" and
        // "CoveTicketRack" are all dead ends with abandoned widgets behind them.
        // This is the one that was demonstrably serving Edit Widget correctly.
        AppIntentConfiguration(
            kind: "CoveWidget",
            intent: SelectCoveAccentIntent.self,
            provider: CoveProvider()
        ) { entry in
            CoveWidgetView(entry: entry)
                .containerBackground(for: .widget) { RackCanvas() }
        }
        .configurationDisplayName("Cove")
        .description("Your most recent captures, and a button to paste one more.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        // A pass is the tile, not a card inside one. WidgetKit's default
        // margins put a band of canvas around every edge of the stock, which
        // read as the ticket having been dropped into a black box.
        .contentMarginsDisabled()
    }
}

/// Plain by design, so the passes sit in relief instead of over a wash.
private struct RackCanvas: View {
    var body: some View { Cove.canvas }
}

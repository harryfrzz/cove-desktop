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
// The canvas stays plain so the passes sit in relief. The passes themselves do
// not invert — they are artwork, printed white-on-colour in both schemes.

private enum Cove {
    static func canvas(_ s: ColorScheme) -> Color {
        s == .dark ? Color(red: 0.09, green: 0.09, blue: 0.10) : .white
    }

    static func ink(_ s: ColorScheme) -> Color {
        s == .dark ? Color(red: 0.95, green: 0.94, blue: 0.92)
                   : Color(red: 0.11, green: 0.11, blue: 0.12)
    }

    static func inkSecondary(_ s: ColorScheme) -> Color { ink(s).opacity(0.5) }

    static func chip(_ s: ColorScheme) -> Color {
        s == .dark ? .white.opacity(0.09) : .black.opacity(0.045)
    }
}

/// The stock a capture is printed on. Two hues carry the rack — ocean for
/// things Cove saw, ember for things you wrote or linked — with a graphite for
/// plain files. Three is enough to tell passes apart; five was a fruit salad.
private enum Stock {
    case ocean, ember, graphite

    init(_ kind: ShelfItemKind) {
        switch kind {
        case .screenshot, .image: self = .ocean
        case .link, .text: self = .ember
        case .file: self = .graphite
        }
    }

    var gradient: [Color] {
        switch self {
        case .ocean: [Color(red: 0.24, green: 0.52, blue: 0.96), Color(red: 0.12, green: 0.33, blue: 0.84)]
        case .ember: [Color(red: 0.95, green: 0.44, blue: 0.32), Color(red: 0.89, green: 0.36, blue: 0.24)]
        case .graphite: [Color(red: 0.35, green: 0.40, blue: 0.48), Color(red: 0.19, green: 0.23, blue: 0.29)]
        }
    }

    var chipColor: Color { gradient[0] }
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
    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 7
            let dot = CGSize(width: 1.2, height: 1.2)
            var y: CGFloat = 0
            while y < size.height {
                var x: CGFloat = 0
                while x < size.width {
                    context.fill(
                        Path(ellipseIn: CGRect(origin: CGPoint(x: x, y: y), size: dot)),
                        with: .color(.white.opacity(0.34))
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
private struct Bevel: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> LinearGradient {
        LinearGradient(
            colors: [.white.opacity(0.55), .white.opacity(0.22), .white.opacity(0.08)],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

/// Monospaced micro-label — the caption stock every pass is annotated in.
private struct Micro: View {
    let text: String
    var size: CGFloat = 6.5
    var opacity: Double = 0.62
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: size, weight: .bold, design: .monospaced))
            .tracking(0.7)
            .foregroundStyle(.white.opacity(opacity))
            .lineLimit(1)
    }
}

// MARK: - Entry

struct CoveEntry: TimelineEntry {
    let date: Date
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
struct CoveProvider: TimelineProvider {
    func placeholder(in context: Context) -> CoveEntry {
        CoveEntry(date: .now, items: [], total: 0, todayCount: 0)
    }

    func getSnapshot(in context: Context, completion: @escaping (CoveEntry) -> Void) {
        completion(readEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CoveEntry>) -> Void) {
        let entry = readEntry()
        let next = Calendar.current.date(byAdding: .hour, value: 1, to: .now) ?? .now
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func readEntry() -> CoveEntry {
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
private struct PassCard: View {
    let snapshot: CaptureSnapshot
    var headlineSize: CGFloat = 22
    var stubHeight: CGFloat = 30
    /// Matched to the widget's own corner when the pass fills the tile, and
    /// kept tighter when it is one card sitting on a rack.
    var cornerRadius: CGFloat = 16
    /// Extra room for a pass printed edge to edge — without it the type sits
    /// against the rounded corner the system clips to.
    var inset: CGFloat = 0

    private var stock: Stock { Stock(snapshot.kind) }
    private var shape: TicketShape {
        TicketShape(cornerRadius: cornerRadius, stubHeight: stubHeight)
    }

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: stock.gradient, startPoint: .top, endPoint: .bottom)

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
                    colors: [.white.opacity(0.20), .clear],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 22)
                Spacer(minLength: 0)
            }
            .allowsHitTesting(false)

            content
        }
        .compositingGroup()
        .clipShape(shape)
        .overlay { shape.stroke(Bevel(), lineWidth: 1) }
        .modifier(PassShadow())
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
                        Color.white.opacity(0.16)
                            .overlay {
                                Image(systemName: snapshot.kind.systemImage)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.9))
                            }
                    }
                }
                .frame(width: 26, height: 26)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(.white.opacity(0.5), lineWidth: 0.75)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.headline)
                        .font(.system(size: headlineSize, weight: .heavy))
                        .tracking(-0.5)
                        .foregroundStyle(.white)
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
            .foregroundStyle(.white.opacity(0.35))
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
                .foregroundStyle(.white)
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

// MARK: - Chrome

/// The rack's masthead: the mark, the name, what is in it, and the one control.
private struct Masthead: View {
    let entry: CoveEntry
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 7) {
            Button(intent: OpenCoveIntent()) {
                HStack(spacing: 7) {
                    Text("C")
                        .font(.system(size: 12, weight: .bold, design: .serif))
                        .foregroundStyle(Cove.canvas(scheme))
                        .frame(width: 22, height: 22)
                        .background(Cove.ink(scheme), in: Circle())
                    Text("Cove")
                        .font(.system(size: 15, weight: .semibold, design: .serif))
                        .foregroundStyle(Cove.ink(scheme))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            Text("\(entry.total) total".uppercased())
                .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                .tracking(0.5)
                .foregroundStyle(Cove.inkSecondary(scheme))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Cove.chip(scheme), in: Capsule())
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
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(intent: intent) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Cove.canvas(scheme))
                .frame(width: 22, height: 22)
                .background(Cove.ink(scheme), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// The footer: which stocks are in the rack, and where they live.
private struct RackFooter: View {
    let entry: CoveEntry
    @Environment(\.colorScheme) private var scheme

    private var stocks: [Color] {
        var seen: [Color] = []
        for item in entry.items {
            let colour = Stock(item.kind).chipColor
            if !seen.contains(where: { $0 == colour }) { seen.append(colour) }
        }
        return Array(seen.prefix(3))
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(stocks.enumerated()), id: \.offset) { index, colour in
                Circle()
                    .fill(colour)
                    .frame(width: 13, height: 13)
                    .overlay(Circle().strokeBorder(Cove.canvas(scheme), lineWidth: 1.5))
                    .offset(x: CGFloat(index) * -4)
            }
            Spacer(minLength: 0)
            Text("on device".uppercased())
                .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                .tracking(0.6)
                .foregroundStyle(Cove.inkSecondary(scheme))
            Image(systemName: "lock.fill")
                .font(.system(size: 7.5, weight: .bold))
                .foregroundStyle(Cove.inkSecondary(scheme))
                .padding(.leading, 4)
        }
    }
}

private struct EmptyRack: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(Cove.inkSecondary(scheme))
            Text("drop something\ninto the notch".uppercased())
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .tracking(0.5)
                .lineSpacing(3)
                .multilineTextAlignment(.center)
                .foregroundStyle(Cove.inkSecondary(scheme))
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
        switch family {
        case .systemSmall: SmallView(entry: entry)
        case .systemLarge: LargeView(entry: entry)
        default: MediumView(entry: entry)
        }
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

/// Medium: two passes, side by side.
private struct MediumView: View {
    let entry: CoveEntry

    var body: some View {
        if entry.items.isEmpty {
            EmptyRack().padding(Layout.rackPadding)
        } else {
            HStack(spacing: Layout.passGap) {
                ForEach(entry.items.prefix(2)) { item in
                    PassButton(itemID: item.id) {
                        PassCard(
                            snapshot: item,
                            headlineSize: 19,
                            stubHeight: 30,
                            cornerRadius: Layout.tileCorner,
                            inset: Layout.bleedInset
                        )
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
        StaticConfiguration(kind: "CoveWidget", provider: CoveProvider()) { entry in
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
    @Environment(\.colorScheme) private var scheme
    var body: some View { Cove.canvas(scheme) }
}

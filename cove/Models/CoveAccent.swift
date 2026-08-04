import SwiftUI

/// The one colour the user gets to choose, and everything that follows from it.
///
/// Cove is otherwise monochrome on purpose — pure black, warm cream, one accent
/// — which is what makes a picker cheap here: there is exactly one value to
/// swap, and no layout, spacing or type decision depends on it.
///
/// Shared with the widget extension rather than owned by the app, because the
/// values live here and the *choice* is made over there: a widget's colour is
/// collected by its own Edit Widget menu and belongs to that tile, so two Cove
/// widgets on one desktop can be two different colours. `CoveAccentChoice`, in
/// the extension, is the menu's half of this.
///
/// The app itself is not one of the six. It is always Deep Water — see
/// `CoveTheme.accent` — which is why nothing here writes to a shared default.
nonisolated struct CoveAccent: Identifiable, Sendable, Hashable {
    let id: String
    let title: String

    private let tintRGB: Components
    private let deepRGB: Components

    /// Whether what is printed *on* this colour has to be dark.
    ///
    /// A bool rather than a stored ink colour, because the two targets spell
    /// their inks differently — the app has `CoveTheme.surface` and the widget
    /// has its own near-black — and what actually needs sharing is the fact,
    /// not one side's name for it.
    ///
    /// This is the one property that has caused every text-legibility bug in
    /// this palette so far. Cream on the blue is fine and cream on the seafoam
    /// is 2.9:1; getting that wrong is invisible in code review and obvious the
    /// moment anyone reads a filter pill.
    let prefersDarkInk: Bool

    struct Components: Sendable, Hashable {
        let red: Double
        let green: Double
        let blue: Double
        var color: Color { Color(red: red, green: green, blue: blue) }
    }

    /// The accent itself, and the top of the widget's card.
    var tint: Color { tintRGB.color }
    /// The bottom of that card's gradient.
    var deep: Color { deepRGB.color }
    var gradient: [Color] { [tint, deep] }
}

// MARK: - The six

/// `nonisolated`, and it has to be spelled out: the app target builds with
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and the widget target does not,
/// so without this the same presets are main-actor in one process and free in
/// the other. The widget's timeline provider is not on the main actor, which
/// makes the widget's reading the correct one.
nonisolated extension CoveAccent {
    /// The default, and the colour Cove has shipped as. Every other preset is an
    /// alternative to this one rather than a peer of it — which is why this is
    /// also the fallback whenever a stored choice cannot be read.
    static let deepWater = CoveAccent(
        id: "deepWater",
        title: "Deep Water",
        tintRGB: .init(red: 0.24, green: 0.52, blue: 0.96),
        deepRGB: .init(red: 0.12, green: 0.33, blue: 0.84),
        prefersDarkInk: false
    )

    static let plum = CoveAccent(
        id: "plum",
        title: "Smoky Plum",
        tintRGB: .init(red: 0.55, green: 0.48, blue: 0.72),
        deepRGB: .init(red: 0.36, green: 0.31, blue: 0.50),
        prefersDarkInk: true
    )

    static let seafoam = CoveAccent(
        id: "seafoam",
        title: "Seafoam",
        tintRGB: .init(red: 0.42, green: 0.78, blue: 0.74),
        deepRGB: .init(red: 0.24, green: 0.56, blue: 0.54),
        prefersDarkInk: true
    )

    static let amber = CoveAccent(
        id: "amber",
        title: "Amber",
        tintRGB: .init(red: 0.91, green: 0.64, blue: 0.24),
        deepRGB: .init(red: 0.75, green: 0.49, blue: 0.13),
        prefersDarkInk: true
    )

    static let sahara = CoveAccent(
        id: "sahara",
        title: "Sahara",
        tintRGB: .init(red: 0.79, green: 0.48, blue: 0.28),
        deepRGB: .init(red: 0.62, green: 0.34, blue: 0.19),
        prefersDarkInk: true
    )

    static let champagne = CoveAccent(
        id: "champagne",
        title: "Champagne",
        tintRGB: .init(red: 0.78, green: 0.70, blue: 0.54),
        deepRGB: .init(red: 0.62, green: 0.54, blue: 0.39),
        prefersDarkInk: true
    )

    /// Deep Water first because it is the default; the rest are ordered cool to
    /// warm so the row reads as a spectrum rather than a list.
    static let all: [CoveAccent] = [
        .deepWater, .plum, .seafoam, .champagne, .amber, .sahara
    ]

    static func preset(id: String?) -> CoveAccent {
        guard let id else { return .deepWater }
        return all.first { $0.id == id } ?? .deepWater
    }
}

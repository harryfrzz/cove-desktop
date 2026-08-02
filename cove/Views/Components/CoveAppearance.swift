import AppKit
import Observation
import SwiftUI

/// Light, dark, or whatever the system is doing.
///
/// Applied by setting `NSApp.appearance`, not by threading a `colorScheme` down
/// the view tree. AppKit draws the window's titlebar, its traffic lights, and
/// the material behind every glass control, and none of that reads a SwiftUI
/// environment value — a light shelf under a dark titlebar is the result.
///
/// The island is deliberately exempt. `NotchPanel` pins itself to `.darkAqua`,
/// which wins over the app-wide setting, because it hangs off a black camera
/// housing and has to meet it without a seam. Choosing Light here changes the
/// window; it does not put a white panel on the notch.
enum CoveAppearance: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var systemImage: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    /// `nil` means "stop overriding", which is how AppKit spells "follow the
    /// system" — not a third appearance to install.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

@MainActor
@Observable
final class CoveAppearanceStore {
    static let shared = CoveAppearanceStore()

    static let defaultsKey = "cove.appearance"

    var selection: CoveAppearance {
        didSet {
            guard selection != oldValue else { return }
            UserDefaults.standard.set(selection.rawValue, forKey: Self.defaultsKey)
            apply()
        }
    }

    private init() {
        let stored = UserDefaults.standard.string(forKey: Self.defaultsKey)
        selection = stored.flatMap(CoveAppearance.init(rawValue:)) ?? .system
    }

    /// Called at launch as well as on every change — a preference that only
    /// takes effect when you change it again is not a preference.
    func apply() {
        NSApp.appearance = selection.nsAppearance
    }
}

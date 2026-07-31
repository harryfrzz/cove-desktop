//
//  coveApp.swift
//  cove
//

import SwiftUI

/// Cove has no window of its own — it is the notch. The scene below exists
/// only because SwiftUI requires one; everything real is built by
/// `AppDelegate` and lives in `NotchController`.
@main
struct coveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // An empty settings scene: Cove's settings live in the island, next to
        // the shelf they configure. A second window for them would be a second
        // place to look.
        Settings {
            EmptyView()
        }
    }
}

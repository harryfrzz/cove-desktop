import AppKit
import SwiftUI

/// Reports a right-click (or control-click) on the view it overlays, without
/// taking anything else away from it.
///
/// SwiftUI has no secondary-click gesture on macOS — `.contextMenu` is the only
/// hook, and it insists on drawing its own menu. Cove wants to answer the click
/// itself, by lifting the item out of a blurred shelf, so the click has to be
/// caught directly.
///
/// The subtlety is `hitTest`: an overlay that accepts everything would swallow
/// the ordinary click that opens an item. This one consults the event being
/// dispatched and claims only the secondary ones, so left clicks fall straight
/// through to the button underneath.
struct SecondaryClickCatcher: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> NSView {
        CatcherView(action: action)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? CatcherView)?.action = action
    }

    private final class CatcherView: NSView {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent, isSecondary(event) else { return nil }
            return super.hitTest(point)
        }

        override func rightMouseDown(with event: NSEvent) {
            action()
        }

        /// Control-click is the other half of "secondary click" on macOS, and
        /// arrives as an ordinary left mouse down.
        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control) {
                action()
            } else {
                super.mouseDown(with: event)
            }
        }

        private func isSecondary(_ event: NSEvent) -> Bool {
            switch event.type {
            case .rightMouseDown, .rightMouseUp, .rightMouseDragged:
                true
            case .leftMouseDown, .leftMouseUp:
                event.modifierFlags.contains(.control)
            default:
                false
            }
        }
    }
}

extension View {
    /// Calls `action` with this view's frame in global space when it is
    /// secondary-clicked. The frame comes along because the caller needs to know
    /// where the thing was on screen in order to lift it from there.
    func onSecondaryClick(perform action: @escaping (CGRect) -> Void) -> some View {
        modifier(SecondaryClickModifier(action: action))
    }
}

private struct SecondaryClickModifier: ViewModifier {
    let action: (CGRect) -> Void

    @State private var frame: CGRect = .zero

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .global)
            } action: { frame = $0 }
            .overlay {
                SecondaryClickCatcher { action(frame) }
            }
    }
}

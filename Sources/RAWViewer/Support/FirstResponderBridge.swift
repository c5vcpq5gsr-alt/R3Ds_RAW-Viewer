@preconcurrency import AppKit
import SwiftUI

struct FirstResponderBridge: NSViewRepresentable {
    let requestToken: Int
    var handleKeyDown: (NSEvent) -> Bool = { _ in false }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> FocusView {
        let view = FocusView()
        view.handleKeyDown = handleKeyDown
        return view
    }

    func updateNSView(_ view: FocusView, context: Context) {
        view.handleKeyDown = handleKeyDown
        guard context.coordinator.lastRequestToken != requestToken else { return }
        context.coordinator.lastRequestToken = requestToken
        DispatchQueue.main.async { [weak view] in
            guard let view, let window = view.window else { return }
            window.makeFirstResponder(view)
        }
    }

    final class Coordinator {
        var lastRequestToken: Int?
    }

    final class FocusView: NSView {
        var handleKeyDown: (NSEvent) -> Bool = { _ in false }

        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            if !handleKeyDown(event) {
                super.keyDown(with: event)
            }
        }
    }
}

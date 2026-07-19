@preconcurrency import AppKit

@MainActor
enum WindowActions {
    static func toggleFullScreen() {
        NSApp.keyWindow?.toggleFullScreen(nil)
    }
}

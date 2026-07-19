@preconcurrency import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--self-test") {
            Task {
                let status = await SelfTestRunner.run()
                exit(status)
            }
            return
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct RAWViewerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = LibraryStore()
    @AppStorage(PreferenceKeys.theme) private var theme = ThemePreference.system.rawValue

    var body: some Scene {
        WindowGroup("RAW Viewer", id: "library") {
            ContentView(store: store)
                .preferredColorScheme(ThemePreference(rawValue: theme)?.colorScheme)
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Fotoordner hinzufügen …") {
                    store.chooseAndAddSources()
                }
                .keyboardShortcut("o", modifiers: .command)
            }

            CommandMenu("Ansicht") {
                Button("Neu einlesen") {
                    store.refresh()
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(store.selectedFolderURL == nil)

                Divider()

                Button("Vergrößern") {
                    store.zoomIn()
                }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(store.viewMode != .photo)

                Button("Verkleinern") {
                    store.zoomOut()
                }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(store.viewMode != .photo)

                Button("In Fenster einpassen") {
                    store.fitImage()
                }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(store.viewMode != .photo)
            }

        }

        Settings {
            SettingsView(store: store)
                .preferredColorScheme(ThemePreference(rawValue: theme)?.colorScheme)
        }
    }
}

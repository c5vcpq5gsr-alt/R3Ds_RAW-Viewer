@preconcurrency import AppKit
import Foundation

@MainActor
enum FolderPanelService {
    static func chooseFolders() -> [URL] {
        let panel = NSOpenPanel()
        panel.title = "Fotoordner auswählen"
        panel.message = "Wähle einen oder mehrere Ordner mit Fotos aus."
        panel.prompt = "Hinzufügen"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true
        return panel.runModal() == .OK ? panel.urls : []
    }

    static func chooseCacheDirectory(currentURL: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Cache-Speicherort auswählen"
        panel.message = "Wähle einen Ordner für Fotoindex und Vorschaubilder. Für beste Leistung empfiehlt sich eine lokale SSD."
        panel.prompt = "Als Cache verwenden"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        panel.directoryURL = currentURL
        return panel.runModal() == .OK ? panel.url?.standardizedFileURL : nil
    }
}

import Foundation

struct FolderLocationStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadFolder(in sources: [PhotoSource]) -> URL? {
        guard let path = defaults.string(forKey: PreferenceKeys.lastSelectedFolderPath) else {
            return nil
        }

        let folderURL = URL(fileURLWithPath: path).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              sources.contains(where: { source in
                  source.isAvailable && folderURL.isDescendant(of: source.url)
              }) else {
            return nil
        }
        return folderURL
    }

    func saveFolder(_ url: URL) {
        defaults.set(url.standardizedFileURL.path, forKey: PreferenceKeys.lastSelectedFolderPath)
    }

    func clearFolder(ifInside sourceURL: URL) {
        guard let path = defaults.string(forKey: PreferenceKeys.lastSelectedFolderPath) else { return }
        let savedURL = URL(fileURLWithPath: path).standardizedFileURL
        if savedURL.isDescendant(of: sourceURL) {
            defaults.removeObject(forKey: PreferenceKeys.lastSelectedFolderPath)
        }
    }
}

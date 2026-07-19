import Foundation

@MainActor
final class CacheLocationStore {
    private var accessedURL: URL?

    func load() -> URL? {
        if let data = UserDefaults.standard.data(forKey: PreferenceKeys.cacheLocationBookmark) {
            var stale = false
            if let url = try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) {
                beginAccessing(url)
                if stale { save(url) }
                return url.standardizedFileURL
            }
        }

        guard let path = UserDefaults.standard.string(forKey: PreferenceKeys.cacheLocationPath),
              !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        beginAccessing(url)
        return url
    }

    func save(_ url: URL) {
        let standardizedURL = url.standardizedFileURL
        let bookmark = try? standardizedURL.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set(standardizedURL.path, forKey: PreferenceKeys.cacheLocationPath)
        if let bookmark {
            UserDefaults.standard.set(bookmark, forKey: PreferenceKeys.cacheLocationBookmark)
        } else {
            UserDefaults.standard.removeObject(forKey: PreferenceKeys.cacheLocationBookmark)
        }
        beginAccessing(standardizedURL)
    }

    private func beginAccessing(_ url: URL) {
        if accessedURL?.standardizedFileURL == url.standardizedFileURL { return }
        accessedURL?.stopAccessingSecurityScopedResource()
        _ = url.startAccessingSecurityScopedResource()
        accessedURL = url
    }

    deinit {
        accessedURL?.stopAccessingSecurityScopedResource()
    }
}

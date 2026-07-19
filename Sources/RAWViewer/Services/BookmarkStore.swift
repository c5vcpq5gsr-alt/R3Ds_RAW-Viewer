import Foundation

struct BookmarkStore: Sendable {
    func loadSources() -> [PhotoSource] {
        guard let data = UserDefaults.standard.data(forKey: PreferenceKeys.savedSources),
              let saved = try? JSONDecoder().decode([SavedPhotoSource].self, from: data) else {
            return []
        }

        return saved.compactMap { item in
            if let bookmarkData = item.bookmarkData {
                var stale = false
                if let resolved = try? URL(
                    resolvingBookmarkData: bookmarkData,
                    options: [.withSecurityScope],
                    relativeTo: nil,
                    bookmarkDataIsStale: &stale
                ) {
                    _ = resolved.startAccessingSecurityScopedResource()
                    return PhotoSource(url: resolved, bookmarkData: bookmarkData)
                }
            }
            return PhotoSource(url: URL(fileURLWithPath: item.path), bookmarkData: item.bookmarkData)
        }
    }

    func makeSource(url: URL) -> PhotoSource {
        let data = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        _ = url.startAccessingSecurityScopedResource()
        return PhotoSource(url: url, bookmarkData: data)
    }

    func saveSources(_ sources: [PhotoSource]) {
        let saved = sources.map { SavedPhotoSource(path: $0.url.path, bookmarkData: $0.bookmarkData) }
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: PreferenceKeys.savedSources)
        }
    }
}

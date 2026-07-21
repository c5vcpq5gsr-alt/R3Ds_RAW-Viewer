import SwiftUI

enum ThemePreference: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Hell"
        case .dark: "Dunkel"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum PhotoSortOrder: String, CaseIterable, Identifiable, Sendable {
    case newestFirst
    case oldestFirst
    case filenameAscending
    case filenameDescending

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newestFirst: "Neueste zuerst"
        case .oldestFirst: "Älteste zuerst"
        case .filenameAscending: "Dateiname A–Z"
        case .filenameDescending: "Dateiname Z–A"
        }
    }

    func sort(_ photos: [PhotoAsset]) -> [PhotoAsset] {
        photos.sorted { lhs, rhs in
            switch self {
            case .newestFirst:
                if lhs.captureDate != rhs.captureDate { return lhs.captureDate > rhs.captureDate }
            case .oldestFirst:
                if lhs.captureDate != rhs.captureDate { return lhs.captureDate < rhs.captureDate }
            case .filenameAscending:
                let comparison = lhs.filename.localizedStandardCompare(rhs.filename)
                if comparison != .orderedSame { return comparison == .orderedAscending }
            case .filenameDescending:
                let comparison = lhs.filename.localizedStandardCompare(rhs.filename)
                if comparison != .orderedSame { return comparison == .orderedDescending }
            }
            return lhs.primaryURL.path.localizedStandardCompare(rhs.primaryURL.path) == .orderedAscending
        }
    }
}

enum PreferenceKeys {
    static let theme = "viewer.theme"
    static let gridTileSize = "viewer.gridTileSize"
    static let collectionLayout = "viewer.collectionLayout"
    static let sortOrder = "viewer.sortOrder"
    static let savedSources = "library.savedSources"
    static let lastSelectedFolderPath = "library.lastSelectedFolderPath"
    static let cacheLocationPath = "cache.location.path.v1"
    static let cacheLocationBookmark = "cache.location.bookmark.v1"
    static let cacheSizeLimitGB = "cache.sizeLimitGB"
    static let lmStudioServerAddress = "lmStudio.serverAddress"
    static let lmStudioModelIdentifier = "lmStudio.modelIdentifier"
    static let lmStudioAutoStartLocalServer = "lmStudio.autoStartLocalServer"
    static let lmStudioUnloadAfterAnalysis = "lmStudio.unloadAfterAnalysis"
}

import Foundation

struct PhotoAsset: Identifiable, Hashable, Sendable {
    let id: String
    let rawURL: URL?
    let companionURLs: [URL]
    let standaloneURL: URL?
    let captureDate: Date
    let modificationDate: Date
    let filename: String

    var primaryURL: URL {
        rawURL ?? standaloneURL ?? companionURLs[0]
    }

    var previewURL: URL {
        if let jpeg = companionURLs.first(where: { Self.jpegExtensions.contains($0.pathExtension.lowercased()) }) {
            return jpeg
        }
        if let heic = companionURLs.first(where: { Self.heicExtensions.contains($0.pathExtension.lowercased()) }) {
            return heic
        }
        return standaloneURL ?? rawURL ?? companionURLs[0]
    }

    var typeLabel: String {
        if rawURL != nil, !companionURLs.isEmpty {
            let companions = companionURLs.map { $0.pathExtension.uppercased() }
            return (["RAW"] + companions).joined(separator: "+")
        }
        return primaryURL.pathExtension.uppercased()
    }

    var isRAW: Bool { rawURL != nil }

    static let jpegExtensions: Set<String> = ["jpg", "jpeg"]
    static let heicExtensions: Set<String> = ["heic", "heif"]
}

enum LibraryViewMode: Sendable {
    case grid
    case photo
}

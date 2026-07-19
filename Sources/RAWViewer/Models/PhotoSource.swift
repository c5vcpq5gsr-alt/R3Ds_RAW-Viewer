import Foundation

struct PhotoSource: Identifiable, Hashable, Sendable {
    let id: String
    let url: URL
    let bookmarkData: Data?

    var name: String {
        url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
    }

    var isAvailable: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    init(url: URL, bookmarkData: Data? = nil) {
        let standardizedURL = url.standardizedFileURL
        self.url = standardizedURL
        self.bookmarkData = bookmarkData
        self.id = standardizedURL.path
    }
}

struct SavedPhotoSource: Codable, Sendable {
    let path: String
    let bookmarkData: Data?
}

import Foundation

struct IndexedPhotoFile: Hashable, Sendable {
    let url: URL
    let kind: PhotoFileKind
    let modificationDate: Date
    let byteSize: Int64
    let captureDate: Date

    var path: String { url.standardizedFileURL.path }
}

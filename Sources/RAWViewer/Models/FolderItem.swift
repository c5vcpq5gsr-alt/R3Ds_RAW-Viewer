import Foundation

struct FolderItem: Identifiable, Hashable, Sendable {
    let url: URL

    var id: String { url.standardizedFileURL.path }
    var name: String {
        url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
    }
}

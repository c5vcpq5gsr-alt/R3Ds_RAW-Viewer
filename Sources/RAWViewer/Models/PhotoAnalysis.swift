import Foundation

struct PhotoAnalysis: Equatable, Sendable {
    let photoID: String
    let sourcePath: String
    let sourceModificationDate: Date
    let modelIdentifier: String
    let keywords: [String]
    let description: String
    let analyzedAt: Date

    func matches(_ asset: PhotoAsset) -> Bool {
        photoID == asset.id
            && sourcePath == asset.primaryURL.standardizedFileURL.path
            && sourceModificationDate.timeIntervalSince1970 == asset.modificationDate.timeIntervalSince1970
    }
}

struct XMPExportRecord: Equatable, Sendable {
    let photoID: String
    let sourcePath: String
    let keywordsJSON: String
    let sidecarPath: String
    let exportedAt: Date

    func matches(keywordsJSON: String) -> Bool {
        self.keywordsJSON == keywordsJSON
    }
}

extension PhotoAnalysis {
    var keywordsJSON: String {
        guard let data = try? JSONEncoder().encode(keywords),
              let value = String(data: data, encoding: .utf8) else { return "[]" }
        return value
    }
}

struct PhotoAnalysisProgress: Sendable {
    let isRunning: Bool
    let total: Int
    let completed: Int
    let failed: Int
    let currentFilename: String?

    static let idle = PhotoAnalysisProgress(
        isRunning: false,
        total: 0,
        completed: 0,
        failed: 0,
        currentFilename: nil
    )
}

struct XMPExportProgress: Sendable {
    let isRunning: Bool
    let total: Int
    let completed: Int
    let failed: Int
    let currentFilename: String?

    static let idle = XMPExportProgress(
        isRunning: false,
        total: 0,
        completed: 0,
        failed: 0,
        currentFilename: nil
    )
}

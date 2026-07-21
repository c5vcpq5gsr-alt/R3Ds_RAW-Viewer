import Foundation

struct PhotoFolderSizeCheck: Sendable {
    let photoCount: Int
    let exceedsLimit: Bool
}

struct PhotoFolderSizeChecker: Sendable {
    static let recommendedPhotoLimit = 10_000

    func check(folderURL: URL, limit: Int = recommendedPhotoLimit) async throws -> PhotoFolderSizeCheck {
        let worker = Task.detached(priority: .userInitiated) {
            try Self.checkSynchronously(folderURL: folderURL, limit: limit)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private struct GroupCounts {
        var raw = 0
        var companion = 0
        var independent = 0

        var minimumPhotoCount: Int {
            independent + (raw > 0 ? raw : (companion > 0 ? 1 : 0))
        }

        var exactPhotoCount: Int {
            independent + (raw > 0 ? raw : companion)
        }

        mutating func add(_ kind: PhotoFileKind) {
            switch kind {
            case .raw:
                raw += 1
            case .jpeg, .heic:
                companion += 1
            case .png, .tiff:
                independent += 1
            }
        }
    }

    private static func checkSynchronously(folderURL: URL, limit: Int) throws -> PhotoFolderSizeCheck {
        try Task.checkCancellation()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw PhotoScannerError.folderUnavailable(folderURL)
        }

        let didAccessSecurityScope = folderURL.startAccessingSecurityScopedResource()
        defer {
            if didAccessSecurityScope {
                folderURL.stopAccessingSecurityScopedResource()
            }
        }

        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw PhotoScannerError.folderUnavailable(folderURL)
        }

        var groups: [String: GroupCounts] = [:]
        groups.reserveCapacity(min(limit + 1, 12_000))
        var minimumPhotoCount = 0

        for case let fileURL as URL in enumerator {
            try Task.checkCancellation()
            guard let kind = PhotoFileKind.classify(fileURL) else { continue }
            let values = try? fileURL.resourceValues(forKeys: keys)
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }

            let key = groupingKey(for: fileURL)
            var counts = groups[key] ?? GroupCounts()
            let previousMinimum = counts.minimumPhotoCount
            counts.add(kind)
            groups[key] = counts
            minimumPhotoCount += counts.minimumPhotoCount - previousMinimum

            // This lower bound cannot be reduced by a RAW file discovered later,
            // so crossing the limit is enough to warn without walking a huge tree.
            if minimumPhotoCount > limit {
                return PhotoFolderSizeCheck(photoCount: minimumPhotoCount, exceedsLimit: true)
            }
        }

        let exactPhotoCount = groups.values.reduce(0) { $0 + $1.exactPhotoCount }
        return PhotoFolderSizeCheck(photoCount: exactPhotoCount, exceedsLimit: exactPhotoCount > limit)
    }

    private static func groupingKey(for url: URL) -> String {
        let directory = url.deletingLastPathComponent().standardizedFileURL.path.lowercased()
        let stem = url.deletingPathExtension().lastPathComponent.lowercased()
        return directory + "\u{0}" + stem
    }
}

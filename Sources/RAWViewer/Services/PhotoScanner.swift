import Foundation

enum PhotoScannerError: LocalizedError {
    case folderUnavailable(URL)

    var errorDescription: String? {
        switch self {
        case .folderUnavailable(let url):
            "Der Ordner „\(url.lastPathComponent)“ ist nicht erreichbar."
        }
    }
}

struct PhotoScanResult: Sendable {
    let assets: [PhotoAsset]
    let indexedFiles: [IndexedPhotoFile]
    let reusedMetadataCount: Int
}

struct PhotoScanner: Sendable {
    private struct DiscoveredFile: Sendable {
        let url: URL
        let kind: PhotoFileKind
        let modificationDate: Date
        let byteSize: Int64
    }

    func scan(folderURL: URL) async throws -> [PhotoAsset] {
        try await scan(folderURL: folderURL, cachedFiles: []).assets
    }

    func scan(folderURL: URL, cachedFiles: [IndexedPhotoFile]) async throws -> PhotoScanResult {
        let discoveryWorker = Task.detached(priority: .userInitiated) {
            try Self.discoverSynchronously(folderURL: folderURL)
        }
        let discovered = try await withTaskCancellationHandler {
            try await discoveryWorker.value
        } onCancel: {
            discoveryWorker.cancel()
        }
        try Task.checkCancellation()

        let cachedByPath = Dictionary(uniqueKeysWithValues: cachedFiles.map { ($0.path, $0) })
        var indexed = Array<IndexedPhotoFile?>(repeating: nil, count: discovered.count)
        var pending: [(Int, DiscoveredFile)] = []
        pending.reserveCapacity(discovered.count)
        var reusedCount = 0

        for (index, file) in discovered.enumerated() {
            if let cached = cachedByPath[file.url.standardizedFileURL.path],
               cached.kind == file.kind,
               cached.byteSize == file.byteSize,
               cached.modificationDate.timeIntervalSince1970 == file.modificationDate.timeIntervalSince1970 {
                indexed[index] = cached
                reusedCount += 1
            } else {
                pending.append((index, file))
            }
        }

        try await withThrowingTaskGroup(of: (Int, IndexedPhotoFile).self) { group in
            var iterator = pending.makeIterator()
            let workerCount = min(4, pending.count)
            for _ in 0..<workerCount {
                if let item = iterator.next() {
                    group.addTask(priority: .utility) { try Self.readMetadata(for: item) }
                }
            }
            while let (index, file) = try await group.next() {
                indexed[index] = file
                if let item = iterator.next() {
                    group.addTask(priority: .utility) { try Self.readMetadata(for: item) }
                }
            }
        }
        try Task.checkCancellation()

        let files = indexed.compactMap { $0 }
        return PhotoScanResult(
            assets: try Self.buildAssets(from: files),
            indexedFiles: files,
            reusedMetadataCount: reusedCount
        )
    }

    func assets(from indexedFiles: [IndexedPhotoFile]) async throws -> [PhotoAsset] {
        let worker = Task.detached(priority: .userInitiated) {
            try Self.buildAssets(from: indexedFiles)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    func indexedFile(at url: URL, cachedFile: IndexedPhotoFile?) async throws -> IndexedPhotoFile? {
        let discovery = try await Task.detached(priority: .utility) {
            try Self.discoverSingleFile(at: url)
        }.value
        guard let discovery else { return nil }
        if let cachedFile,
           cachedFile.kind == discovery.kind,
           cachedFile.byteSize == discovery.byteSize,
           cachedFile.modificationDate.timeIntervalSince1970 == discovery.modificationDate.timeIntervalSince1970 {
            return cachedFile
        }
        return try Self.readMetadata(for: (0, discovery)).1
    }

    private static func discoverSynchronously(folderURL: URL) throws -> [DiscoveredFile] {
        try Task.checkCancellation()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw PhotoScannerError.folderUnavailable(folderURL)
        }

        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .contentModificationDateKey,
            .fileSizeKey
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw PhotoScannerError.folderUnavailable(folderURL)
        }

        var discovered: [DiscoveredFile] = []
        discovered.reserveCapacity(2_000)
        for case let fileURL as URL in enumerator {
            try Task.checkCancellation()
            guard let kind = PhotoFileKind.classify(fileURL) else { continue }
            let values = try? fileURL.resourceValues(forKeys: keys)
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
            discovered.append(DiscoveredFile(
                url: fileURL.standardizedFileURL,
                kind: kind,
                modificationDate: values?.contentModificationDate ?? .distantPast,
                byteSize: Int64(values?.fileSize ?? 0)
            ))
        }
        return discovered
    }

    private static func discoverSingleFile(at url: URL) throws -> DiscoveredFile? {
        try Task.checkCancellation()
        guard let kind = PhotoFileKind.classify(url) else { return nil }
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .contentModificationDateKey,
            .fileSizeKey
        ]
        let values = try? url.resourceValues(forKeys: keys)
        guard values?.isRegularFile == true, values?.isSymbolicLink != true else { return nil }
        return DiscoveredFile(
            url: url.standardizedFileURL,
            kind: kind,
            modificationDate: values?.contentModificationDate ?? .distantPast,
            byteSize: Int64(values?.fileSize ?? 0)
        )
    }

    private static func readMetadata(for item: (Int, DiscoveredFile)) throws -> (Int, IndexedPhotoFile) {
        try Task.checkCancellation()
        let file = item.1
        let captureDate = ImageMetadataReader.captureDate(at: file.url) ?? file.modificationDate
        try Task.checkCancellation()
        return (item.0, IndexedPhotoFile(
            url: file.url,
            kind: file.kind,
            modificationDate: file.modificationDate,
            byteSize: file.byteSize,
            captureDate: captureDate
        ))
    }

    private static func buildAssets(from files: [IndexedPhotoFile]) throws -> [PhotoAsset] {
        let groups = Dictionary(grouping: files, by: groupingKey)
        var assets: [PhotoAsset] = []
        assets.reserveCapacity(files.count)

        for candidates in groups.values {
            try Task.checkCancellation()
            let raws = candidates.filter { $0.kind == .raw }.sorted { $0.path < $1.path }
            let companions = candidates
                .filter { $0.kind == .jpeg || $0.kind == .heic }
                .sorted { lhs, rhs in
                    if lhs.kind != rhs.kind { return lhs.kind == .jpeg }
                    return lhs.path < rhs.path
                }
            let independent = candidates
                .filter { $0.kind == .png || $0.kind == .tiff }
                .sorted { $0.path < $1.path }

            if let primaryRAW = raws.first {
                assets.append(makeAsset(raw: primaryRAW, companions: companions))
                for extraRAW in raws.dropFirst() {
                    assets.append(makeAsset(raw: extraRAW, companions: []))
                }
                for candidate in independent {
                    assets.append(makeStandalone(candidate))
                }
            } else {
                for candidate in companions + independent {
                    assets.append(makeStandalone(candidate))
                }
            }
        }
        return assets
    }

    private static func groupingKey(_ file: IndexedPhotoFile) -> String {
        let directory = file.url.deletingLastPathComponent().standardizedFileURL.path.lowercased()
        let stem = file.url.deletingPathExtension().lastPathComponent.lowercased()
        return directory + "\u{0}" + stem
    }

    private static func makeAsset(raw: IndexedPhotoFile, companions: [IndexedPhotoFile]) -> PhotoAsset {
        let companionURLs = companions.map(\.url)
        let captureDate = ([raw.captureDate] + companions.map(\.captureDate)).min() ?? raw.captureDate
        let modificationDate = ([raw.modificationDate] + companions.map(\.modificationDate)).max() ?? raw.modificationDate
        return PhotoAsset(
            id: "raw:" + raw.path,
            rawURL: raw.url,
            companionURLs: companionURLs,
            standaloneURL: nil,
            captureDate: captureDate,
            modificationDate: modificationDate,
            filename: raw.url.lastPathComponent
        )
    }

    private static func makeStandalone(_ file: IndexedPhotoFile) -> PhotoAsset {
        PhotoAsset(
            id: "file:" + file.path,
            rawURL: file.kind == .raw ? file.url : nil,
            companionURLs: [],
            standaloneURL: file.kind == .raw ? nil : file.url,
            captureDate: file.captureDate,
            modificationDate: file.modificationDate,
            filename: file.url.lastPathComponent
        )
    }
}

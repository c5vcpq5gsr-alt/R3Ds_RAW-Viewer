@preconcurrency import AppKit
import Foundation
import ImageIO
@preconcurrency import QuickLookThumbnailing

struct ThumbnailCacheStats: Sendable {
    let fileCount: Int
    let byteCount: Int64

    static let empty = ThumbnailCacheStats(fileCount: 0, byteCount: 0)

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }
}

private struct ThumbnailRequestResult: @unchecked Sendable {
    let image: NSImage?
}

private actor ThumbnailRequestBroker {
    private struct Entry {
        let id: UUID
        let task: Task<ThumbnailRequestResult, Never>
    }

    private var tasks: [String: Entry] = [:]

    func result(
        for key: String,
        operation: @escaping @Sendable () async -> ThumbnailRequestResult
    ) async -> ThumbnailRequestResult {
        if let entry = tasks[key] { return await entry.task.value }
        let id = UUID()
        let task = Task { await operation() }
        tasks[key] = Entry(id: id, task: task)
        let result = await task.value
        if tasks[key]?.id == id { tasks[key] = nil }
        return result
    }

    func cancelAll() {
        for entry in tasks.values { entry.task.cancel() }
        tasks.removeAll()
    }
}

final class ThumbnailService: @unchecked Sendable {
    private let memoryCache = NSCache<NSString, NSImage>()
    private let generator = QLThumbnailGenerator.shared
    private let fileManager = FileManager.default
    private let stateLock = NSLock()
    private let requestBroker = ThumbnailRequestBroker()
    private let maintenanceQueue = DispatchQueue(label: "de.r3d.rawviewer.thumbnail-maintenance", qos: .utility)
    private var thumbnailsDirectory: URL?
    private var sizeLimitBytes: Int64 = 8 * 1_024 * 1_024 * 1_024
    private var writesSinceMaintenance = 0

    init() {
        memoryCache.countLimit = 500
        memoryCache.totalCostLimit = 256 * 1_024 * 1_024
    }

    func configure(cacheDirectory: URL, sizeLimitGB: Int) async throws {
        await requestBroker.cancelAll()
        let directory = cacheDirectory.appendingPathComponent("thumbnails", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        stateLock.withLock {
            thumbnailsDirectory = directory
            sizeLimitBytes = Int64(max(1, sizeLimitGB)) * 1_024 * 1_024 * 1_024
            writesSinceMaintenance = 0
        }
        memoryCache.removeAllObjects()
    }

    func updateSizeLimit(gigabytes: Int) {
        stateLock.lock()
        sizeLimitBytes = Int64(max(1, gigabytes)) * 1_024 * 1_024 * 1_024
        let directory = thumbnailsDirectory
        let limit = sizeLimitBytes
        stateLock.unlock()
        scheduleMaintenance(directory: directory, limit: limit)
    }

    func thumbnail(for asset: PhotoAsset, requestedPixelSize: Int, scale: CGFloat) async -> NSImage? {
        let bucket = Self.pixelBucket(for: requestedPixelSize)
        let url = asset.previewURL
        let previewModificationDate = modificationDate(for: url, fallback: asset.modificationDate)
        let key = cacheKey(url: url, modificationDate: previewModificationDate, bucket: bucket)
        if let cached = memoryCache.object(forKey: key as NSString) { return cached }

        let result = await requestBroker.result(for: key) { [weak self] in
            guard let self else { return ThumbnailRequestResult(image: nil) }
            let image = await self.loadOrGenerate(
                url: url,
                key: key,
                bucket: bucket,
                scale: scale
            )
            return ThumbnailRequestResult(image: image)
        }
        return result.image
    }

    func isThumbnailCached(for asset: PhotoAsset, requestedPixelSize: Int) -> Bool {
        let bucket = Self.pixelBucket(for: requestedPixelSize)
        let url = asset.previewURL
        let previewModificationDate = modificationDate(for: url, fallback: asset.modificationDate)
        let key = cacheKey(url: url, modificationDate: previewModificationDate, bucket: bucket)
        if memoryCache.object(forKey: key as NSString) != nil { return true }
        guard let diskURL = diskURL(for: key, bucket: bucket) else { return false }
        return fileManager.fileExists(atPath: diskURL.path)
    }

    func cachedAssetIDs(for assets: [PhotoAsset], requestedPixelSize: Int) async -> Set<PhotoAsset.ID> {
        await Task.detached(priority: .utility) { [self] in
            var result: Set<PhotoAsset.ID> = []
            result.reserveCapacity(assets.count)
            for asset in assets {
                if Task.isCancelled { break }
                if isThumbnailCached(for: asset, requestedPixelSize: requestedPixelSize) {
                    result.insert(asset.id)
                }
            }
            return result
        }.value
    }

    private func loadOrGenerate(url: URL, key: String, bucket: Int, scale: CGFloat) async -> NSImage? {
        if let cached = memoryCache.object(forKey: key as NSString) { return cached }

        let diskURL = diskURL(for: key, bucket: bucket)
        if let diskURL,
           let data = try? Data(contentsOf: diskURL, options: .mappedIfSafe),
           let cached = NSImage(data: data) {
            memoryCache.setObject(cached, forKey: key as NSString, cost: imageCost(cached))
            return cached
        }

        let effectiveScale = max(1, scale)
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: CGFloat(bucket) / effectiveScale, height: CGFloat(bucket) / effectiveScale),
            scale: effectiveScale,
            representationTypes: .thumbnail
        )
        let image: NSImage? = await withCheckedContinuation { continuation in
            generator.generateBestRepresentation(for: request) { representation, _ in
                if let image = representation?.nsImage {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(returning: Self.imageIOThumbnail(url: url, maxPixelSize: bucket))
                }
            }
        }

        guard !Task.isCancelled, let image else { return nil }
        memoryCache.setObject(image, forKey: key as NSString, cost: imageCost(image))
        if let diskURL {
            saveJPEG(image, to: diskURL)
            noteWriteAndMaintainIfNeeded()
        }
        return image
    }

    func statistics() async -> ThumbnailCacheStats {
        let directory = stateLock.withLock { thumbnailsDirectory }
        guard let directory else { return .empty }
        return await Task.detached(priority: .utility) {
            Self.calculateStatistics(in: directory)
        }.value
    }

    func clear() async {
        await requestBroker.cancelAll()
        memoryCache.removeAllObjects()
        let directory = stateLock.withLock { thumbnailsDirectory }
        guard let directory else { return }
        await Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }.value
    }

    static func pixelBucket(for requestedPixelSize: Int) -> Int {
        if requestedPixelSize <= 256 { return 256 }
        if requestedPixelSize <= 512 { return 512 }
        return 1_024
    }

    private static func imageIOThumbnail(url: URL, maxPixelSize: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private func cacheKey(url: URL, modificationDate: Date, bucket: Int) -> String {
        let source = "v2|\(url.standardizedFileURL.path)|\(modificationDate.timeIntervalSince1970)|\(bucket)"
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in source.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private func modificationDate(for url: URL, fallback: Date) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? fallback
    }

    private func diskURL(for key: String, bucket: Int) -> URL? {
        let root = stateLock.withLock { thumbnailsDirectory }
        guard let root else { return nil }
        let directory = root.appendingPathComponent(String(bucket), isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(key + ".jpg")
    }

    private func imageCost(_ image: NSImage) -> Int {
        max(1, Int(image.size.width * image.size.height * 4))
    }

    private func saveJPEG(_ image: NSImage, to url: URL) {
        guard let tiff = image.tiffRepresentation,
              let representation = NSBitmapImageRep(data: tiff),
              let jpeg = representation.representation(using: .jpeg, properties: [.compressionFactor: 0.84]) else { return }
        try? jpeg.write(to: url, options: .atomic)
    }

    private func noteWriteAndMaintainIfNeeded() {
        stateLock.lock()
        writesSinceMaintenance += 1
        let shouldRun = writesSinceMaintenance >= 50
        if shouldRun { writesSinceMaintenance = 0 }
        let directory = thumbnailsDirectory
        let limit = sizeLimitBytes
        stateLock.unlock()
        if shouldRun { scheduleMaintenance(directory: directory, limit: limit) }
    }

    private func scheduleMaintenance(directory: URL?, limit: Int64) {
        guard let directory else { return }
        maintenanceQueue.async {
            Self.trim(directory: directory, to: limit)
        }
    }

    private static func calculateStatistics(in directory: URL) -> ThumbnailCacheStats {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return .empty }
        var count = 0
        var bytes: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: keys)
            guard values?.isRegularFile == true else { continue }
            count += 1
            bytes += Int64(values?.fileSize ?? 0)
        }
        return ThumbnailCacheStats(fileCount: count, byteCount: bytes)
    }

    private static func trim(directory: URL, to limit: Int64) {
        struct Entry {
            let url: URL
            let size: Int64
            let date: Date
        }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return }
        var entries: [Entry] = []
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: keys)
            guard values?.isRegularFile == true else { continue }
            let size = Int64(values?.fileSize ?? 0)
            total += size
            entries.append(Entry(url: url, size: size, date: values?.contentModificationDate ?? .distantPast))
        }
        guard total > limit else { return }
        let target = Int64(Double(limit) * 0.9)
        for entry in entries.sorted(by: { $0.date < $1.date }) where total > target {
            if (try? FileManager.default.removeItem(at: entry.url)) != nil {
                total -= entry.size
            }
        }
    }
}

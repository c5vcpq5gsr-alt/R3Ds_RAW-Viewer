@preconcurrency import AppKit
import CoreImage
import Foundation
import ImageIO

struct RenderedImage: @unchecked Sendable {
    let image: NSImage
    let pixelSize: CGSize
}

enum ImageRenderPriority: Sendable {
    case interactive
    case background
}

private final class RenderedImageCacheEntry: @unchecked Sendable {
    let value: RenderedImage

    init(_ value: RenderedImage) {
        self.value = value
    }
}

private final class RenderedImageCache: @unchecked Sendable {
    private let storage: NSCache<NSString, RenderedImageCacheEntry>

    init() {
        storage = NSCache<NSString, RenderedImageCacheEntry>()
        storage.countLimit = 32
        storage.totalCostLimit = 256 * 1_024 * 1_024
    }

    func value(forKey key: String) -> RenderedImage? {
        storage.object(forKey: key as NSString)?.value
    }

    func store(_ image: RenderedImage, forKey key: String, cost: Int) {
        storage.setObject(RenderedImageCacheEntry(image), forKey: key as NSString, cost: cost)
    }
}

private actor RAWRenderGate {
    private var isRendering = false
    private var interactiveWaiters: [CheckedContinuation<Void, Never>] = []
    private var backgroundWaiters: [CheckedContinuation<Void, Never>] = []

    func acquire(priority: ImageRenderPriority) async {
        guard isRendering else {
            isRendering = true
            return
        }

        await withCheckedContinuation { continuation in
            switch priority {
            case .interactive:
                interactiveWaiters.append(continuation)
            case .background:
                backgroundWaiters.append(continuation)
            }
        }
    }

    func release() {
        if !interactiveWaiters.isEmpty {
            interactiveWaiters.removeFirst().resume()
        } else if !backgroundWaiters.isEmpty {
            backgroundWaiters.removeFirst().resume()
        } else {
            isRendering = false
        }
    }
}

enum FullImageError: LocalizedError {
    case unsupportedRAW
    case unreadableImage
    case renderingFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedRAW: "Dieses RAW-Format wird von macOS nicht unterstützt."
        case .unreadableImage: "Die Bilddatei konnte nicht gelesen werden."
        case .renderingFailed: "Das Bild konnte nicht gerendert werden."
        }
    }
}

struct FullImageService: Sendable {
    private static let rawRenderGate = RAWRenderGate()
    private static let renderedImageCache = RenderedImageCache()

    func render(
        url: URL,
        isRAW: Bool,
        maxPixelSize: Int,
        priority: ImageRenderPriority = .interactive
    ) async throws -> RenderedImage {
        let cacheKey = Self.cacheKey(url: url, isRAW: isRAW, maxPixelSize: maxPixelSize)
        if let cacheKey, let cached = Self.renderedImageCache.value(forKey: cacheKey) {
            return cached
        }

        if isRAW {
            await Self.rawRenderGate.acquire(priority: priority)
            do {
                try Task.checkCancellation()
                if let cacheKey, let cached = Self.renderedImageCache.value(forKey: cacheKey) {
                    await Self.rawRenderGate.release()
                    return cached
                }
                let image = try await renderInWorker(url: url, isRAW: true, maxPixelSize: maxPixelSize)
                Self.store(image, forKey: cacheKey)
                await Self.rawRenderGate.release()
                return image
            } catch {
                await Self.rawRenderGate.release()
                throw error
            }
        }

        let image = try await renderInWorker(url: url, isRAW: false, maxPixelSize: maxPixelSize)
        Self.store(image, forKey: cacheKey)
        return image
    }

    private func renderInWorker(url: URL, isRAW: Bool, maxPixelSize: Int) async throws -> RenderedImage {
        let worker = Task.detached(priority: .userInitiated) {
            try autoreleasepool {
                try Task.checkCancellation()
                let image = isRAW
                    ? try Self.renderRAW(url: url, maxPixelSize: maxPixelSize)
                    : try Self.renderStandard(url: url, maxPixelSize: maxPixelSize)
                try Task.checkCancellation()
                return image
            }
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private static func cacheKey(url: URL, isRAW: Bool, maxPixelSize: Int) -> String? {
        guard maxPixelSize <= 2_048 else { return nil }
        let modificationDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return "\(isRAW ? "raw" : "standard")|\(url.standardizedFileURL.path)|\(modificationDate?.timeIntervalSince1970 ?? 0)|\(maxPixelSize)"
    }

    private static func store(_ image: RenderedImage, forKey key: String?) {
        guard let key else { return }
        let pixelCount = max(1, Int(image.pixelSize.width * image.pixelSize.height))
        renderedImageCache.store(image, forKey: key, cost: pixelCount * 4)
    }

    private static func renderRAW(url: URL, maxPixelSize: Int) throws -> RenderedImage {
        guard let filter = CIRAWFilter(imageURL: url), let output = filter.outputImage else {
            throw FullImageError.unsupportedRAW
        }
        return try render(ciImage: output, maxPixelSize: maxPixelSize)
    }

    private static func renderStandard(url: URL, maxPixelSize: Int) throws -> RenderedImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary) else { throw FullImageError.unreadableImage }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? maxPixelSize
        let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? maxPixelSize
        let requestedSize = max(1, min(maxPixelSize, max(width, height)))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: requestedSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw FullImageError.unreadableImage
        }
        let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        return RenderedImage(image: nsImage, pixelSize: CGSize(width: image.width, height: image.height))
    }

    private static func render(ciImage: CIImage, maxPixelSize: Int) throws -> RenderedImage {
        let extent = ciImage.extent.integral
        guard extent.width > 0, extent.height > 0 else { throw FullImageError.renderingFailed }
        let longest = max(extent.width, extent.height)
        let scale = min(1, CGFloat(maxPixelSize) / longest)
        let output = scale < 1 ? ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) : ciImage
        let outputExtent = output.extent.integral
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let cgImage = context.createCGImage(output, from: outputExtent) else {
            throw FullImageError.renderingFailed
        }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        return RenderedImage(image: image, pixelSize: CGSize(width: cgImage.width, height: cgImage.height))
    }
}

@preconcurrency import AppKit
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum PhotoExportFormat: String, CaseIterable, Sendable {
    case original
    case jpeg
    case png
    case tiff

    var title: String {
        switch self {
        case .original: "Original"
        case .jpeg: "JPEG"
        case .png: "PNG"
        case .tiff: "TIFF"
        }
    }

    fileprivate func outputURL(for asset: PhotoAsset) -> URL {
        let source = asset.primaryURL
        guard self != .original else { return source }
        return source.deletingPathExtension().appendingPathExtension(filenameExtension)
    }

    fileprivate var filenameExtension: String {
        switch self {
        case .original: ""
        case .jpeg: "jpg"
        case .png: "png"
        case .tiff: "tiff"
        }
    }

    fileprivate func contentType(for asset: PhotoAsset) -> UTType {
        switch self {
        case .original: UTType(filenameExtension: asset.primaryURL.pathExtension) ?? .data
        case .jpeg: .jpeg
        case .png: .png
        case .tiff: .tiff
        }
    }
}

enum PhotoExportError: LocalizedError {
    case encodingFailed
    case unsupportedRAW

    var errorDescription: String? {
        switch self {
        case .encodingFailed: "Die Bilddatei konnte nicht exportiert werden."
        case .unsupportedRAW: "Dieses RAW-Format kann von macOS nicht konvertiert werden."
        }
    }
}

struct PhotoExportService: Sendable {
    @MainActor
    func chooseDestinationAndExport(_ asset: PhotoAsset, format: PhotoExportFormat) async throws {
        let suggestedURL = format.outputURL(for: asset)
        let panel = NSSavePanel()
        panel.title = format == .original ? "Original exportieren" : "Als \(format.title) exportieren"
        panel.prompt = "Exportieren"
        panel.nameFieldStringValue = suggestedURL.lastPathComponent
        panel.allowedContentTypes = [format.contentType(for: asset)]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        try await write(asset, format: format, to: destination)
    }

    func write(_ asset: PhotoAsset, format: PhotoExportFormat, to destination: URL) async throws {
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            if format == .original {
                try Self.copyReplacingExisting(from: asset.primaryURL, to: destination)
            } else {
                try Self.encode(asset: asset, format: format, to: destination)
            }
            try Task.checkCancellation()
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private static func copyReplacingExisting(from source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        if source.standardizedFileURL == destination.standardizedFileURL { return }
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".raw-viewer-\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporary) }
        try fileManager.copyItem(at: source, to: temporary)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
    }

    private static func encode(asset: PhotoAsset, format: PhotoExportFormat, to destination: URL) throws {
        let sourceURL = asset.rawURL ?? asset.primaryURL
        let cgImage: CGImage
        let properties: [CFString: Any]

        if asset.rawURL != nil {
            guard let filter = CIRAWFilter(imageURL: sourceURL), let output = filter.outputImage else {
                throw PhotoExportError.unsupportedRAW
            }
            let extent = output.extent.integral
            guard extent.width > 0, extent.height > 0,
                  let rendered = CIContext(options: [.cacheIntermediates: false]).createCGImage(output, from: extent)
            else { throw PhotoExportError.encodingFailed }
            cgImage = rendered
            properties = imageProperties(at: sourceURL)
        } else {
            guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, [
                kCGImageSourceShouldCache: false
            ] as CFDictionary) else { throw PhotoExportError.encodingFailed }
            let sourceProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
            let width = (sourceProperties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 1
            let height = (sourceProperties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 1
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(width, height),
                kCGImageSourceShouldCacheImmediately: true
            ]
            guard let rendered = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                throw PhotoExportError.encodingFailed
            }
            cgImage = rendered
            properties = sourceProperties
        }

        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".raw-viewer-\(UUID().uuidString).\(format.filenameExtension)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let imageDestination = CGImageDestinationCreateWithURL(
            temporary as CFURL,
            format.contentType(for: asset).identifier as CFString,
            1,
            nil
        ) else { throw PhotoExportError.encodingFailed }

        var outputProperties = properties
        outputProperties[kCGImagePropertyOrientation] = 1
        if format == .jpeg {
            outputProperties[kCGImageDestinationLossyCompressionQuality] = 0.92
        }
        CGImageDestinationAddImage(imageDestination, cgImage, outputProperties as CFDictionary)
        guard CGImageDestinationFinalize(imageDestination) else { throw PhotoExportError.encodingFailed }

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
    }

    private static func imageProperties(at url: URL) -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary) else { return [:] }
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
    }
}

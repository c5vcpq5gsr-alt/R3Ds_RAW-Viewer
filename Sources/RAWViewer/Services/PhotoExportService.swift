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
    case sidecarAlreadyExists(String)

    var errorDescription: String? {
        switch self {
        case .encodingFailed: "Die Bilddatei konnte nicht exportiert werden."
        case .unsupportedRAW: "Dieses RAW-Format kann von macOS nicht konvertiert werden."
        case .sidecarAlreadyExists(let filename):
            "Neben dem Exportziel existiert bereits \(filename). Das Sidecar wurde nicht überschrieben; wähle bitte einen anderen Zielnamen."
        }
    }
}

struct PhotoExportItem: Sendable {
    let asset: PhotoAsset
    let rotation: PhotoRotation
}

struct BatchPhotoExportFailure: Sendable {
    let filename: String
    let message: String
}

struct BatchPhotoExportResult: Sendable {
    let exportedCount: Int
    let failures: [BatchPhotoExportFailure]
}

struct PhotoExportService: Sendable {
    @MainActor
    func chooseDestinationAndExport(
        _ asset: PhotoAsset,
        format: PhotoExportFormat,
        rotation: PhotoRotation = .none
    ) async throws -> Bool {
        let suggestedURL = format.outputURL(for: asset)
        let panel = NSSavePanel()
        panel.title = format == .original ? "Original exportieren" : "Als \(format.title) exportieren"
        panel.prompt = "Exportieren"
        panel.nameFieldStringValue = suggestedURL.lastPathComponent
        panel.allowedContentTypes = [format.contentType(for: asset)]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let destination = panel.url else { return false }
        try await write(asset, format: format, rotation: rotation, to: destination)
        return true
    }

    @MainActor
    func chooseDirectoryAndExport(
        _ items: [PhotoExportItem],
        format: PhotoExportFormat,
        progress: @MainActor (Int, Int) -> Void
    ) async throws -> BatchPhotoExportResult? {
        guard !items.isEmpty else { return BatchPhotoExportResult(exportedCount: 0, failures: []) }
        let panel = NSOpenPanel()
        panel.title = "\(items.count) Fotos als \(format.title) exportieren"
        panel.message = "Wähle einen Zielordner. Vorhandene Dateien werden nicht überschrieben."
        panel.prompt = "Ordner auswählen"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let directory = panel.url else { return nil }

        var reservedPaths: Set<String> = []
        var failures: [BatchPhotoExportFailure] = []
        var exportedCount = 0
        for item in items {
            try Task.checkCancellation()
            let destination = Self.availableDestinationURL(
                for: item.asset,
                format: format,
                in: directory,
                reservedPaths: &reservedPaths
            )
            do {
                try await write(item.asset, format: format, rotation: item.rotation, to: destination)
                exportedCount += 1
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures.append(BatchPhotoExportFailure(
                    filename: item.asset.filename,
                    message: error.localizedDescription
                ))
            }
            progress(exportedCount, failures.count)
        }
        return BatchPhotoExportResult(exportedCount: exportedCount, failures: failures)
    }

    func write(
        _ asset: PhotoAsset,
        format: PhotoExportFormat,
        rotation: PhotoRotation = .none,
        to destination: URL
    ) async throws {
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            if format == .original {
                try Self.copyOriginalWithSidecar(asset: asset, to: destination)
            } else {
                try Self.encode(asset: asset, format: format, rotation: rotation, to: destination)
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

    private static func copyOriginalWithSidecar(asset: PhotoAsset, to destination: URL) throws {
        let sourceSidecar = proprietaryRAWSidecarURL(for: asset)
        let destinationSidecar = sourceSidecar.map { _ in
            destination.deletingPathExtension().appendingPathExtension("xmp")
        }
        if let sourceSidecar, let destinationSidecar,
           FileManager.default.fileExists(atPath: sourceSidecar.path),
           sourceSidecar.standardizedFileURL != destinationSidecar.standardizedFileURL,
           FileManager.default.fileExists(atPath: destinationSidecar.path) {
            throw PhotoExportError.sidecarAlreadyExists(destinationSidecar.lastPathComponent)
        }

        try copyReplacingExisting(from: asset.primaryURL, to: destination)
        if let sourceSidecar, let destinationSidecar,
           FileManager.default.fileExists(atPath: sourceSidecar.path) {
            try copyReplacingExisting(from: sourceSidecar, to: destinationSidecar)
        }
    }

    private static func proprietaryRAWSidecarURL(for asset: PhotoAsset) -> URL? {
        guard let rawURL = asset.rawURL, rawURL.pathExtension.lowercased() != "dng" else { return nil }
        return rawURL.deletingPathExtension().appendingPathExtension("xmp")
    }

    static func availableDestinationURL(
        for asset: PhotoAsset,
        format: PhotoExportFormat,
        in directory: URL,
        reservedPaths: inout Set<String>
    ) -> URL {
        let suggestedName = format.outputURL(for: asset).lastPathComponent
        let suggestedURL = URL(fileURLWithPath: suggestedName)
        let baseName = suggestedURL.deletingPathExtension().lastPathComponent
        let pathExtension = suggestedURL.pathExtension
        var suffix = 1

        while true {
            let filename: String
            if suffix == 1 {
                filename = suggestedName
            } else if pathExtension.isEmpty {
                filename = "\(baseName) (\(suffix))"
            } else {
                filename = "\(baseName) (\(suffix)).\(pathExtension)"
            }
            let candidate = directory.appendingPathComponent(filename)
            let candidatePath = candidate.standardizedFileURL.path
            let sidecarPath = batchSidecarPath(for: asset, format: format, destination: candidate)
            let imageConflict = reservedPaths.contains(candidatePath)
                || FileManager.default.fileExists(atPath: candidatePath)
            let sidecarConflict = sidecarPath.map {
                reservedPaths.contains($0) || FileManager.default.fileExists(atPath: $0)
            } ?? false
            if !imageConflict, !sidecarConflict {
                reservedPaths.insert(candidatePath)
                if let sidecarPath { reservedPaths.insert(sidecarPath) }
                return candidate
            }
            suffix += 1
        }
    }

    private static func batchSidecarPath(
        for asset: PhotoAsset,
        format: PhotoExportFormat,
        destination: URL
    ) -> String? {
        guard format == .original,
              let sourceSidecar = proprietaryRAWSidecarURL(for: asset),
              FileManager.default.fileExists(atPath: sourceSidecar.path) else { return nil }
        return destination.deletingPathExtension()
            .appendingPathExtension("xmp")
            .standardizedFileURL.path
    }

    private static func encode(
        asset: PhotoAsset,
        format: PhotoExportFormat,
        rotation: PhotoRotation,
        to destination: URL
    ) throws {
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
            cgImage = try rotated(rendered, by: rotation)
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
            cgImage = try rotated(rendered, by: rotation)
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

    private static func rotated(_ image: CGImage, by rotation: PhotoRotation) throws -> CGImage {
        guard rotation != .none else { return image }
        let oriented = CIImage(cgImage: image).oriented(forExifOrientation: rotation.exifOrientationForPixelRotation)
        let extent = oriented.extent.integral
        guard extent.width > 0, extent.height > 0,
              let output = CIContext(options: [.cacheIntermediates: false]).createCGImage(oriented, from: extent)
        else { throw PhotoExportError.encodingFailed }
        return output
    }

    private static func imageProperties(at url: URL) -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary) else { return [:] }
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
    }
}

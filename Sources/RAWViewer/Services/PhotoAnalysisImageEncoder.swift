@preconcurrency import AppKit
import Foundation

enum PhotoAnalysisImageEncoder {
    static func jpegData(for asset: PhotoAsset, fullImageService: FullImageService) async throws -> Data {
        let rendered = try await fullImageService.render(
            url: asset.previewURL,
            isRAW: asset.previewURL == asset.rawURL,
            maxPixelSize: 1_600,
            priority: .background
        )
        return try await Task.detached(priority: .utility) {
            guard let tiff = rendered.image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.84]) else {
                throw FullImageError.renderingFailed
            }
            return jpeg
        }.value
    }
}

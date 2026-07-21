@preconcurrency import AppKit
import SwiftUI

struct RotatedPhotoImage: View {
    let image: NSImage
    let rotation: PhotoRotation
    let unrotatedSize: CGSize

    var body: some View {
        let displaySize = rotation.displaySize(for: unrotatedSize)
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .frame(width: unrotatedSize.width, height: unrotatedSize.height)
            .rotationEffect(.degrees(rotation.degrees))
            .frame(width: displaySize.width, height: displaySize.height)
    }
}

struct RotatedFittedPhotoImage: View {
    let image: NSImage
    let rotation: PhotoRotation

    var body: some View {
        GeometryReader { geometry in
            let pixelSize = ThumbnailService.pixelSize(of: image) ?? CGSize(width: 1, height: 1)
            let displaySize = rotation.displaySize(for: pixelSize)
            let scale = min(
                geometry.size.width / max(1, displaySize.width),
                geometry.size.height / max(1, displaySize.height)
            )
            RotatedPhotoImage(
                image: image,
                rotation: rotation,
                unrotatedSize: CGSize(
                    width: max(1, pixelSize.width * scale),
                    height: max(1, pixelSize.height * scale)
                )
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

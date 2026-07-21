import Foundation

enum PhotoRotation: Int, CaseIterable, Codable, Sendable {
    case none = 0
    case right = 1
    case upsideDown = 2
    case left = 3

    var degrees: Double { Double(rawValue * 90) }

    var swapsAxes: Bool { rawValue % 2 == 1 }

    var title: String {
        switch self {
        case .none: "Keine Korrektur"
        case .right: "90° rechts"
        case .upsideDown: "180°"
        case .left: "90° links"
        }
    }

    func rotatedRight() -> PhotoRotation {
        PhotoRotation(rawValue: (rawValue + 1) % 4) ?? .none
    }

    func rotatedLeft() -> PhotoRotation {
        PhotoRotation(rawValue: (rawValue + 3) % 4) ?? .none
    }

    func displaySize(for size: CGSize) -> CGSize {
        swapsAxes ? CGSize(width: size.height, height: size.width) : size
    }

    func adjustedAspectRatio(_ ratio: Double) -> Double {
        guard swapsAxes, ratio > 0 else { return ratio }
        return 1 / ratio
    }

    func applying(toTIFFOrientation orientation: Int) -> Int {
        var result = (1...8).contains(orientation) ? orientation : 1
        for _ in 0..<rawValue {
            result = Self.rotateTIFFOrientationRight(result)
        }
        return result
    }

    var exifOrientationForPixelRotation: Int32 {
        switch self {
        case .none: 1
        case .right: 6
        case .upsideDown: 3
        case .left: 8
        }
    }

    private static func rotateTIFFOrientationRight(_ orientation: Int) -> Int {
        switch orientation {
        case 1: 6
        case 6: 3
        case 3: 8
        case 8: 1
        case 2: 7
        case 7: 4
        case 4: 5
        case 5: 2
        default: 6
        }
    }
}

struct PhotoRotationEdit: Equatable, Sendable {
    let photoID: PhotoAsset.ID
    let sourcePath: String
    var rotation: PhotoRotation
    var originalXMPOrientation: Int?
    var isOriginalXMPOrientationKnown: Bool
    var isXMPSyncPending: Bool
    var xmpSyncError: String?
    var updatedAt: Date
}

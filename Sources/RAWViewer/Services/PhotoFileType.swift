import Foundation
import UniformTypeIdentifiers

enum PhotoFileKind: String, Sendable {
    case raw
    case jpeg
    case heic
    case png
    case tiff

    static let fallbackRAWExtensions: Set<String> = [
        "3fr", "arw", "cr2", "cr3", "crw", "dcr", "dng", "erf", "fff",
        "iiq", "kdc", "mef", "mos", "mrw", "nef", "nrw", "orf", "pef",
        "raf", "raw", "rw2", "rwl", "sr2", "srf", "srw", "x3f"
    ]

    static func classify(_ url: URL) -> PhotoFileKind? {
        let fileExtension = url.pathExtension.lowercased()
        if let type = UTType(filenameExtension: fileExtension), type.conforms(to: .rawImage) {
            return .raw
        }
        if fallbackRAWExtensions.contains(fileExtension) { return .raw }
        if PhotoAsset.jpegExtensions.contains(fileExtension) { return .jpeg }
        if PhotoAsset.heicExtensions.contains(fileExtension) { return .heic }
        if fileExtension == "png" { return .png }
        if fileExtension == "tif" || fileExtension == "tiff" { return .tiff }
        return nil
    }
}

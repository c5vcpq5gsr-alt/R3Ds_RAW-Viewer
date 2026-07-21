import SwiftUI

struct PhotoContextMenu: View {
    let asset: PhotoAsset
    @ObservedObject var store: LibraryStore

    private var actionCount: Int { store.actionPhotoCount(containing: asset) }

    var body: some View {
        Button(actionCount == 1 ? "Nach links drehen" : "\(actionCount) Fotos nach links drehen") {
            store.rotate(asset, direction: .left)
        }

        Button(actionCount == 1 ? "Nach rechts drehen" : "\(actionCount) Fotos nach rechts drehen") {
            store.rotate(asset, direction: .right)
        }

        Button(actionCount == 1 ? "Ausrichtung zurücksetzen" : "Ausrichtung für \(actionCount) Fotos zurücksetzen") {
            store.resetRotation(asset)
        }
        .disabled(!store.photosForAction(containing: asset).contains { store.rotationEdit(for: $0) != nil })

        if store.rotationEdit(for: asset)?.isXMPSyncPending == true {
            Button("XMP erneut synchronisieren") {
                store.retryXMPSync(asset)
            }
        }

        Divider()

        Button(actionCount == 1 ? "In Ordner anzeigen" : "\(actionCount) Fotos in Ordner anzeigen") {
            store.revealInFinder(asset)
        }

        Menu(actionCount == 1 ? "Exportieren" : "\(actionCount) Fotos exportieren") {
            ForEach(PhotoExportFormat.allCases, id: \.self) { format in
                Button(actionCount == 1 ? format.title + " …" : "Als \(format.title) …") {
                    store.export(asset, as: format)
                }
            }
        }
        .disabled(store.isExporting)
    }
}

extension View {
    func photoContextMenu(asset: PhotoAsset, store: LibraryStore) -> some View {
        contextMenu {
            PhotoContextMenu(asset: asset, store: store)
        }
    }
}

import SwiftUI

struct PhotoContextMenu: View {
    let asset: PhotoAsset
    @ObservedObject var store: LibraryStore

    var body: some View {
        Button("In Ordner anzeigen") {
            store.revealInFinder(asset)
        }

        Menu("Exportieren") {
            ForEach(PhotoExportFormat.allCases, id: \.self) { format in
                Button(format.title + " …") {
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

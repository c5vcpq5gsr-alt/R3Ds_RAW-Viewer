import SwiftUI

struct DetailView: View {
    @ObservedObject var store: LibraryStore

    var body: some View {
        Group {
            if store.selectedFolderURL == nil {
                WelcomeView(store: store)
            } else if store.viewMode == .photo, let photo = store.selectedPhoto {
                PhotoDetailView(asset: photo, store: store)
            } else {
                PhotoGridView(store: store)
            }
        }
        .navigationTitle(navigationTitle)
    }

    private var navigationTitle: String {
        if store.viewMode == .photo, let photo = store.selectedPhoto {
            return photo.filename
        }
        return store.selectedFolderURL?.lastPathComponent ?? "RAW Viewer"
    }
}

private struct WelcomeView: View {
    @ObservedObject var store: LibraryStore

    var body: some View {
        ContentUnavailableView {
            Label("RAW Viewer", systemImage: "photo.on.rectangle.angled")
        } description: {
            Text("Wähle links einen Fotoordner oder füge eine neue Quelle hinzu.")
        } actions: {
            Button("Fotoordner hinzufügen") {
                store.chooseAndAddSources()
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

import SwiftUI

struct ContentView: View {
    @ObservedObject var store: LibraryStore

    var body: some View {
        Group {
            if store.isCacheConfigured {
                libraryView
            } else {
                CacheSetupView(store: store)
            }
        }
        .frame(minWidth: 920, minHeight: 620)
        .task {
            await store.prepareCacheIfNeeded()
        }
        .task {
            await store.checkLMStudioAtLaunch()
        }
        .alert(item: $store.actionError) { error in
            Alert(
                title: Text(error.title),
                message: Text(error.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private var libraryView: some View {
        NavigationSplitView {
            SidebarView(store: store)
                .navigationSplitViewColumnWidth(min: 210, ideal: 270, max: 420)
        } detail: {
            DetailView(store: store)
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    store.chooseAndAddSources()
                } label: {
                    Label("Fotoordner hinzufügen", systemImage: "folder.badge.plus")
                }
                .help("Fotoordner hinzufügen (⌘O)")

                Button {
                    store.refresh()
                } label: {
                    Label("Neu einlesen", systemImage: "arrow.clockwise")
                }
                .disabled(store.selectedFolderURL == nil || store.isScanning)
                .help("Ausgewählten Ordner neu einlesen (⌘R)")

            }

            if store.viewMode == .photo {
                ToolbarItemGroup(placement: .principal) {
                    Button(action: store.closePhoto) {
                        Image(systemName: "square.grid.2x2")
                    }
                    .keyboardShortcut(.escape, modifiers: [])
                    .help("Zurück zum Grid (Esc)")

                    Button(action: store.showPreviousPhoto) {
                        Image(systemName: "chevron.left")
                    }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .disabled(!store.canShowPrevious)
                    .help("Vorheriges Foto (←)")

                    Button(action: store.showNextPhoto) {
                        Image(systemName: "chevron.right")
                    }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .disabled(!store.canShowNext)
                    .help("Nächstes Foto (→)")
                }

                ToolbarItemGroup(placement: .primaryAction) {
                    Button("Einpassen", action: store.fitImage)
                        .help("In Fenster einpassen (⌘0)")
                    Button("100 %", action: store.actualSize)

                    Button(action: store.zoomOut) {
                        Image(systemName: "minus.magnifyingglass")
                    }
                    Slider(
                        value: Binding(
                            get: { store.viewerZoom },
                            set: {
                                store.viewerFitsWindow = false
                                store.viewerZoom = $0
                            }
                        ),
                        in: 0.25...8
                    )
                    .frame(width: 110)
                    .help("Zoom \(Int(store.viewerZoom * 100)) %")
                    Button(action: store.zoomIn) {
                        Image(systemName: "plus.magnifyingglass")
                    }

                    Button(action: WindowActions.toggleFullScreen) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                    .help("Vollbild")
                }
            }
        }
    }
}

private struct CacheSetupView: View {
    @ObservedObject var store: LibraryStore

    var body: some View {
        ContentUnavailableView {
            Label("Cache-Speicherort festlegen", systemImage: "externaldrive.badge.plus")
        } description: {
            VStack(spacing: 8) {
                Text("RAW Viewer speichert dort den Fotoindex und Vorschaubilder. Deine Originaldateien werden nicht verändert.")
                Text("Für beste Leistung empfiehlt sich ein Ordner auf einer lokalen SSD.")
                if let error = store.cacheSetupError {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }
            .frame(maxWidth: 560)
        } actions: {
            Button("Cache-Ordner auswählen …") {
                Task { await store.chooseCacheLocation() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.isConfiguringCache)
        }
    }
}

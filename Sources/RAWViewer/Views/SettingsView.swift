import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: LibraryStore
    @AppStorage(PreferenceKeys.theme) private var theme = ThemePreference.system.rawValue
    @AppStorage(PreferenceKeys.gridTileSize) private var gridTileSize = 180.0
    @AppStorage(PreferenceKeys.cacheSizeLimitGB) private var cacheSizeLimitGB = 8
    @State private var confirmation: CacheConfirmation?

    var body: some View {
        TabView {
            appearanceSettings
                .tabItem {
                    Label("Darstellung", systemImage: "paintbrush")
                }

            cacheSettings
                .tabItem {
                    Label("Cache", systemImage: "externaldrive")
                }

            LMStudioSettingsView(store: store)
                .tabItem {
                    Label("KI-Analyse", systemImage: "sparkles")
                }
        }
        .frame(width: 620, height: 440)
        .alert(item: $confirmation) { confirmation in
            switch confirmation {
            case .clearThumbnails:
                Alert(
                    title: Text("Vorschaubilder löschen?"),
                    message: Text("Die Vorschaubilder werden bei Bedarf neu erzeugt. Deine Originalfotos bleiben unverändert."),
                    primaryButton: .destructive(Text("Löschen")) {
                        Task { await store.clearThumbnailCache() }
                    },
                    secondaryButton: .cancel()
                )
            case .rebuildIndex:
                Alert(
                    title: Text("Fotoindex neu aufbauen?"),
                    message: Text("Alle Metadaten werden erneut eingelesen. Vorschaubilder und Originalfotos bleiben erhalten."),
                    primaryButton: .destructive(Text("Neu aufbauen")) {
                        Task { await store.rebuildIndex() }
                    },
                    secondaryButton: .cancel()
                )
            case .deletePeople:
                Alert(
                    title: Text("Alte Personendaten löschen?"),
                    message: Text("Alle früher gespeicherten Namen, Gesichtszuordnungen und biometrischen Embeddings werden aus dem Cache gelöscht. Originalfotos, normale KI-Schlagwörter und Vorschaubilder bleiben erhalten."),
                    primaryButton: .destructive(Text("Altbestand löschen")) {
                        Task { await store.deleteAllPersonData() }
                    },
                    secondaryButton: .cancel()
                )
            }
        }
        .task {
            await store.updateCacheStatistics()
        }
    }

    private var appearanceSettings: some View {
        Form {
            Picker("Erscheinungsbild", selection: $theme) {
                ForEach(ThemePreference.allCases) { option in
                    Text(option.title).tag(option.rawValue)
                }
            }
            .pickerStyle(.segmented)

            LabeledContent("Standard-Gridgröße") {
                HStack {
                    Slider(value: $gridTileSize, in: 110...340, step: 10)
                        .frame(width: 220)
                    Text("\(Int(gridTileSize)) pt")
                        .monospacedDigit()
                        .frame(width: 55, alignment: .trailing)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var cacheSettings: some View {
        Form {
            Section("Speicherort") {
                LabeledContent("Cache-Ordner") {
                    Text(store.cacheDirectoryURL?.path ?? "Nicht festgelegt")
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .frame(maxWidth: 330, alignment: .trailing)
                }

                HStack {
                    Spacer()
                    Button("Im Finder zeigen") {
                        store.revealCacheInFinder()
                    }
                    .disabled(store.cacheDirectoryURL == nil)
                    Button("Ändern …") {
                        Task { await store.chooseCacheLocation() }
                    }
                }
            }

            Section("Begrenzung und Belegung") {
                Picker("Maximale Thumbnail-Größe", selection: $cacheSizeLimitGB) {
                    Text("2 GB").tag(2)
                    Text("5 GB").tag(5)
                    Text("8 GB").tag(8)
                    Text("10 GB").tag(10)
                    Text("20 GB").tag(20)
                }
                .onChange(of: cacheSizeLimitGB) { _, value in
                    store.updateCacheSizeLimit(value)
                }

                LabeledContent("Fotoindex", value: "\(store.cacheStats.indexedFileCount) Dateien")
                LabeledContent("KI-Analysen", value: "\(store.cacheStats.analyzedPhotoCount) Fotos")
                if store.cacheStats.storedPersonDataCount > 0 {
                    LabeledContent("Alte Personendaten", value: "\(store.cacheStats.storedPersonDataCount) Einträge")
                }
                LabeledContent(
                    "Vorschaubilder",
                    value: "\(store.cacheStats.thumbnailFileCount) Dateien · \(store.cacheStats.formattedThumbnailSize)"
                )
            }

            Section {
                HStack {
                    Button("Vorschaubilder löschen …", role: .destructive) {
                        confirmation = .clearThumbnails
                    }
                    if store.cacheStats.storedPersonDataCount > 0 {
                        Button("Alte Personendaten löschen …", role: .destructive) {
                            confirmation = .deletePeople
                        }
                    }
                    Spacer()
                    Button("Index neu aufbauen …") {
                        confirmation = .rebuildIndex
                    }
                }
            } footer: {
                Text("Beim Wechsel des Speicherorts wird dort ein neuer Index verwendet. Originaldateien werden niemals verschoben oder verändert.")
            }
        }
        .formStyle(.grouped)
    }
}

private enum CacheConfirmation: String, Identifiable {
    case clearThumbnails
    case rebuildIndex
    case deletePeople

    var id: String { rawValue }
}

import SwiftUI

struct SidebarView: View {
    @ObservedObject var store: LibraryStore

    var body: some View {
        VSplitView {
            sourceList
                .frame(minHeight: 240)

            TabView {
                PhotoMetadataView(
                    asset: store.selectedPhoto,
                    rotationEdit: store.selectedPhoto.flatMap(store.rotationEdit(for:))
                )
                    .tabItem {
                        Label("Metadaten", systemImage: "info.circle")
                    }

                PhotoKeywordsView(store: store)
                    .tabItem {
                        Label("Schlagwörter", systemImage: "tag")
                    }
            }
            .frame(minHeight: 220, idealHeight: 330, maxHeight: 500)
        }
        .navigationTitle("Ordner")
    }

    private var sourceList: some View {
        List {
            if store.sources.isEmpty {
                ContentUnavailableView {
                    Label("Keine Fotoordner", systemImage: "folder")
                } description: {
                    Text("Füge einen oder mehrere Ordner hinzu.")
                } actions: {
                    Button("Ordner hinzufügen") {
                        store.chooseAndAddSources()
                    }
                    .disabled(store.isCheckingSourceSize)
                }
            } else {
                Section("Fotoquellen") {
                    ForEach(store.sources) { source in
                        FolderTreeRow(
                            item: FolderItem(url: source.url),
                            isRoot: true,
                            isAvailable: source.isAvailable,
                            store: store
                        )
                        .contextMenu {
                            Button("Quelle entfernen", role: .destructive) {
                                if store.selectedFolderURL?.path != source.url.path {
                                    store.selectFolder(source.url)
                                }
                                store.removeSelectedSource()
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 8) {
                Button {
                    store.chooseAndAddSources()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .disabled(store.isCheckingSourceSize)
                .help("Fotoquelle hinzufügen")

                if store.isCheckingSourceSize {
                    ProgressView()
                        .controlSize(.small)
                        .help("Fotoanzahl einschließlich Unterordnern wird geprüft")
                }

                Button {
                    store.removeSelectedSource()
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(.borderless)
                .disabled(store.selectedSource == nil)
                .help("Ausgewählte Quelle entfernen")

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }
}

private struct FolderTreeRow: View {
    let item: FolderItem
    let isRoot: Bool
    let isAvailable: Bool
    @ObservedObject var store: LibraryStore
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            if store.loadingFolders.contains(item.id) {
                ProgressView()
                    .controlSize(.small)
                    .padding(.leading, 20)
            }
            if let children = store.children(of: item.url) {
                ForEach(children) { child in
                    FolderTreeRow(item: child, isRoot: false, isAvailable: true, store: store)
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isAvailable ? (isRoot ? "externaldrive" : "folder") : "externaldrive.badge.exclamationmark")
                    .foregroundStyle(isAvailable ? Color.secondary : Color.orange)
                    .frame(width: 16)
                Text(item.name)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 2)
            .padding(.horizontal, 4)
            .background(
                store.selectedFolderURL?.standardizedFileURL.path == item.id
                    ? Color.accentColor.opacity(0.18)
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: 5)
            )
            .onTapGesture {
                store.selectFolder(item.url)
            }
        }
        .onChange(of: isExpanded) { _, expanded in
            if expanded, isAvailable {
                store.loadChildren(of: item.url)
            }
        }
        .onChange(of: store.selectedFolderURL) { _, _ in
            expandTowardSelectedFolder()
        }
        .onAppear {
            expandTowardSelectedFolder()
            if (isRoot || isExpanded), isAvailable {
                store.loadChildren(of: item.url)
            }
        }
    }

    private func expandTowardSelectedFolder() {
        guard isAvailable,
              let selectedFolderURL = store.selectedFolderURL,
              selectedFolderURL.standardizedFileURL != item.url.standardizedFileURL,
              selectedFolderURL.isDescendant(of: item.url) else { return }
        isExpanded = true
        store.loadChildren(of: item.url)
    }
}

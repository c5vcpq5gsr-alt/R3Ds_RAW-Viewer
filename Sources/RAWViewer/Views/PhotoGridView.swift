@preconcurrency import AppKit
import SwiftUI

struct PhotoGridView: View {
    @ObservedObject var store: LibraryStore
    @AppStorage(PreferenceKeys.gridTileSize) private var tileSize = 180.0
    @State private var folderActionConfirmation: FolderActionConfirmation?

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: tileSize, maximum: tileSize), spacing: 14)]
    }

    var body: some View {
        VStack(spacing: 0) {
            gridHeader
            Divider()
            content
        }
        .onAppear {
            store.prepareThumbnails(tileSize: tileSize)
        }
        .onChange(of: tileSize) { _, value in
            store.prepareThumbnails(tileSize: value)
        }
        .searchable(text: $store.searchText, prompt: "Dateiname oder Schlagwort")
        .confirmationDialog(
            folderActionConfirmation?.title(store: store) ?? "Ordner bearbeiten",
            isPresented: Binding(
                get: { folderActionConfirmation != nil },
                set: { if !$0 { folderActionConfirmation = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let confirmation = folderActionConfirmation {
                Button(confirmation.buttonTitle) {
                    switch confirmation {
                    case .analyze: store.analyzeMissingPhotosInSelectedFolder()
                    case .exportXMP: store.exportPendingXMPInSelectedFolder()
                    }
                    folderActionConfirmation = nil
                }
            }
            Button("Abbrechen", role: .cancel) {
                folderActionConfirmation = nil
            }
        } message: {
            if let confirmation = folderActionConfirmation {
                Text(confirmation.message(store: store))
            }
        }
    }

    private var gridHeader: some View {
        HStack(spacing: 12) {
            if store.isScanning {
                ProgressView()
                    .controlSize(.small)
                Text("Fotos werden eingelesen …")
                    .foregroundStyle(.secondary)
            } else {
                Text(photoCountLabel)
                    .foregroundStyle(.secondary)
            }

            ThumbnailProgressView(state: store.thumbnailPreparation)

            Spacer()

            analysisControls

            Picker("Sortierung", selection: Binding(
                get: { store.sortOrder },
                set: { store.setSortOrder($0) }
            )) {
                ForEach(PhotoSortOrder.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 170)

            Image(systemName: "rectangle.grid.3x3")
                .foregroundStyle(.secondary)
            Slider(value: $tileSize, in: 110...340, step: 10)
                .frame(width: 130)
                .help("Gridgröße")
            Image(systemName: "rectangle.grid.1x2")
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if let error = store.scanError {
            ContentUnavailableView("Ordner nicht lesbar", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if store.visiblePhotos.isEmpty, !store.isScanning, !store.searchText.isEmpty {
            ContentUnavailableView.search(text: store.searchText)
        } else if store.photos.isEmpty, !store.isScanning {
            ContentUnavailableView(
                "Keine Fotos gefunden",
                systemImage: "photo",
                description: Text("Dieser Ordner und seine Unterordner enthalten keine unterstützten Bilddateien.")
            )
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(store.visiblePhotos) { photo in
                            ThumbnailCell(
                                asset: photo,
                                tileSize: tileSize,
                                isSelected: store.selectedPhotoID == photo.id,
                                service: store.thumbnailService
                            )
                            .id(photo.id)
                            .onTapGesture(count: 2) {
                                store.openPhoto(photo)
                            }
                            .simultaneousGesture(TapGesture().onEnded {
                                store.selectedPhotoID = photo.id
                            })
                            .photoContextMenu(asset: photo, store: store)
                        }
                    }
                    .padding(16)
                }
                .task {
                    guard let selectedPhotoID = store.selectedPhotoID else { return }
                    await Task.yield()
                    guard store.viewMode == .grid,
                          store.selectedPhotoID == selectedPhotoID else { return }
                    proxy.scrollTo(selectedPhotoID, anchor: .center)
                }
            }
        }
    }

    private var photoCountLabel: String {
        if store.searchText.isEmpty {
            return "\(store.photos.count) \(store.photos.count == 1 ? "Foto" : "Fotos")"
        }
        return "\(store.visiblePhotos.count) von \(store.photos.count) Fotos"
    }

    @ViewBuilder
    private var analysisControls: some View {
        let progress = store.analysisProgress
        if progress.isRunning {
            HStack(spacing: 7) {
                ProgressView(value: Double(progress.completed + progress.failed), total: Double(max(1, progress.total)))
                    .frame(width: 80)
                Text("Analyse \(progress.completed + progress.failed) / \(progress.total)")
                    .font(.caption)
                    .monospacedDigit()
                Button {
                    store.cancelPhotoAnalysis()
                } label: {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(.borderless)
                .help("Fotoanalyse abbrechen")
            }
        } else if store.xmpExportProgress.isRunning {
            let xmpProgress = store.xmpExportProgress
            HStack(spacing: 7) {
                ProgressView(
                    value: Double(xmpProgress.completed + xmpProgress.failed),
                    total: Double(max(1, xmpProgress.total))
                )
                .frame(width: 80)
                Text("XMP \(xmpProgress.completed + xmpProgress.failed) / \(xmpProgress.total)")
                    .font(.caption)
                    .monospacedDigit()
                Button {
                    store.cancelXMPExport()
                } label: {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(.borderless)
                .help("XMP-Export abbrechen")
            }
        } else {
            Menu {
                Button {
                    folderActionConfirmation = .analyze
                } label: {
                    Label(
                        "\(store.missingAnalysisCountInSelectedFolder) fehlende Fotos analysieren",
                        systemImage: "sparkles"
                    )
                }
                .disabled(store.missingAnalysisCountInSelectedFolder == 0)

                Divider()

                Button {
                    folderActionConfirmation = .exportXMP
                } label: {
                    Label(
                        xmpActionLabel,
                        systemImage: "tag.square"
                    )
                }
                .disabled(store.xmpEligibleAnalysisCountInSelectedFolder == 0)
            } label: {
                Label("Aktueller Ordner", systemImage: "folder")
            }
            .disabled(store.photosInSelectedFolderScope.isEmpty)
            .help("Fotos im ausgewählten Ordner und allen Unterordnern bearbeiten")
        }

        Image(systemName: lmStudioStatusSymbol)
            .foregroundStyle(lmStudioStatusColor)
            .help(store.lmStudioStatus.message)
    }

    private var lmStudioStatusSymbol: String {
        switch store.lmStudioStatus.connection {
        case .unknown, .checking: "circle.dotted"
        case .unavailable: "exclamationmark.triangle.fill"
        case .ready: store.lmStudioStatus.loadedInstanceID == nil ? "server.rack" : "checkmark.circle.fill"
        }
    }

    private var xmpActionLabel: String {
        let pending = store.pendingXMPExportCountInSelectedFolder
        return pending == 0 ? "XMP-Sidecars prüfen" : "\(pending) XMP-Sidecars aktualisieren"
    }

    private var lmStudioStatusColor: Color {
        switch store.lmStudioStatus.connection {
        case .unknown, .checking: .secondary
        case .unavailable: .orange
        case .ready: .green
        }
    }
}

@MainActor
private enum FolderActionConfirmation {
    case analyze
    case exportXMP

    var buttonTitle: String {
        switch self {
        case .analyze: "Analyse starten"
        case .exportXMP: "XMP schreiben"
        }
    }

    func title(store: LibraryStore) -> String {
        switch self {
        case .analyze: "Ordner „\(store.selectedFolderName)“ analysieren?"
        case .exportXMP: "XMP-Sidecars in „\(store.selectedFolderName)“ aktualisieren?"
        }
    }

    func message(store: LibraryStore) -> String {
        switch self {
        case .analyze:
            "\(store.missingAnalysisCountInSelectedFolder) noch nicht analysierte Fotos im Ordner und allen Unterordnern werden nacheinander verarbeitet. Der Vorgang kann abgebrochen und später fortgesetzt werden."
        case .exportXMP:
            "Die Sidecars von \(store.xmpEligibleAnalysisCountInSelectedFolder) analysierten RAW-Fotos im Ordner und allen Unterordnern werden geprüft. Neue, fehlende oder durch eine erneute Analyse veraltete XMP-Dateien werden neben den Originalen angelegt beziehungsweise sicher ergänzt. Vorhandene Lightroom-Metadaten bleiben erhalten."
        }
    }
}

private struct ThumbnailCell: View {
    let asset: PhotoAsset
    let tileSize: Double
    let isSelected: Bool
    let service: ThumbnailService
    @State private var image: NSImage?
    @State private var didFail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color(nsColor: .controlBackgroundColor))
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .padding(4)
                } else if didFail {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.title2)
                        .foregroundStyle(.orange)
                        .help("Für diese Datei konnte keine Vorschau erstellt werden.")
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(width: tileSize, height: tileSize)

            HStack(spacing: 6) {
                Text(asset.filename)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 2)
                Text(asset.typeLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
            .font(.caption)
        }
        .padding(5)
        .background(
            isSelected ? Color.accentColor.opacity(0.15) : Color.clear,
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        }
        .contentShape(Rectangle())
        .task(id: "\(asset.id)|\(Int(tileSize))") {
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            didFail = false
            let loadedImage = await service.thumbnail(
                for: asset,
                requestedPixelSize: max(256, Int(tileSize * scale)),
                scale: scale
            )
            guard !Task.isCancelled else { return }
            image = loadedImage
            didFail = loadedImage == nil
        }
        .accessibilityLabel(asset.filename)
    }
}

private struct ThumbnailProgressView: View {
    @ObservedObject var state: ThumbnailPreparationState

    var body: some View {
        let progress = state.progress
        Group {
            switch progress.phase {
            case .idle:
                EmptyView()
            case .checking:
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Vorschauen werden geprüft …")
                }
                .foregroundStyle(.secondary)
            case .rendering:
                HStack(spacing: 7) {
                    ProgressView(value: progress.progressValue, total: Double(max(1, progress.total)))
                        .frame(width: 86)
                    Text("Vorschauen: \(progress.ready) / \(progress.total)")
                        .monospacedDigit()
                    if progress.failed > 0 {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .help("\(progress.failed) Vorschauen konnten nicht erstellt werden.")
                    }
                }
                .foregroundStyle(.secondary)
            case .complete:
                if progress.failed == 0 {
                    Label("Alle Vorschauen erstellt", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Label(
                        "\(progress.ready) / \(progress.total) Vorschauen",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                    .help("\(progress.failed) Vorschauen konnten nicht erstellt werden.")
                }
            }
        }
        .font(.caption)
    }
}

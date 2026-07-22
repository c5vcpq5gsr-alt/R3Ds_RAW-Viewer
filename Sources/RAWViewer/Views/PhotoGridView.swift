@preconcurrency import AppKit
import SwiftUI

struct PhotoGridView: View {
    @ObservedObject var store: LibraryStore
    @AppStorage(PreferenceKeys.gridTileSize) private var tileSize = 180.0
    @AppStorage(PreferenceKeys.collectionLayout) private var collectionLayout = PhotoCollectionLayout.grid
    @State private var folderActionConfirmation: FolderActionConfirmation?
    @State private var aspectRatios: [PhotoAsset.ID: Double] = [:]
    @State private var aspectRatioRevision = 0
    @State private var justifiedRows: [JustifiedPhotoLayout.Row] = []
    @State private var justifiedAvailableWidth = 0.0
    @State private var focusRequestToken = 0

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
            restoreKeyboardFocus()
        }
        .onChange(of: tileSize) { _, value in
            store.prepareThumbnails(tileSize: value)
        }
        .onChange(of: collectionLayout) { _, _ in
            restoreKeyboardFocus()
        }
        .onChange(of: store.viewMode) { previousMode, newMode in
            guard previousMode == .photo, newMode == .grid else { return }
            restoreKeyboardFocus()
        }
        .task(id: aspectRatioTaskID) {
            await loadAspectRatiosIfNeeded()
        }
        .task(id: justifiedRowsTaskID) {
            await rebuildJustifiedRows()
        }
        .background {
            FirstResponderBridge(
                requestToken: focusRequestToken,
                isEnabled: store.viewMode == .grid,
                handleKeyDown: handleKeyDown
            )
                .frame(width: 0, height: 0)
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
                    case .analyzeMissing: store.analyzeMissingPhotosInSelectedFolder()
                    case .regenerateKeywords: store.regenerateKeywordsInSelectedFolder()
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
            PhotoExportProgressView(progress: store.photoExportProgress)

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
                .help(collectionLayout == .grid ? "Rastergröße" : "Zeilenhöhe der Blocksatzansicht")
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
            collectionContent
        }
    }

    @ViewBuilder
    private var collectionContent: some View {
        switch collectionLayout {
        case .grid:
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(store.visiblePhotos) { photo in
                        interactiveCell(photo, imageWidth: tileSize, imageHeight: tileSize)
                    }
                }
                .padding(16)
            }
        case .justified:
            GeometryReader { geometry in
                let availableWidth = max(1, geometry.size.width - 32)
                ZStack {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: JustifiedPhotoLayout.rowSpacing) {
                            ForEach(justifiedRows) { row in
                                HStack(alignment: .top, spacing: JustifiedPhotoLayout.itemSpacing) {
                                    ForEach(row.items) { item in
                                        interactiveCell(
                                            item.photo,
                                            imageWidth: max(1, item.width - JustifiedPhotoLayout.cellHorizontalInset),
                                            imageHeight: row.imageHeight
                                        )
                                    }
                                }
                            }
                        }
                        .padding(16)
                    }
                    if justifiedRows.isEmpty, !store.visiblePhotos.isEmpty {
                        ProgressView("Blocksatz wird aufgebaut …")
                    }
                }
                .task(id: Int((availableWidth * 10).rounded())) {
                    justifiedAvailableWidth = availableWidth
                }
            }
        }
    }

    private func interactiveCell(_ photo: PhotoAsset, imageWidth: Double, imageHeight: Double) -> some View {
        ThumbnailCell(
            asset: photo,
            rotation: store.rotation(for: photo),
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            requestedThumbnailSize: tileSize,
            showsTypeLabel: collectionLayout == .grid,
            isSelected: store.isPhotoSelected(photo),
            service: store.thumbnailService,
            onAspectRatioLoaded: { ratio in
                guard collectionLayout == .justified,
                      aspectRatios[photo.id] != ratio else { return }
                aspectRatios[photo.id] = ratio
                aspectRatioRevision &+= 1
            }
        )
        .id(photo.id)
        .onTapGesture(count: 2) {
            store.openPhoto(photo)
        }
        .simultaneousGesture(
            TapGesture().onEnded {
                store.selectPhoto(photo, modifiers: currentSelectionModifiers)
                restoreKeyboardFocus()
            }
        )
        .photoContextMenu(asset: photo, store: store)
    }

    private var photoListTaskID: String {
        let photos = store.visiblePhotos
        return [
            store.selectedFolderURL?.standardizedFileURL.path ?? "",
            String(photos.count),
            photos.first?.id ?? "",
            photos.last?.id ?? "",
            store.sortOrder.rawValue,
            store.searchText
        ].joined(separator: "|")
    }

    private var aspectRatioTaskID: String {
        "\(collectionLayout.rawValue)|\(Int(tileSize))|\(photoListTaskID)"
    }

    private var justifiedRowsTaskID: String {
        "\(collectionLayout.rawValue)|\(Int(tileSize))|\(Int(justifiedAvailableWidth.rounded()))|\(aspectRatioRevision)|\(photoListTaskID)"
    }

    private func loadAspectRatiosIfNeeded() async {
        guard collectionLayout == .justified else { return }
        let missingPhotos = Array(
            store.visiblePhotos
                .lazy
                .filter { aspectRatios[$0.id] == nil }
                .prefix(512)
        )
        guard !missingPhotos.isEmpty else { return }
        let thumbnailService = store.thumbnailService
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let requestedPixelSize = max(256, Int(tileSize * scale))

        let batchSize = 128
        var batchStart = 0
        while batchStart < missingPhotos.count, !Task.isCancelled {
            let batchEnd = min(batchStart + batchSize, missingPhotos.count)
            let batch = Array(missingPhotos[batchStart..<batchEnd])
            let rotations = Dictionary(uniqueKeysWithValues: batch.map { ($0.id, store.rotation(for: $0)) })
            let worker = Task.detached(priority: .utility) {
                var loaded: [PhotoAsset.ID: Double] = [:]
                loaded.reserveCapacity(batch.count)
                for photo in batch {
                    guard !Task.isCancelled else { break }
                    if let ratio = thumbnailService.cachedAspectRatio(
                        for: photo,
                        requestedPixelSize: requestedPixelSize
                    ) {
                        loaded[photo.id] = rotations[photo.id, default: .none].adjustedAspectRatio(ratio)
                    }
                }
                return loaded
            }
            let loaded = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled else { return }
            if !loaded.isEmpty {
                aspectRatios.merge(loaded) { _, new in new }
                aspectRatioRevision &+= 1
            }
            batchStart = batchEnd
            await Task.yield()
        }
    }

    private func rebuildJustifiedRows() async {
        guard collectionLayout == .justified, justifiedAvailableWidth > 1 else { return }
        do {
            try await Task.sleep(for: .milliseconds(75))
        } catch {
            return
        }

        let photos = store.visiblePhotos
        let ratios = aspectRatios
        let width = justifiedAvailableWidth
        let height = tileSize
        let worker = Task.detached(priority: .userInitiated) {
            JustifiedPhotoLayout.rows(
                photos: photos,
                aspectRatios: ratios,
                availableWidth: width,
                targetImageHeight: height
            )
        }
        let rows = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        guard !Task.isCancelled, collectionLayout == .justified else { return }
        justifiedRows = rows
    }

    private func restoreKeyboardFocus() {
        guard store.viewMode == .grid else { return }
        Task { @MainActor in
            await Task.yield()
            guard store.viewMode == .grid else { return }
            focusRequestToken &+= 1
        }
    }

    private var currentSelectionModifiers: PhotoSelectionModifiers {
        let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: PhotoSelectionModifiers = []
        if flags.contains(.command) { modifiers.insert(.toggle) }
        if flags.contains(.shift) { modifiers.insert(.range) }
        return modifiers
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if event.keyCode == 53, modifiers.isEmpty {
            store.handleEscapeKey()
            return true
        }
        guard store.viewMode == .grid else { return false }
        if event.keyCode == 0, modifiers == .command {
            store.selectAllVisiblePhotos()
            return true
        }
        return false
    }

    private var photoCountLabel: String {
        let selectionPrefix = store.selectedPhotoCount > 0
            ? "\(store.selectedPhotoCount) ausgewählt · "
            : ""
        if store.searchText.isEmpty {
            return selectionPrefix + "\(store.photos.count) \(store.photos.count == 1 ? "Foto" : "Fotos")"
        }
        return selectionPrefix + "\(store.visiblePhotos.count) von \(store.photos.count) Fotos"
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
                    folderActionConfirmation = .analyzeMissing
                } label: {
                    Label(
                        "\(store.missingAnalysisCountInSelectedFolder) fehlende Fotos analysieren",
                        systemImage: "sparkles"
                    )
                }
                .disabled(store.missingAnalysisCountInSelectedFolder == 0)

                Button {
                    folderActionConfirmation = .regenerateKeywords
                } label: {
                    Label(
                        "Schlagwörter für alle Fotos neu erzeugen …",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                }

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
    case analyzeMissing
    case regenerateKeywords
    case exportXMP

    var buttonTitle: String {
        switch self {
        case .analyzeMissing: "Analyse starten"
        case .regenerateKeywords: "Neu erzeugen"
        case .exportXMP: "XMP schreiben"
        }
    }

    func title(store: LibraryStore) -> String {
        switch self {
        case .analyzeMissing: "Ordner „\(store.selectedFolderName)“ analysieren?"
        case .regenerateKeywords: "Alle Schlagwörter in „\(store.selectedFolderName)“ neu erzeugen?"
        case .exportXMP: "XMP-Sidecars in „\(store.selectedFolderName)“ aktualisieren?"
        }
    }

    func message(store: LibraryStore) -> String {
        switch self {
        case .analyzeMissing:
            "\(store.missingAnalysisCountInSelectedFolder) noch nicht analysierte Fotos im Ordner und allen Unterordnern werden nacheinander verarbeitet. Der Vorgang kann abgebrochen und später fortgesetzt werden."
        case .regenerateKeywords:
            "Die lokale KI-Analyse für alle \(store.photosInSelectedFolderScope.count) Fotos im Ordner und allen Unterordnern wird erneut ausgeführt. Erfolgreiche Ergebnisse ersetzen die bisher gespeicherten Schlagwörter und Bildbeschreibungen im Cache. Originalfotos und vorhandene XMP-Dateien bleiben unverändert, bis der XMP-Export ausdrücklich gestartet wird."
        case .exportXMP:
            "Die Sidecars von \(store.xmpEligibleAnalysisCountInSelectedFolder) analysierten RAW-Fotos im Ordner und allen Unterordnern werden geprüft. Neue, fehlende oder durch eine erneute Analyse veraltete XMP-Dateien werden neben den Originalen angelegt beziehungsweise sicher ergänzt. Vorhandene Lightroom-Metadaten bleiben erhalten."
        }
    }
}

struct JustifiedPhotoLayout {
    static let itemSpacing = 8.0
    static let rowSpacing = 8.0
    static let cellHorizontalInset = 10.0

    struct Item: Identifiable, Sendable {
        let photo: PhotoAsset
        let width: Double

        var id: PhotoAsset.ID { photo.id }
    }

    struct Row: Identifiable, Sendable {
        let items: [Item]
        let imageHeight: Double

        var id: PhotoAsset.ID { items[0].id }
    }

    static func rows(
        photos: [PhotoAsset],
        aspectRatios: [PhotoAsset.ID: Double],
        availableWidth: Double,
        targetImageHeight: Double
    ) -> [Row] {
        guard !photos.isEmpty, availableWidth > cellHorizontalInset else { return [] }

        var result: [Row] = []
        var pending: [(photo: PhotoAsset, ratio: Double)] = []
        var naturalWidth = 0.0

        for photo in photos {
            guard !Task.isCancelled else { return [] }
            let ratio = min(6, max(0.2, aspectRatios[photo.id] ?? 4.0 / 3.0))
            pending.append((photo, ratio))
            naturalWidth += ratio * targetImageHeight + cellHorizontalInset
            naturalWidth += pending.count == 1 ? 0 : itemSpacing

            if naturalWidth >= availableWidth {
                result.append(makeRow(from: pending, availableWidth: availableWidth, maximumHeight: nil))
                pending.removeAll(keepingCapacity: true)
                naturalWidth = 0
            }
        }

        if !pending.isEmpty {
            result.append(makeRow(
                from: pending,
                availableWidth: availableWidth,
                maximumHeight: targetImageHeight
            ))
        }
        return result
    }

    private static func makeRow(
        from entries: [(photo: PhotoAsset, ratio: Double)],
        availableWidth: Double,
        maximumHeight: Double?
    ) -> Row {
        let fixedWidth = Double(entries.count) * cellHorizontalInset
            + Double(max(0, entries.count - 1)) * itemSpacing
        let ratioTotal = entries.reduce(0) { $0 + $1.ratio }
        let fittedHeight = max(1, (availableWidth - fixedWidth) / max(0.2, ratioTotal))
        let imageHeight = maximumHeight.map { min($0, fittedHeight) } ?? fittedHeight
        let items = entries.map { entry in
            Item(photo: entry.photo, width: entry.ratio * imageHeight + cellHorizontalInset)
        }
        return Row(items: items, imageHeight: imageHeight)
    }
}

private struct ThumbnailCell: View {
    let asset: PhotoAsset
    let rotation: PhotoRotation
    let imageWidth: Double
    let imageHeight: Double
    let requestedThumbnailSize: Double
    let showsTypeLabel: Bool
    let isSelected: Bool
    let service: ThumbnailService
    let onAspectRatioLoaded: (Double) -> Void
    @State private var image: NSImage?
    @State private var didFail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color(nsColor: .controlBackgroundColor))
                if let image {
                    RotatedFittedPhotoImage(image: image, rotation: rotation)
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
            .frame(width: imageWidth, height: imageHeight)

            HStack(spacing: 6) {
                Text(asset.filename)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: showsTypeLabel ? .leading : .center)
                if showsTypeLabel {
                    Text(asset.typeLabel)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
            }
            .font(.caption)
        }
        .frame(width: imageWidth, alignment: .leading)
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
        .task(id: "\(asset.id)|\(Int(imageWidth))|\(Int(imageHeight))|\(rotation.rawValue)") {
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            didFail = false
            let loadedImage = await service.thumbnail(
                for: asset,
                requestedPixelSize: max(256, Int(requestedThumbnailSize * scale)),
                scale: scale
            )
            guard !Task.isCancelled else { return }
            image = loadedImage
            didFail = loadedImage == nil
            if let loadedImage,
               let ratio = ThumbnailService.pixelAspectRatio(of: loadedImage) {
                onAspectRatioLoaded(rotation.adjustedAspectRatio(ratio))
            }
        }
        .accessibilityLabel(asset.filename)
        .accessibilityValue(isSelected ? "Ausgewählt" : "Nicht ausgewählt")
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

private struct PhotoExportProgressView: View {
    let progress: PhotoExportProgress

    var body: some View {
        Group {
            switch progress.phase {
            case .idle:
                EmptyView()
            case .exporting:
                HStack(spacing: 7) {
                    ProgressView(
                        value: Double(progress.completed + progress.failed),
                        total: Double(max(1, progress.total))
                    )
                    .frame(width: 76)
                    Text("Export: \(progress.completed + progress.failed) / \(progress.total)")
                        .monospacedDigit()
                }
                .foregroundStyle(.secondary)
            case .complete:
                if progress.failed == 0 {
                    Label("\(progress.completed) exportiert", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Label(
                        "\(progress.completed) exportiert, \(progress.failed) fehlgeschlagen",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                }
            }
        }
        .font(.caption)
    }
}

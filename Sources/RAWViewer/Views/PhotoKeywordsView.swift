import SwiftUI

struct PhotoKeywordsView: View {
    @ObservedObject var store: LibraryStore

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "tag")
                    .foregroundStyle(.secondary)
                Text("Schlagwörter")
                    .font(.headline)
                Spacer()
                if store.analyzingPhotoID == store.selectedPhoto?.id {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.bar)

            Divider()

            Group {
                if let asset = store.selectedPhoto {
                    photoContent(asset)
                } else {
                    Text("Markiere ein Bild, um seine Schlagwörter anzuzeigen.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Schlagwörter")
    }

    @ViewBuilder
    private func photoContent(_ asset: PhotoAsset) -> some View {
        let analysis = store.analysesByPhotoID[asset.id]

        if analysis == nil {
            ContentUnavailableView {
                Label("Noch nicht analysiert", systemImage: "sparkles")
            } description: {
                Text("LM Studio kann eine Bildbeschreibung und Schlagwörter erzeugen.")
            } actions: {
                Button("Foto analysieren") {
                    store.analyzeSelectedPhoto()
                }
                .disabled(store.analysisProgress.isRunning)
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    keywordGrid(asset)

                    if let analysis, !analysis.description.isEmpty {
                        Divider()
                        Text(analysis.description)
                            .font(.caption)
                            .textSelection(.enabled)
                    }

                    Divider()

                    if let analysis {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Modell: \(analysis.modelIdentifier)")
                            Text("Analysiert: \(analysis.analyzedAt.formatted(date: .abbreviated, time: .shortened))")
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }

                    Button("KI neu analysieren") {
                        store.analyzeSelectedPhoto()
                    }
                    .disabled(store.analysisProgress.isRunning)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func keywordGrid(_ asset: PhotoAsset) -> some View {
        let keywords = store.effectiveKeywords(for: asset)
        return Group {
            if keywords.isEmpty {
                Text("Noch keine Schlagwörter")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 82), spacing: 6)], alignment: .leading, spacing: 6) {
                    ForEach(keywords, id: \.self) { keyword in
                        Text(keyword)
                            .font(.caption)
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                    }
                }
            }
        }
    }
}

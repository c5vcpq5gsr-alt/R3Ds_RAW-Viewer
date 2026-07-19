import SwiftUI

struct PhotoMetadataView: View {
    let asset: PhotoAsset?
    @State private var metadata: PhotoMetadata?
    @State private var isLoading = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                Text("Metadaten")
                    .font(.headline)
                Spacer()
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.bar)

            Divider()

            Group {
                if asset == nil {
                    placeholder("Markiere ein Bild, um seine Metadaten anzuzeigen.")
                } else if let metadata, metadata.isEmpty {
                    placeholder("Für dieses Bild sind keine Metadaten verfügbar.")
                } else if let metadata {
                    ScrollView {
                        Grid(alignment: .leading, horizontalSpacing: 9, verticalSpacing: 4) {
                            ForEach(Array(metadata.rows.enumerated()), id: \.offset) { _, row in
                                GridRow(alignment: .firstTextBaseline) {
                                    Text(row.label + ":")
                                        .fontWeight(.semibold)
                                        .frame(maxWidth: .infinity, alignment: .trailing)
                                    Text(row.value)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity)
                    }
                } else {
                    placeholder("")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: asset?.id) {
            metadata = nil
            guard let asset else {
                isLoading = false
                return
            }
            isLoading = true
            let loaded = await Task.detached(priority: .utility) {
                ImageMetadataReader.metadata(for: asset)
            }.value
            guard !Task.isCancelled else { return }
            metadata = loaded
            isLoading = false
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Metadaten")
    }

    private func placeholder(_ message: String) -> some View {
        Text(message)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding()
    }
}

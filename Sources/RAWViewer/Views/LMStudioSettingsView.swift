import SwiftUI

struct LMStudioSettingsView: View {
    @ObservedObject var store: LibraryStore
    @AppStorage(PreferenceKeys.lmStudioServerAddress) private var serverAddress = "http://127.0.0.1:1234"
    @AppStorage(PreferenceKeys.lmStudioModelIdentifier) private var modelIdentifier = ""
    @AppStorage(PreferenceKeys.lmStudioAutoStartLocalServer) private var autoStartLocalServer = true
    @AppStorage(PreferenceKeys.lmStudioUnloadAfterAnalysis) private var unloadAfterAnalysis = true

    var body: some View {
        Form {
            Section("LM-Studio-Server") {
                TextField("Server-Adresse", text: $serverAddress, prompt: Text("http://127.0.0.1:1234"))
                    .textFieldStyle(.roundedBorder)

                Toggle("Lokalen Server beim App-Start automatisch starten", isOn: $autoStartLocalServer)

                LabeledContent("Status") {
                    HStack(spacing: 7) {
                        if store.isLMStudioBusy {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Image(systemName: statusSymbol)
                            .foregroundStyle(statusColor)
                        Text(store.lmStudioStatus.message)
                            .multilineTextAlignment(.trailing)
                    }
                    .frame(maxWidth: 390, alignment: .trailing)
                }

                HStack {
                    Spacer()
                    Button("Verbindung prüfen") {
                        Task { await store.refreshLMStudioStatus(startLocalIfNeeded: true) }
                    }
                    .disabled(store.isLMStudioBusy)
                }
            }

            Section {
                TextField("Modell-ID", text: $modelIdentifier, prompt: Text("z. B. google/gemma-3-12b"))
                    .textFieldStyle(.roundedBorder)

                if !visionModels.isEmpty {
                    Picker("Verfügbare Vision-Modelle", selection: $modelIdentifier) {
                        Text("Modell auswählen …").tag("")
                        ForEach(visionModels) { model in
                            Text(model.displayName).tag(model.key)
                        }
                    }
                }

                Toggle("Von RAW Viewer geladene Modelle nach der Analyse entladen", isOn: $unloadAfterAnalysis)

                HStack {
                    Spacer()
                    Button("Modell entladen") {
                        Task { await store.unloadConfiguredLMStudioModel() }
                    }
                    .disabled(store.isLMStudioBusy || store.lmStudioStatus.loadedInstanceID == nil)
                    Button(store.lmStudioStatus.loadedInstanceID == nil ? "Modell laden" : "Mit Profil neu laden") {
                        Task { await store.loadConfiguredLMStudioModel() }
                    }
                    .disabled(store.isLMStudioBusy || modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } header: {
                Text("Bildmodell")
            } footer: {
                Text("Für die Fotoanalyse ist ein in LM Studio installiertes Modell mit Vision-Unterstützung erforderlich. RAW Viewer lädt es mit 16.384 Kontext-Tokens und verwendet das präzise Fotoanalyse-Profil automatisch. Bei einer Rack-Adresse muss der entfernte Server bereits als Dienst laufen und im Netzwerk abgesichert sein.")
            }
        }
        .formStyle(.grouped)
        .onChange(of: serverAddress) { _, _ in
            store.lmStudioConfigurationDidChange()
        }
        .onChange(of: modelIdentifier) { _, _ in
            store.lmStudioConfigurationDidChange()
        }
    }

    private var visionModels: [LMStudioModel] {
        store.lmStudioStatus.models
            .filter(\.supportsVision)
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    private var statusSymbol: String {
        switch store.lmStudioStatus.connection {
        case .unknown, .checking: "circle.dotted"
        case .unavailable: "exclamationmark.triangle.fill"
        case .ready: "checkmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch store.lmStudioStatus.connection {
        case .unknown, .checking: .secondary
        case .unavailable: .orange
        case .ready: .green
        }
    }
}

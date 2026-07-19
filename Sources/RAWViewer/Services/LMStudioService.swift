import Foundation

struct LMStudioConfiguration: Sendable {
    let serverAddress: String
    let modelIdentifier: String
    let autoStartLocalServer: Bool
    let unloadAfterAnalysis: Bool

    static func current(defaults: UserDefaults = .standard) -> LMStudioConfiguration {
        let savedAddress = defaults.string(forKey: PreferenceKeys.lmStudioServerAddress)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let address: String
        if let savedAddress, !savedAddress.isEmpty {
            address = savedAddress
        } else {
            address = "http://127.0.0.1:1234"
        }
        return LMStudioConfiguration(
            serverAddress: address,
            modelIdentifier: defaults.string(forKey: PreferenceKeys.lmStudioModelIdentifier)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            autoStartLocalServer: defaults.object(forKey: PreferenceKeys.lmStudioAutoStartLocalServer) == nil
                ? true
                : defaults.bool(forKey: PreferenceKeys.lmStudioAutoStartLocalServer),
            unloadAfterAnalysis: defaults.object(forKey: PreferenceKeys.lmStudioUnloadAfterAnalysis) == nil
                ? true
                : defaults.bool(forKey: PreferenceKeys.lmStudioUnloadAfterAnalysis)
        )
    }

    var serverURL: URL {
        get throws {
            let trimmed = serverAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            guard var components = URLComponents(string: trimmed),
                  let scheme = components.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  components.host?.isEmpty == false,
                  components.user == nil,
                  components.password == nil,
                  components.query == nil,
                  components.fragment == nil,
                  components.path.isEmpty || components.path == "/" else {
                throw LMStudioError.invalidServerAddress
            }
            components.path = ""
            guard let url = components.url else { throw LMStudioError.invalidServerAddress }
            return url
        }
    }

    var isLocalServer: Bool {
        guard let url = try? serverURL, let host = url.host?.lowercased() else { return false }
        return ["localhost", "127.0.0.1", "::1", "0.0.0.0"].contains(host)
    }
}

enum LMStudioError: LocalizedError {
    case invalidServerAddress
    case serverUnavailable(String)
    case remoteServerUnavailable
    case cliNotFound
    case cliFailed(String)
    case modelNotConfigured
    case modelNotFound(String)
    case modelHasNoVision(String)
    case invalidResponse
    case invalidAnalysisResponse
    case httpError(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidServerAddress:
            "Die LM-Studio-Adresse muss eine HTTP- oder HTTPS-Basisadresse ohne zusätzlichen Pfad sein."
        case .serverUnavailable(let detail):
            "Der LM-Studio-Server ist nicht erreichbar. \(detail)"
        case .remoteServerUnavailable:
            "Der entfernte LM-Studio-Server ist nicht erreichbar. Er kann von diesem Mac nicht automatisch gestartet werden."
        case .cliNotFound:
            "Die LM-Studio-CLI wurde nicht gefunden. Starte LM Studio einmal und aktiviere dort die lms-CLI."
        case .cliFailed(let detail):
            "Der lokale LM-Studio-Server konnte nicht gestartet werden. \(detail)"
        case .modelNotConfigured:
            "In den Einstellungen ist noch kein LM-Studio-Modell hinterlegt."
        case .modelNotFound(let identifier):
            "Das Modell „\(identifier)“ wurde auf dem LM-Studio-Server nicht gefunden."
        case .modelHasNoVision(let identifier):
            "Das Modell „\(identifier)“ unterstützt laut LM Studio keine Bildeingaben."
        case .invalidResponse:
            "LM Studio hat eine unerwartete Antwort geliefert."
        case .invalidAnalysisResponse:
            "Das Modell hat keine gültigen Schlagwörter im erwarteten JSON-Format geliefert."
        case .httpError(let status, let message):
            "LM Studio antwortete mit HTTP \(status): \(message)"
        }
    }
}

struct LMStudioModel: Codable, Identifiable, Sendable {
    struct LoadedInstance: Codable, Identifiable, Sendable {
        let id: String
    }

    struct Capabilities: Codable, Sendable {
        struct Reasoning: Codable, Sendable {
            let allowedOptions: [String]
            let `default`: String?
        }

        let vision: Bool
        let reasoning: Reasoning?
    }

    let key: String
    let displayName: String
    let type: String
    let loadedInstances: [LoadedInstance]
    let capabilities: Capabilities?

    var id: String { key }
    var supportsVision: Bool { capabilities?.vision == true }
    var supportsReasoningOff: Bool { capabilities?.reasoning?.allowedOptions.contains("off") == true }
}

struct LMStudioRuntimeStatus: Sendable {
    enum Connection: Sendable {
        case unknown
        case checking
        case unavailable
        case ready
    }

    let connection: Connection
    let models: [LMStudioModel]
    let selectedModelKey: String?
    let loadedInstanceID: String?
    let message: String

    static let unknown = LMStudioRuntimeStatus(
        connection: .unknown,
        models: [],
        selectedModelKey: nil,
        loadedInstanceID: nil,
        message: "Noch nicht geprüft"
    )

    static let checking = LMStudioRuntimeStatus(
        connection: .checking,
        models: [],
        selectedModelKey: nil,
        loadedInstanceID: nil,
        message: "Verbindung wird geprüft …"
    )
}

struct LMStudioModelHandle: Sendable {
    let modelKey: String
    let instanceID: String
    let loadedByApp: Bool
    let reasoning: String?
}

struct LMStudioPhotoAnalysisProfile: Sendable {
    static let contextLength = 16_384
    static let temperature = 0.1
    static let topP = 0.8
    static let topK = 20
    static let minP = 0.0
    static let repeatPenalty = 1.0
    static let maxOutputTokens = 2_048
}

actor LMStudioService {
    private struct ModelsResponse: Decodable {
        let models: [LMStudioModel]
    }

    private struct LoadRequest: Encodable {
        let model: String
        let contextLength: Int
    }

    private struct LoadResponse: Decodable {
        let instanceID: String
    }

    private struct UnloadRequest: Encodable {
        let instanceID: String
    }

    private struct ChatInput: Encodable {
        let type: String
        let content: String?
        let dataURL: String?

        enum CodingKeys: String, CodingKey {
            case type, content
            case dataURL = "data_url"
        }
    }

    private struct ChatRequest: Encodable {
        let model: String
        let input: [ChatInput]
        let systemPrompt: String
        let temperature: Double
        let topP: Double
        let topK: Int
        let minP: Double
        let repeatPenalty: Double
        let maxOutputTokens: Int
        let store: Bool
        let reasoning: String?
    }

    private struct ChatOutput: Decodable {
        let type: String
        let content: String?
    }

    private struct ChatResponse: Decodable {
        let output: [ChatOutput]
    }

    private struct AnalysisPayload: Decodable {
        let keywords: [String]
        let description: String?
    }

    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 180
        session = URLSession(configuration: configuration)
        encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
    }

    func ensureServerAvailable(configuration: LMStudioConfiguration, startLocalIfNeeded: Bool) async throws -> [LMStudioModel] {
        do {
            return try await listModels(configuration: configuration, timeout: 5)
        } catch {
            guard startLocalIfNeeded, configuration.autoStartLocalServer else { throw error }
            guard configuration.isLocalServer else { throw LMStudioError.remoteServerUnavailable }
            try await startLocalServer(configuration: configuration)
            for _ in 0..<30 {
                try Task.checkCancellation()
                if let models = try? await listModels(configuration: configuration, timeout: 3) {
                    return models
                }
                try await Task.sleep(for: .milliseconds(500))
            }
            throw LMStudioError.serverUnavailable("Der Start wurde angestoßen, die API wurde aber nicht rechtzeitig bereit.")
        }
    }

    func runtimeStatus(configuration: LMStudioConfiguration, startLocalIfNeeded: Bool = false) async throws -> LMStudioRuntimeStatus {
        let models = try await ensureServerAvailable(
            configuration: configuration,
            startLocalIfNeeded: startLocalIfNeeded
        )
        let selected = models.first { model in
            model.key == configuration.modelIdentifier
                || model.loadedInstances.contains { $0.id == configuration.modelIdentifier }
        }
        let loaded = selected?.loadedInstances.first?.id
        let message: String
        if configuration.modelIdentifier.isEmpty {
            message = "Server erreichbar · noch kein Modell ausgewählt"
        } else if let selected, !selected.supportsVision {
            message = "Server erreichbar · das gewählte Modell unterstützt keine Bilder"
        } else if selected == nil {
            message = "Server erreichbar · Modell nicht gefunden"
        } else if loaded != nil {
            message = "Bereit · Modell geladen"
        } else {
            message = "Server erreichbar · Modell wird bei Bedarf geladen"
        }
        return LMStudioRuntimeStatus(
            connection: .ready,
            models: models,
            selectedModelKey: selected?.key,
            loadedInstanceID: loaded,
            message: message
        )
    }

    func prepareModel(
        configuration: LMStudioConfiguration,
        reloadIfAlreadyLoaded: Bool = false
    ) async throws -> LMStudioModelHandle {
        guard !configuration.modelIdentifier.isEmpty else { throw LMStudioError.modelNotConfigured }
        let models = try await ensureServerAvailable(configuration: configuration, startLocalIfNeeded: true)
        guard let model = models.first(where: { candidate in
            candidate.key == configuration.modelIdentifier
                || candidate.loadedInstances.contains { $0.id == configuration.modelIdentifier }
        }) else {
            throw LMStudioError.modelNotFound(configuration.modelIdentifier)
        }
        guard model.supportsVision else { throw LMStudioError.modelHasNoVision(model.key) }
        if let instance = model.loadedInstances.first, !reloadIfAlreadyLoaded {
            return LMStudioModelHandle(
                modelKey: model.key,
                instanceID: instance.id,
                loadedByApp: false,
                reasoning: model.supportsReasoningOff ? "off" : nil
            )
        }

        if reloadIfAlreadyLoaded {
            for instance in model.loadedInstances {
                try await unload(instanceID: instance.id, configuration: configuration)
            }
        }

        let body = try encoder.encode(LoadRequest(
            model: model.key,
            contextLength: LMStudioPhotoAnalysisProfile.contextLength
        ))
        let data = try await request(
            configuration: configuration,
            path: "/api/v1/models/load",
            method: "POST",
            body: body,
            timeout: 180
        )
        let response = try decoder.decode(LoadResponse.self, from: data)
        return LMStudioModelHandle(
            modelKey: model.key,
            instanceID: response.instanceID,
            loadedByApp: true,
            reasoning: model.supportsReasoningOff ? "off" : nil
        )
    }

    func unload(_ handle: LMStudioModelHandle, configuration: LMStudioConfiguration) async throws {
        try await unload(instanceID: handle.instanceID, configuration: configuration)
    }

    func unloadConfiguredModel(configuration: LMStudioConfiguration) async throws {
        guard !configuration.modelIdentifier.isEmpty else { throw LMStudioError.modelNotConfigured }
        let models = try await listModels(configuration: configuration, timeout: 5)
        guard let model = models.first(where: { candidate in
            candidate.key == configuration.modelIdentifier
                || candidate.loadedInstances.contains { $0.id == configuration.modelIdentifier }
        }) else { throw LMStudioError.modelNotFound(configuration.modelIdentifier) }
        for instance in model.loadedInstances {
            try await unload(instanceID: instance.id, configuration: configuration)
        }
    }

    func analyzeJPEG(
        _ jpegData: Data,
        filename: String,
        handle: LMStudioModelHandle,
        configuration: LMStudioConfiguration
    ) async throws -> (keywords: [String], description: String) {
        let dataURL = "data:image/jpeg;base64," + jpegData.base64EncodedString()
        let body = try encoder.encode(ChatRequest(
            model: handle.instanceID,
            input: [
                ChatInput(
                    type: "text",
                    content: "Analysiere das Foto \(filename). Gib ausschließlich das verlangte JSON zurück.",
                    dataURL: nil
                ),
                ChatInput(type: "image", content: nil, dataURL: dataURL)
            ],
            systemPrompt: """
                Du verschlagwortest Fotos für eine deutschsprachige Fotobibliothek. Antworte ausschließlich als gültiges JSON ohne Markdown: {"keywords":["schlagwort"],"description":"kurze sachliche Bildbeschreibung"}. Erzeuge 6 bis 15 präzise deutsche Schlagwörter in Kleinschreibung. Nutze sichtbare Motive, Umgebung, Farben, Licht, Tageszeit, Wetter, Bildstil und Aktivität. Erfinde keine Orte, Namen oder Ereignisse, die nicht sicher sichtbar sind.
                """,
            temperature: LMStudioPhotoAnalysisProfile.temperature,
            topP: LMStudioPhotoAnalysisProfile.topP,
            topK: LMStudioPhotoAnalysisProfile.topK,
            minP: LMStudioPhotoAnalysisProfile.minP,
            repeatPenalty: LMStudioPhotoAnalysisProfile.repeatPenalty,
            maxOutputTokens: LMStudioPhotoAnalysisProfile.maxOutputTokens,
            store: false,
            reasoning: handle.reasoning
        ))
        let data = try await request(
            configuration: configuration,
            path: "/api/v1/chat",
            method: "POST",
            body: body,
            timeout: 180
        )
        let response = try decoder.decode(ChatResponse.self, from: data)
        guard let content = response.output.first(where: { $0.type == "message" })?.content,
              let jsonData = Self.extractedJSONObject(from: content),
              let payload = try? decoder.decode(AnalysisPayload.self, from: jsonData) else {
            throw LMStudioError.invalidAnalysisResponse
        }
        let keywords = Self.normalizedKeywords(payload.keywords)
        guard !keywords.isEmpty else { throw LMStudioError.invalidAnalysisResponse }
        let description = (payload.description ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(1_000)
        return (keywords, String(description))
    }

    private func listModels(configuration: LMStudioConfiguration, timeout: TimeInterval) async throws -> [LMStudioModel] {
        let data = try await request(
            configuration: configuration,
            path: "/api/v1/models",
            method: "GET",
            body: nil,
            timeout: timeout
        )
        do {
            return try decoder.decode(ModelsResponse.self, from: data).models
        } catch {
            throw LMStudioError.invalidResponse
        }
    }

    private func unload(instanceID: String, configuration: LMStudioConfiguration) async throws {
        let body = try encoder.encode(UnloadRequest(instanceID: instanceID))
        _ = try await request(
            configuration: configuration,
            path: "/api/v1/models/unload",
            method: "POST",
            body: body,
            timeout: 60
        )
    }

    private func request(
        configuration: LMStudioConfiguration,
        path: String,
        method: String,
        body: Data?,
        timeout: TimeInterval
    ) async throws -> Data {
        let baseURL = try configuration.serverURL
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw LMStudioError.invalidServerAddress
        }
        components.path = path
        guard let url = components.url else { throw LMStudioError.invalidServerAddress }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw LMStudioError.invalidResponse }
            guard (200..<300).contains(http.statusCode) else {
                let message = Self.errorMessage(from: data)
                throw LMStudioError.httpError(http.statusCode, message)
            }
            return data
        } catch let error as LMStudioError {
            throw error
        } catch {
            throw LMStudioError.serverUnavailable(error.localizedDescription)
        }
    }

    private func startLocalServer(configuration: LMStudioConfiguration) async throws {
        let executable = try Self.findLMSExecutable()
        let port = try configuration.serverURL.port ?? (configuration.serverURL.scheme == "https" ? 443 : 80)
        do {
            try await Self.runProcess(
                executable: executable,
                arguments: ["server", "start", "--port", String(port)],
                timeout: 30
            )
        } catch let error as LMStudioError {
            throw error
        } catch {
            throw LMStudioError.cliFailed(error.localizedDescription)
        }
    }

    private static func findLMSExecutable() throws -> URL {
        let fileManager = FileManager.default
        var candidates: [String] = []
        if let override = ProcessInfo.processInfo.environment["LMS_CLI"], !override.isEmpty {
            candidates.append(override)
        }
        candidates.append(fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".lmstudio/bin/lms").path)
        candidates.append(contentsOf: ["/opt/homebrew/bin/lms", "/usr/local/bin/lms", "/usr/bin/lms"])
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { String($0) + "/lms" })
        }
        guard let path = candidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) else {
            throw LMStudioError.cliNotFound
        }
        return URL(fileURLWithPath: path)
    }

    private static func runProcess(executable: URL, arguments: [String], timeout: TimeInterval) async throws {
        try await Task.detached(priority: .utility) {
            let process = Process()
            let output = Pipe()
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = output
            process.standardError = output
            do {
                try process.run()
            } catch {
                throw LMStudioError.cliFailed(error.localizedDescription)
            }

            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning, Date() < deadline {
                do {
                    try Task.checkCancellation()
                    try await Task.sleep(for: .milliseconds(100))
                } catch {
                    if process.isRunning { process.terminate() }
                    throw error
                }
            }
            if process.isRunning {
                process.terminate()
                throw LMStudioError.cliFailed("Zeitüberschreitung beim Start der lms-CLI.")
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            guard process.terminationStatus == 0 else {
                let text = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unbekannter CLI-Fehler"
                throw LMStudioError.cliFailed(text)
            }
        }.value
    }

    private static func extractedJSONObject(from value: String) -> Data? {
        guard let start = value.firstIndex(of: "{"), let end = value.lastIndex(of: "}"), start <= end else {
            return nil
        }
        return String(value[start...end]).data(using: .utf8)
    }

    private static func normalizedKeywords(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for value in values {
            let cleaned = value
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
                .lowercased(with: Locale(identifier: "de_DE"))
                .prefix(60)
            let keyword = String(cleaned)
            guard keyword.count >= 2, seen.insert(keyword).inserted else { continue }
            result.append(keyword)
            if result.count == 20 { break }
        }
        return result
    }

    private static func errorMessage(from data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
                return message
            }
            if let message = object["message"] as? String { return message }
            if let error = object["error"] as? String { return error }
        }
        return String(data: data, encoding: .utf8)?.prefix(500).description ?? "Unbekannter Fehler"
    }
}

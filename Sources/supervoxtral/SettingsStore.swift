import Foundation

@MainActor
final class SettingsStore: ObservableObject {
    private enum Keys {
        static let endpointURL = "settings.endpoint_url"
        static let apiKey = "settings.api_key"
        static let modelName = "settings.model_name"
        static let commitIntervalSeconds = "settings.commit_interval_seconds"
        static let autoCopyEnabled = "settings.auto_copy_enabled"
    }

    private let defaults = UserDefaults.standard

    @Published var endpointURL: String {
        didSet { defaults.set(endpointURL, forKey: Keys.endpointURL) }
    }

    @Published var apiKey: String {
        didSet { defaults.set(apiKey, forKey: Keys.apiKey) }
    }

    @Published var modelName: String {
        didSet { defaults.set(modelName, forKey: Keys.modelName) }
    }

    @Published var commitIntervalSeconds: Double {
        didSet { defaults.set(commitIntervalSeconds, forKey: Keys.commitIntervalSeconds) }
    }

    @Published var autoCopyEnabled: Bool {
        didSet { defaults.set(autoCopyEnabled, forKey: Keys.autoCopyEnabled) }
    }

    init() {
        endpointURL = defaults.string(forKey: Keys.endpointURL)
            ?? ProcessInfo.processInfo.environment["REALTIME_ENDPOINT"]
            ?? "ws://127.0.0.1:8000/v1/realtime"

        apiKey = defaults.string(forKey: Keys.apiKey)
            ?? ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
            ?? ""

        let configuredModel = defaults.string(forKey: Keys.modelName)
            ?? ProcessInfo.processInfo.environment["REALTIME_MODEL"]
            ?? "voxtral-mini-latest"
        let normalizedModel = Self.normalizedModelName(from: configuredModel)
        modelName = normalizedModel.isEmpty ? "voxtral-mini-latest" : normalizedModel

        let storedInterval = defaults.double(forKey: Keys.commitIntervalSeconds)
        commitIntervalSeconds = storedInterval > 0 ? storedInterval : 0.9

        if defaults.object(forKey: Keys.autoCopyEnabled) == nil {
            autoCopyEnabled = false
        } else {
            autoCopyEnabled = defaults.bool(forKey: Keys.autoCopyEnabled)
        }
    }

    var trimmedAPIKey: String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var effectiveModelName: String {
        let normalized = Self.normalizedModelName(from: modelName)
        return normalized.isEmpty ? "voxtral-mini-latest" : normalized
    }

    var displayModelName: String {
        effectiveModelName
    }

    var resolvedWebSocketURL: URL? {
        let trimmed = endpointURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("ws://") || trimmed.hasPrefix("wss://") {
            return URL(string: trimmed)
        }

        if trimmed.hasPrefix("http://") {
            return URL(string: "ws://" + trimmed.dropFirst("http://".count))
        }

        if trimmed.hasPrefix("https://") {
            return URL(string: "wss://" + trimmed.dropFirst("https://".count))
        }

        return URL(string: "ws://\(trimmed)")
    }

    private static func normalizedModelName(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let lines = trimmed
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard let candidate = lines.last else {
            return trimmed
        }

        if candidate.contains(" ") {
            let tokens = candidate.split(whereSeparator: \.isWhitespace).map(String.init)
            if let token = tokens.last {
                return token
            }
        }

        return candidate
    }
}

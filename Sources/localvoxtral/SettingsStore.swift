import Foundation
import Observation

@MainActor
@Observable
final class SettingsStore {
    enum RealtimeProvider: String, CaseIterable, Identifiable {
        case openAICompatible = "openai_compatible"
        case mlxAudio = "mlx_audio"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .openAICompatible:
                return "OpenAI/vLLM"
            case .mlxAudio:
                return "mlx-audio"
            }
        }

        var defaultEndpoint: String {
            switch self {
            case .openAICompatible:
                return "ws://127.0.0.1:8000/v1/realtime"
            case .mlxAudio:
                return "ws://127.0.0.1:8000/v1/audio/transcriptions/realtime"
            }
        }

        var defaultModelName: String {
            switch self {
            case .openAICompatible:
                return "voxtral-mini-latest"
            case .mlxAudio:
                return "mlx-community/Voxtral-Mini-4B-Realtime-2602-4bit"
            }
        }
    }

    private enum Keys {
        static let realtimeProvider = "settings.realtime_provider"
        static let openAIEndpointURL = "settings.endpoint_url"
        static let mlxAudioEndpointURL = "settings.mlx_audio_endpoint_url"
        static let apiKey = "settings.api_key"
        static let openAIModelName = "settings.model_name"
        static let mlxAudioModelName = "settings.mlx_audio_model_name"
        static let commitIntervalSeconds = "settings.commit_interval_seconds"
        static let autoCopyEnabled = "settings.auto_copy_enabled"
        static let selectedInputDeviceUID = "settings.selected_input_device_uid"
    }

    private let defaults = UserDefaults.standard

    var realtimeProvider: RealtimeProvider {
        didSet { defaults.set(realtimeProvider.rawValue, forKey: Keys.realtimeProvider) }
    }

    var openAIEndpointURL: String {
        didSet { defaults.set(openAIEndpointURL, forKey: Keys.openAIEndpointURL) }
    }

    var mlxAudioEndpointURL: String {
        didSet { defaults.set(mlxAudioEndpointURL, forKey: Keys.mlxAudioEndpointURL) }
    }

    var apiKey: String {
        didSet { defaults.set(apiKey, forKey: Keys.apiKey) }
    }

    var openAIModelName: String {
        didSet { defaults.set(openAIModelName, forKey: Keys.openAIModelName) }
    }

    var mlxAudioModelName: String {
        didSet { defaults.set(mlxAudioModelName, forKey: Keys.mlxAudioModelName) }
    }

    var commitIntervalSeconds: Double {
        didSet { defaults.set(commitIntervalSeconds, forKey: Keys.commitIntervalSeconds) }
    }

    var autoCopyEnabled: Bool {
        didSet { defaults.set(autoCopyEnabled, forKey: Keys.autoCopyEnabled) }
    }

    var selectedInputDeviceUID: String {
        didSet { defaults.set(selectedInputDeviceUID, forKey: Keys.selectedInputDeviceUID) }
    }

    init() {
        let configuredProvider = defaults.string(forKey: Keys.realtimeProvider)
            ?? ProcessInfo.processInfo.environment["REALTIME_PROVIDER"]
            ?? RealtimeProvider.openAICompatible.rawValue

        let resolvedProvider = RealtimeProvider(rawValue: configuredProvider) ?? .openAICompatible
        realtimeProvider = resolvedProvider

        openAIEndpointURL = defaults.string(forKey: Keys.openAIEndpointURL)
            ?? ProcessInfo.processInfo.environment["REALTIME_ENDPOINT"]
            ?? resolvedProvider.defaultEndpoint

        mlxAudioEndpointURL = defaults.string(forKey: Keys.mlxAudioEndpointURL)
            ?? ProcessInfo.processInfo.environment["MLX_AUDIO_REALTIME_ENDPOINT"]
            ?? RealtimeProvider.mlxAudio.defaultEndpoint

        apiKey = defaults.string(forKey: Keys.apiKey)
            ?? ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
            ?? ""

        let configuredOpenAIModel = defaults.string(forKey: Keys.openAIModelName)
            ?? ProcessInfo.processInfo.environment["REALTIME_MODEL"]
            ?? RealtimeProvider.openAICompatible.defaultModelName
        let normalizedOpenAIModel = Self.normalizedModelName(from: configuredOpenAIModel)
        openAIModelName = normalizedOpenAIModel.isEmpty
            ? RealtimeProvider.openAICompatible.defaultModelName
            : normalizedOpenAIModel

        let configuredMlxAudioModel = defaults.string(forKey: Keys.mlxAudioModelName)
            ?? ProcessInfo.processInfo.environment["MLX_AUDIO_REALTIME_MODEL"]
            ?? RealtimeProvider.mlxAudio.defaultModelName
        let normalizedMlxAudioModel = Self.normalizedModelName(from: configuredMlxAudioModel)
        mlxAudioModelName = normalizedMlxAudioModel.isEmpty
            ? RealtimeProvider.mlxAudio.defaultModelName
            : normalizedMlxAudioModel

        let storedInterval = defaults.double(forKey: Keys.commitIntervalSeconds)
        if storedInterval > 0 {
            commitIntervalSeconds = min(max(storedInterval, 0.1), 1.0)
        } else {
            commitIntervalSeconds = 0.9
        }

        if defaults.object(forKey: Keys.autoCopyEnabled) == nil {
            autoCopyEnabled = false
        } else {
            autoCopyEnabled = defaults.bool(forKey: Keys.autoCopyEnabled)
        }

        selectedInputDeviceUID = defaults.string(forKey: Keys.selectedInputDeviceUID) ?? ""
    }

    var trimmedAPIKey: String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var effectiveModelName: String {
        effectiveModelName(for: realtimeProvider)
    }

    var displayModelName: String {
        effectiveModelName
    }

    var endpointPlaceholder: String {
        realtimeProvider.defaultEndpoint
    }

    var modelPlaceholder: String {
        realtimeProvider.defaultModelName
    }

    func modelName(for provider: RealtimeProvider) -> String {
        switch provider {
        case .openAICompatible:
            return openAIModelName
        case .mlxAudio:
            return mlxAudioModelName
        }
    }

    func effectiveModelName(for provider: RealtimeProvider) -> String {
        let normalized = Self.normalizedModelName(from: modelName(for: provider))
        return normalized.isEmpty ? provider.defaultModelName : normalized
    }

    func endpointURL(for provider: RealtimeProvider) -> String {
        switch provider {
        case .openAICompatible:
            return openAIEndpointURL
        case .mlxAudio:
            return mlxAudioEndpointURL
        }
    }

    var resolvedWebSocketURL: URL? {
        resolvedWebSocketURL(for: realtimeProvider)
    }

    func resolvedWebSocketURL(for provider: RealtimeProvider) -> URL? {
        let trimmed = endpointURL(for: provider).trimmingCharacters(in: .whitespacesAndNewlines)
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

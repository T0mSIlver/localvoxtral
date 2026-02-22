import Foundation
import Observation

@MainActor
@Observable
final class SettingsStore {
    enum RealtimeProvider: String, CaseIterable, Identifiable {
        case realtimeAPI = "realtime_api"
        case mlxAudio = "mlx_audio"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .realtimeAPI:
                return "vLLM/voxmlx"
            case .mlxAudio:
                return "mlx-audio"
            }
        }

        var defaultEndpoint: String {
            switch self {
            case .realtimeAPI:
                return "ws://127.0.0.1:8000/v1/realtime"
            case .mlxAudio:
                return "ws://127.0.0.1:8000/v1/audio/transcriptions/realtime"
            }
        }

        var defaultModelName: String {
            switch self {
            case .realtimeAPI:
                return "voxtral-mini-latest"
            case .mlxAudio:
                return "mlx-community/Voxtral-Mini-4B-Realtime-2602-4bit"
            }
        }
    }

    private enum Keys {
        static let realtimeProvider = "settings.realtime_provider"
        static let realtimeAPIEndpointURL = "settings.realtime_api_endpoint_url"
        static let mlxAudioEndpointURL = "settings.mlx_audio_endpoint_url"
        static let apiKey = "settings.api_key"
        static let realtimeAPIModelName = "settings.realtime_api_model_name"
        static let mlxAudioModelName = "settings.mlx_audio_model_name"
        static let commitIntervalSeconds = "settings.commit_interval_seconds"
        static let mlxAudioTranscriptionDelayMilliseconds = "settings.mlx_audio_transcription_delay_ms"
        static let autoCopyEnabled = "settings.auto_copy_enabled"
        static let selectedInputDeviceUID = "settings.selected_input_device_uid"
    }

    private let defaults = UserDefaults.standard

    var realtimeProvider: RealtimeProvider {
        didSet { defaults.set(realtimeProvider.rawValue, forKey: Keys.realtimeProvider) }
    }

    var realtimeAPIEndpointURL: String {
        didSet { defaults.set(realtimeAPIEndpointURL, forKey: Keys.realtimeAPIEndpointURL) }
    }

    var mlxAudioEndpointURL: String {
        didSet { defaults.set(mlxAudioEndpointURL, forKey: Keys.mlxAudioEndpointURL) }
    }

    var apiKey: String {
        didSet { defaults.set(apiKey, forKey: Keys.apiKey) }
    }

    var realtimeAPIModelName: String {
        didSet { defaults.set(realtimeAPIModelName, forKey: Keys.realtimeAPIModelName) }
    }

    var mlxAudioModelName: String {
        didSet { defaults.set(mlxAudioModelName, forKey: Keys.mlxAudioModelName) }
    }

    var commitIntervalSeconds: Double {
        didSet { defaults.set(commitIntervalSeconds, forKey: Keys.commitIntervalSeconds) }
    }

    var mlxAudioTranscriptionDelayMilliseconds: Int {
        didSet { defaults.set(mlxAudioTranscriptionDelayMilliseconds, forKey: Keys.mlxAudioTranscriptionDelayMilliseconds) }
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
            ?? RealtimeProvider.realtimeAPI.rawValue

        let resolvedProvider = RealtimeProvider(rawValue: configuredProvider) ?? .realtimeAPI
        realtimeProvider = resolvedProvider

        realtimeAPIEndpointURL = defaults.string(forKey: Keys.realtimeAPIEndpointURL)
            ?? ProcessInfo.processInfo.environment["REALTIME_ENDPOINT"]
            ?? RealtimeProvider.realtimeAPI.defaultEndpoint

        mlxAudioEndpointURL = defaults.string(forKey: Keys.mlxAudioEndpointURL)
            ?? ProcessInfo.processInfo.environment["MLX_AUDIO_REALTIME_ENDPOINT"]
            ?? RealtimeProvider.mlxAudio.defaultEndpoint

        apiKey = defaults.string(forKey: Keys.apiKey)
            ?? ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
            ?? ""

        let configuredRealtimeAPIModel = defaults.string(forKey: Keys.realtimeAPIModelName)
            ?? ProcessInfo.processInfo.environment["REALTIME_MODEL"]
            ?? RealtimeProvider.realtimeAPI.defaultModelName
        let normalizedRealtimeAPIModel = Self.normalizedModelName(from: configuredRealtimeAPIModel)
        realtimeAPIModelName = normalizedRealtimeAPIModel.isEmpty
            ? RealtimeProvider.realtimeAPI.defaultModelName
            : normalizedRealtimeAPIModel

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

        let delayDefault = 900
        if defaults.object(forKey: Keys.mlxAudioTranscriptionDelayMilliseconds) != nil {
            mlxAudioTranscriptionDelayMilliseconds = Self.clampedTranscriptionDelay(
                defaults.integer(forKey: Keys.mlxAudioTranscriptionDelayMilliseconds)
            )
        } else if let envDelay = ProcessInfo.processInfo.environment["MLX_AUDIO_REALTIME_TRANSCRIPTION_DELAY_MS"],
                  let parsedDelay = Int(envDelay)
        {
            mlxAudioTranscriptionDelayMilliseconds = Self.clampedTranscriptionDelay(parsedDelay)
        } else {
            mlxAudioTranscriptionDelayMilliseconds = delayDefault
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
        case .realtimeAPI:
            return realtimeAPIModelName
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
        case .realtimeAPI:
            return realtimeAPIEndpointURL
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

    private static func clampedTranscriptionDelay(_ value: Int) -> Int {
        min(max(value, 400), 2_000)
    }
}

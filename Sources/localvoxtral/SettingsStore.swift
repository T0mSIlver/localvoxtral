import Carbon.HIToolbox
import Foundation
import Observation

struct DictationShortcut: Equatable, Sendable {
    var keyCode: UInt32
    var carbonModifierFlags: UInt32

    var normalized: DictationShortcut {
        DictationShortcut(
            keyCode: keyCode,
            carbonModifierFlags: DictationShortcutValidation.normalizedModifierFlags(carbonModifierFlags)
        )
    }
}

enum DictationShortcutValidation {
    static let allowedModifierFlagsMask = UInt32(cmdKey | optionKey | shiftKey | controlKey)

    static func normalizedModifierFlags(_ flags: UInt32) -> UInt32 {
        flags & allowedModifierFlagsMask
    }

    static func persistenceErrorMessage(for shortcut: DictationShortcut) -> String? {
        if shortcut.keyCode > UInt32(UInt16.max) {
            return "Shortcut key is not supported."
        }

        if normalizedModifierFlags(shortcut.carbonModifierFlags) == 0 {
            return "Shortcut must include at least one modifier key."
        }

        return nil
    }

    static func validationErrorMessage(for shortcut: DictationShortcut) -> String? {
        if let persistenceError = persistenceErrorMessage(for: shortcut) {
            return persistenceError
        }

        let normalized = shortcut.normalized
        switch (normalized.keyCode, normalized.carbonModifierFlags) {
        case (UInt32(kVK_Space), UInt32(cmdKey)):
            return "Command-Space is reserved by Spotlight."
        case (UInt32(kVK_Tab), UInt32(cmdKey)):
            return "Command-Tab is reserved for app switching."
        case (UInt32(kVK_ANSI_Q), UInt32(cmdKey)):
            return "Command-Q is reserved for quitting apps."
        case (UInt32(kVK_ANSI_W), UInt32(cmdKey)):
            return "Command-W is reserved for closing windows."
        default:
            return nil
        }
    }
}

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
        static let autoPasteIntoInputFieldEnabled = "settings.auto_paste_into_input_field_enabled"
        static let selectedInputDeviceUID = "settings.selected_input_device_uid"
        static let dictationShortcutEnabled = "settings.dictation_shortcut_enabled"
        static let dictationShortcutKeyCode = "settings.dictation_shortcut_key_code"
        static let dictationShortcutCarbonModifierFlags = "settings.dictation_shortcut_carbon_modifiers"
    }

    private let defaults = UserDefaults.standard

    static let defaultDictationShortcut = DictationShortcut(
        keyCode: UInt32(kVK_Space),
        carbonModifierFlags: UInt32(optionKey)
    )

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

    var autoPasteIntoInputFieldEnabled: Bool {
        didSet { defaults.set(autoPasteIntoInputFieldEnabled, forKey: Keys.autoPasteIntoInputFieldEnabled) }
    }

    var selectedInputDeviceUID: String {
        didSet { defaults.set(selectedInputDeviceUID, forKey: Keys.selectedInputDeviceUID) }
    }

    var dictationShortcutEnabled: Bool {
        didSet { defaults.set(dictationShortcutEnabled, forKey: Keys.dictationShortcutEnabled) }
    }

    private var dictationShortcutKeyCode: UInt32 {
        didSet { defaults.set(dictationShortcutKeyCode, forKey: Keys.dictationShortcutKeyCode) }
    }

    private var dictationShortcutCarbonModifierFlags: UInt32 {
        didSet { defaults.set(dictationShortcutCarbonModifierFlags, forKey: Keys.dictationShortcutCarbonModifierFlags) }
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

        if defaults.object(forKey: Keys.autoPasteIntoInputFieldEnabled) == nil {
            autoPasteIntoInputFieldEnabled = true
        } else {
            autoPasteIntoInputFieldEnabled = defaults.bool(forKey: Keys.autoPasteIntoInputFieldEnabled)
        }

        selectedInputDeviceUID = defaults.string(forKey: Keys.selectedInputDeviceUID) ?? ""

        if defaults.object(forKey: Keys.dictationShortcutEnabled) == nil {
            dictationShortcutEnabled = true
        } else {
            dictationShortcutEnabled = defaults.bool(forKey: Keys.dictationShortcutEnabled)
        }

        let storedKeyCode = (defaults.object(forKey: Keys.dictationShortcutKeyCode) as? NSNumber)?.uint32Value
        let storedModifierFlags = (defaults.object(forKey: Keys.dictationShortcutCarbonModifierFlags) as? NSNumber)?.uint32Value
        let fallbackShortcut = Self.defaultDictationShortcut

        let resolvedShortcut: DictationShortcut
        if let storedKeyCode, let storedModifierFlags {
            let candidate = DictationShortcut(
                keyCode: storedKeyCode,
                carbonModifierFlags: storedModifierFlags
            ).normalized
            if DictationShortcutValidation.persistenceErrorMessage(for: candidate) == nil {
                resolvedShortcut = candidate
            } else {
                resolvedShortcut = fallbackShortcut
            }
        } else {
            resolvedShortcut = fallbackShortcut
        }

        dictationShortcutKeyCode = resolvedShortcut.keyCode
        dictationShortcutCarbonModifierFlags = resolvedShortcut.carbonModifierFlags
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

    var dictationShortcut: DictationShortcut? {
        guard dictationShortcutEnabled else { return nil }

        let candidate = DictationShortcut(
            keyCode: dictationShortcutKeyCode,
            carbonModifierFlags: dictationShortcutCarbonModifierFlags
        ).normalized

        if DictationShortcutValidation.persistenceErrorMessage(for: candidate) != nil {
            return Self.defaultDictationShortcut
        }

        return candidate
    }

    func setDictationShortcut(_ shortcut: DictationShortcut?) {
        guard let shortcut else {
            dictationShortcutEnabled = false
            return
        }

        let normalizedShortcut = shortcut.normalized
        let resolvedShortcut: DictationShortcut
        if DictationShortcutValidation.persistenceErrorMessage(for: normalizedShortcut) == nil {
            resolvedShortcut = normalizedShortcut
        } else {
            resolvedShortcut = Self.defaultDictationShortcut
        }

        dictationShortcutKeyCode = resolvedShortcut.keyCode
        dictationShortcutCarbonModifierFlags = resolvedShortcut.carbonModifierFlags
        dictationShortcutEnabled = true
    }

    func resetDictationShortcutToDefault() {
        setDictationShortcut(Self.defaultDictationShortcut)
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

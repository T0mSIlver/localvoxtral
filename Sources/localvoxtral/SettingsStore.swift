import Carbon.HIToolbox
import Foundation
import Observation

struct DictationShortcut: Equatable, Sendable {
    var keyCode: UInt32
    var carbonModifierFlags: UInt32

    var normalized: DictationShortcut {
        DictationShortcut(
            keyCode: keyCode,
            carbonModifierFlags: DictationShortcutValidation.normalizedModifierFlags(
                carbonModifierFlags)
        )
    }
}

enum DictationOutputMode: String, CaseIterable, Identifiable {
    case overlayBuffer = "overlay_buffer"
    case liveAutoPaste = "live_auto_paste"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .overlayBuffer:
            return "Overlay Buffer"
        case .liveAutoPaste:
            return "Live Auto-Paste"
        }
    }

    var description: String {
        switch self {
        case .overlayBuffer:
            return "Keeps text in an on-screen buffer until stop."
        case .liveAutoPaste:
            return "Streams text directly into the focused app."
        }
    }
}

enum DictationShortcutMode: String, CaseIterable, Identifiable {
    case toggle = "toggle"
    case pushToTalk = "push_to_talk"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .toggle:
            return "Toggle"
        case .pushToTalk:
            return "Push to Talk"
        }
    }

    var description: String {
        switch self {
        case .toggle:
            return "Press once to start dictation, press again to stop."
        case .pushToTalk:
            return "Hold the shortcut to dictate, release to stop."
        }
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
                return "T0mSIlver/Voxtral-Mini-4B-Realtime-2602-MLX-4bit"
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
        static let mlxAudioTranscriptionDelayMilliseconds =
            "settings.mlx_audio_transcription_delay_ms"
        static let dictationOutputMode = "settings.dictation_output_mode"
        static let dictationShortcutMode = "settings.dictation_shortcut_mode"
        static let autoCopyEnabled = "settings.auto_copy_enabled"
        static let selectedInputDeviceUID = "settings.selected_input_device_uid"
        static let dictationShortcutEnabled = "settings.dictation_shortcut_enabled"
        static let dictationShortcutKeyCode = "settings.dictation_shortcut_key_code"
        static let dictationShortcutCarbonModifierFlags =
            "settings.dictation_shortcut_carbon_modifiers"
        static let llmPolishingEnabled = "settings.llm_polishing_enabled"
        static let llmPolishingEndpointURL = "settings.llm_polishing_endpoint_url"
        static let llmPolishingAPIKey = "settings.llm_polishing_api_key"
        static let llmPolishingModel = "settings.llm_polishing_model"
        static let replacementDictionaryEnabled = "settings.replacement_dictionary_enabled"
        static let audioDuckingEnabled = "settings.audio_ducking_enabled"
        static let audioDuckingLevel = "settings.audio_ducking_level"
        static let audioDuckingUseDDC = "settings.audio_ducking_use_ddc"
        static let audioDuckingFadeInDuration = "settings.audio_ducking_fade_in_duration"
        static let modifierOnlyHotKeyEnabled = "settings.modifier_only_hotkey_enabled"
        static let modifierOnlyHotKeyModifier = "settings.modifier_only_hotkey_modifier"
        static let modifierOnlyHoldDelay = "settings.modifier_only_hold_delay"
        static let overlayLastX = "settings.overlay_last_x"
        static let overlayLastY = "settings.overlay_last_y"
        static let overlayPositionSaved = "settings.overlay_position_saved"
        static let overlayBufferShortcutKeyCode = "settings.overlay_buffer_shortcut_key_code"
        static let overlayBufferShortcutModifiers = "settings.overlay_buffer_shortcut_carbon_modifiers"
        static let overlayBufferShortcutEnabled = "settings.overlay_buffer_shortcut_enabled"
        static let livePasteShortcutKeyCode = "settings.live_paste_shortcut_key_code"
        static let livePasteShortcutModifiers = "settings.live_paste_shortcut_carbon_modifiers"
        static let livePasteShortcutEnabled = "settings.live_paste_shortcut_enabled"
    }

    private let defaults: UserDefaults

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
        didSet {
            defaults.set(
                mlxAudioTranscriptionDelayMilliseconds,
                forKey: Keys.mlxAudioTranscriptionDelayMilliseconds)
        }
    }

    var autoCopyEnabled: Bool {
        didSet { defaults.set(autoCopyEnabled, forKey: Keys.autoCopyEnabled) }
    }

    var dictationOutputMode: DictationOutputMode {
        didSet { defaults.set(dictationOutputMode.rawValue, forKey: Keys.dictationOutputMode) }
    }

    var dictationShortcutMode: DictationShortcutMode {
        didSet { defaults.set(dictationShortcutMode.rawValue, forKey: Keys.dictationShortcutMode) }
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
        didSet {
            defaults.set(
                dictationShortcutCarbonModifierFlags,
                forKey: Keys.dictationShortcutCarbonModifierFlags)
        }
    }

    var llmPolishingEnabled: Bool {
        didSet { defaults.set(llmPolishingEnabled, forKey: Keys.llmPolishingEnabled) }
    }

    var llmPolishingEndpointURL: String {
        didSet { defaults.set(llmPolishingEndpointURL, forKey: Keys.llmPolishingEndpointURL) }
    }

    var llmPolishingAPIKey: String {
        didSet { defaults.set(llmPolishingAPIKey, forKey: Keys.llmPolishingAPIKey) }
    }

    var llmPolishingModel: String {
        didSet { defaults.set(llmPolishingModel, forKey: Keys.llmPolishingModel) }
    }

    var replacementDictionaryEnabled: Bool {
        didSet {
            defaults.set(replacementDictionaryEnabled, forKey: Keys.replacementDictionaryEnabled)
        }
    }

    var audioDuckingEnabled: Bool {
        didSet { defaults.set(audioDuckingEnabled, forKey: Keys.audioDuckingEnabled) }
    }

    /// The fraction of current volume to duck to (0.0 = mute, 1.0 = no change).
    /// For example, 0.2 means duck to 20% of the current volume.
    var audioDuckingLevel: Double {
        didSet {
            defaults.set(
                min(max(audioDuckingLevel, 0.0), 1.0),
                forKey: Keys.audioDuckingLevel)
        }
    }

    /// When true, duck HDMI/DisplayPort monitor volume via BetterDisplay DDC
    /// instead of falling back to pausing music apps.
    var audioDuckingUseDDC: Bool {
        didSet { defaults.set(audioDuckingUseDDC, forKey: Keys.audioDuckingUseDDC) }
    }

    /// Duration in seconds for the volume fade-in after dictation stops (0.3–5.0).
    var audioDuckingFadeInDuration: Double {
        didSet { defaults.set(audioDuckingFadeInDuration, forKey: Keys.audioDuckingFadeInDuration) }
    }

    var modifierOnlyHotKeyEnabled: Bool {
        didSet { defaults.set(modifierOnlyHotKeyEnabled, forKey: Keys.modifierOnlyHotKeyEnabled) }
    }

    var modifierOnlyHotKeyModifier: ModifierOnlyHotKeyManager.ModifierKey {
        didSet {
            defaults.set(modifierOnlyHotKeyModifier.rawValue, forKey: Keys.modifierOnlyHotKeyModifier)
        }
    }

    /// Seconds to hold modifier before it triggers live auto-paste (0.15–0.8).
    var modifierOnlyHoldDelay: Double {
        didSet { defaults.set(modifierOnlyHoldDelay, forKey: Keys.modifierOnlyHoldDelay) }
    }

    var overlayLastX: Double {
        didSet { defaults.set(overlayLastX, forKey: Keys.overlayLastX) }
    }

    var overlayLastY: Double {
        didSet { defaults.set(overlayLastY, forKey: Keys.overlayLastY) }
    }

    var overlayPositionSaved: Bool {
        didSet { defaults.set(overlayPositionSaved, forKey: Keys.overlayPositionSaved) }
    }

    var overlayBufferShortcutEnabled: Bool {
        didSet { defaults.set(overlayBufferShortcutEnabled, forKey: Keys.overlayBufferShortcutEnabled) }
    }

    private var overlayBufferShortcutKeyCode: UInt32 {
        didSet { defaults.set(overlayBufferShortcutKeyCode, forKey: Keys.overlayBufferShortcutKeyCode) }
    }

    private var overlayBufferShortcutCarbonModifierFlags: UInt32 {
        didSet {
            defaults.set(
                overlayBufferShortcutCarbonModifierFlags,
                forKey: Keys.overlayBufferShortcutModifiers)
        }
    }

    var livePasteShortcutEnabled: Bool {
        didSet { defaults.set(livePasteShortcutEnabled, forKey: Keys.livePasteShortcutEnabled) }
    }

    private var livePasteShortcutKeyCode: UInt32 {
        didSet { defaults.set(livePasteShortcutKeyCode, forKey: Keys.livePasteShortcutKeyCode) }
    }

    private var livePasteShortcutCarbonModifierFlags: UInt32 {
        didSet {
            defaults.set(
                livePasteShortcutCarbonModifierFlags,
                forKey: Keys.livePasteShortcutModifiers)
        }
    }

    init(
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.defaults = defaults

        let configuredProvider = Self.loadString(
            defaults: defaults, key: Keys.realtimeProvider,
            envKey: "REALTIME_PROVIDER", fallback: RealtimeProvider.realtimeAPI.rawValue,
            environment: environment
        )
        realtimeProvider = RealtimeProvider(rawValue: configuredProvider) ?? .realtimeAPI

        realtimeAPIEndpointURL = Self.loadString(
            defaults: defaults, key: Keys.realtimeAPIEndpointURL,
            envKey: "REALTIME_ENDPOINT", fallback: RealtimeProvider.realtimeAPI.defaultEndpoint,
            environment: environment
        )

        mlxAudioEndpointURL = Self.loadString(
            defaults: defaults, key: Keys.mlxAudioEndpointURL,
            envKey: "MLX_AUDIO_REALTIME_ENDPOINT",
            fallback: RealtimeProvider.mlxAudio.defaultEndpoint,
            environment: environment
        )

        apiKey = Self.loadString(
            defaults: defaults, key: Keys.apiKey,
            envKey: "OPENAI_API_KEY", fallback: "",
            environment: environment
        )

        realtimeAPIModelName = Self.loadModelName(
            defaults: defaults, key: Keys.realtimeAPIModelName,
            envKey: "REALTIME_MODEL", provider: .realtimeAPI,
            environment: environment
        )

        mlxAudioModelName = Self.loadModelName(
            defaults: defaults, key: Keys.mlxAudioModelName,
            envKey: "MLX_AUDIO_REALTIME_MODEL", provider: .mlxAudio,
            environment: environment
        )

        let storedInterval = defaults.double(forKey: Keys.commitIntervalSeconds)
        commitIntervalSeconds =
            storedInterval > 0
            ? min(max(storedInterval, 0.1), 1.0)
            : 0.9

        let delayDefault = 900
        if defaults.object(forKey: Keys.mlxAudioTranscriptionDelayMilliseconds) != nil {
            mlxAudioTranscriptionDelayMilliseconds = Self.clampedTranscriptionDelay(
                defaults.integer(forKey: Keys.mlxAudioTranscriptionDelayMilliseconds))
        } else if let envDelay = environment["MLX_AUDIO_REALTIME_TRANSCRIPTION_DELAY_MS"],
            let parsedDelay = Int(envDelay)
        {
            mlxAudioTranscriptionDelayMilliseconds = Self.clampedTranscriptionDelay(parsedDelay)
        } else {
            mlxAudioTranscriptionDelayMilliseconds = delayDefault
        }

        autoCopyEnabled = Self.loadBool(
            defaults: defaults, key: Keys.autoCopyEnabled, fallback: false)
        if let storedOutputMode = defaults.string(forKey: Keys.dictationOutputMode),
            let parsedMode = DictationOutputMode(rawValue: storedOutputMode)
        {
            dictationOutputMode = parsedMode
        } else {
            dictationOutputMode = .overlayBuffer
        }
        if let storedShortcutMode = defaults.string(forKey: Keys.dictationShortcutMode),
            let parsedShortcutMode = DictationShortcutMode(rawValue: storedShortcutMode)
        {
            dictationShortcutMode = parsedShortcutMode
        } else {
            dictationShortcutMode = .toggle
        }
        selectedInputDeviceUID = defaults.string(forKey: Keys.selectedInputDeviceUID) ?? ""
        dictationShortcutEnabled = Self.loadBool(
            defaults: defaults, key: Keys.dictationShortcutEnabled, fallback: true)

        let storedKeyCode = (defaults.object(forKey: Keys.dictationShortcutKeyCode) as? NSNumber)?
            .uint32Value
        let storedModifierFlags =
            (defaults.object(forKey: Keys.dictationShortcutCarbonModifierFlags) as? NSNumber)?
            .uint32Value

        let resolvedShortcut: DictationShortcut
        if let storedKeyCode, let storedModifierFlags {
            let candidate = DictationShortcut(
                keyCode: storedKeyCode,
                carbonModifierFlags: storedModifierFlags
            ).normalized
            resolvedShortcut =
                DictationShortcutValidation.persistenceErrorMessage(for: candidate) == nil
                ? candidate : Self.defaultDictationShortcut
        } else {
            resolvedShortcut = Self.defaultDictationShortcut
        }

        dictationShortcutKeyCode = resolvedShortcut.keyCode
        dictationShortcutCarbonModifierFlags = resolvedShortcut.carbonModifierFlags

        llmPolishingEnabled = Self.loadBool(
            defaults: defaults, key: Keys.llmPolishingEnabled, fallback: false)
        llmPolishingEndpointURL = Self.loadString(
            defaults: defaults, key: Keys.llmPolishingEndpointURL,
            envKey: "LLM_POLISHING_ENDPOINT",
            fallback: "http://127.0.0.1:8080/v1/chat/completions",
            environment: environment
        )
        llmPolishingAPIKey = Self.loadString(
            defaults: defaults, key: Keys.llmPolishingAPIKey,
            envKey: "LLM_POLISHING_API_KEY", fallback: "",
            environment: environment
        )
        llmPolishingModel = Self.loadString(
            defaults: defaults, key: Keys.llmPolishingModel,
            envKey: "LLM_POLISHING_MODEL", fallback: "mlx-community/Qwen3.5-0.8B-8bit",
            environment: environment
        )
        replacementDictionaryEnabled = Self.loadBool(
            defaults: defaults, key: Keys.replacementDictionaryEnabled, fallback: false)
        audioDuckingEnabled = Self.loadBool(
            defaults: defaults, key: Keys.audioDuckingEnabled, fallback: false)
        let storedDuckingLevel = defaults.object(forKey: Keys.audioDuckingLevel) != nil
            ? defaults.double(forKey: Keys.audioDuckingLevel)
            : 0.2
        audioDuckingLevel = min(max(storedDuckingLevel, 0.0), 1.0)
        audioDuckingUseDDC = Self.loadBool(
            defaults: defaults, key: Keys.audioDuckingUseDDC, fallback: true)
        let storedFadeIn = defaults.object(forKey: Keys.audioDuckingFadeInDuration) != nil
            ? defaults.double(forKey: Keys.audioDuckingFadeInDuration)
            : 1.5
        audioDuckingFadeInDuration = min(max(storedFadeIn, 0.3), 5.0)
        modifierOnlyHotKeyEnabled = Self.loadBool(
            defaults: defaults, key: Keys.modifierOnlyHotKeyEnabled, fallback: false)
        if let storedModifier = defaults.string(forKey: Keys.modifierOnlyHotKeyModifier),
           let parsed = ModifierOnlyHotKeyManager.ModifierKey(rawValue: storedModifier)
        {
            modifierOnlyHotKeyModifier = parsed
        } else {
            modifierOnlyHotKeyModifier = .fn
        }
        let storedHoldDelay = defaults.object(forKey: Keys.modifierOnlyHoldDelay) != nil
            ? defaults.double(forKey: Keys.modifierOnlyHoldDelay)
            : 0.35
        modifierOnlyHoldDelay = min(max(storedHoldDelay, 0.15), 0.8)
        overlayLastX = defaults.double(forKey: Keys.overlayLastX)
        overlayLastY = defaults.double(forKey: Keys.overlayLastY)
        overlayPositionSaved = Self.loadBool(
            defaults: defaults, key: Keys.overlayPositionSaved, fallback: false)

        // --- Dual shortcut keys ---

        // Check if overlay buffer shortcut keys already exist
        let hasExistingOverlayKeys = defaults.object(forKey: Keys.overlayBufferShortcutKeyCode) != nil
        var needsOverlayMigrationPersist = false

        if hasExistingOverlayKeys {
            // Load existing overlay buffer shortcut
            let obKeyCode = (defaults.object(forKey: Keys.overlayBufferShortcutKeyCode) as? NSNumber)?
                .uint32Value ?? 0
            let obModifiers = (defaults.object(forKey: Keys.overlayBufferShortcutModifiers) as? NSNumber)?
                .uint32Value ?? 0
            let obCandidate = DictationShortcut(keyCode: obKeyCode, carbonModifierFlags: obModifiers).normalized
            if DictationShortcutValidation.persistenceErrorMessage(for: obCandidate) == nil {
                overlayBufferShortcutKeyCode = obCandidate.keyCode
                overlayBufferShortcutCarbonModifierFlags = obCandidate.carbonModifierFlags
            } else {
                overlayBufferShortcutKeyCode = 0
                overlayBufferShortcutCarbonModifierFlags = 0
            }
            overlayBufferShortcutEnabled = Self.loadBool(
                defaults: defaults, key: Keys.overlayBufferShortcutEnabled, fallback: true)
        } else if storedKeyCode != nil, storedModifierFlags != nil {
            // Migration: copy legacy shortcut → overlay buffer shortcut
            overlayBufferShortcutKeyCode = resolvedShortcut.keyCode
            overlayBufferShortcutCarbonModifierFlags = resolvedShortcut.carbonModifierFlags
            overlayBufferShortcutEnabled = Self.loadBool(
                defaults: defaults, key: Keys.dictationShortcutEnabled, fallback: true)
            needsOverlayMigrationPersist = true
        } else {
            // Fresh install — use default shortcut for overlay
            overlayBufferShortcutKeyCode = Self.defaultDictationShortcut.keyCode
            overlayBufferShortcutCarbonModifierFlags = Self.defaultDictationShortcut.carbonModifierFlags
            overlayBufferShortcutEnabled = true
        }

        // Live paste shortcut — defaults to disabled/nil
        let hasExistingLivePasteKeys = defaults.object(forKey: Keys.livePasteShortcutKeyCode) != nil
        if hasExistingLivePasteKeys {
            let lpKeyCode = (defaults.object(forKey: Keys.livePasteShortcutKeyCode) as? NSNumber)?
                .uint32Value ?? 0
            let lpModifiers = (defaults.object(forKey: Keys.livePasteShortcutModifiers) as? NSNumber)?
                .uint32Value ?? 0
            let lpCandidate = DictationShortcut(keyCode: lpKeyCode, carbonModifierFlags: lpModifiers).normalized
            if DictationShortcutValidation.persistenceErrorMessage(for: lpCandidate) == nil {
                livePasteShortcutKeyCode = lpCandidate.keyCode
                livePasteShortcutCarbonModifierFlags = lpCandidate.carbonModifierFlags
            } else {
                livePasteShortcutKeyCode = 0
                livePasteShortcutCarbonModifierFlags = 0
            }
            livePasteShortcutEnabled = Self.loadBool(
                defaults: defaults, key: Keys.livePasteShortcutEnabled, fallback: false)
        } else {
            livePasteShortcutKeyCode = 0
            livePasteShortcutCarbonModifierFlags = 0
            livePasteShortcutEnabled = false
        }

        // Persist migrated overlay values after all stored properties are initialized
        if needsOverlayMigrationPersist {
            defaults.set(overlayBufferShortcutKeyCode, forKey: Keys.overlayBufferShortcutKeyCode)
            defaults.set(overlayBufferShortcutCarbonModifierFlags, forKey: Keys.overlayBufferShortcutModifiers)
            defaults.set(overlayBufferShortcutEnabled, forKey: Keys.overlayBufferShortcutEnabled)
        }
    }

    // MARK: - Init Helpers

    private static func loadString(
        defaults: UserDefaults, key: String, envKey: String, fallback: String,
        environment: [String: String]
    ) -> String {
        defaults.string(forKey: key)
            ?? environment[envKey]
            ?? fallback
    }

    private static func loadBool(
        defaults: UserDefaults, key: String, fallback: Bool
    ) -> Bool {
        defaults.object(forKey: key) != nil
            ? defaults.bool(forKey: key)
            : fallback
    }

    private static func loadModelName(
        defaults: UserDefaults,
        key: String,
        envKey: String,
        provider: RealtimeProvider,
        environment: [String: String]
    ) -> String {
        let configured = loadString(
            defaults: defaults,
            key: key,
            envKey: envKey,
            fallback: provider.defaultModelName,
            environment: environment
        )
        let normalized = normalizedModelName(from: configured)
        return normalized.isEmpty ? provider.defaultModelName : normalized
    }

    var trimmedAPIKey: String {
        apiKey.trimmed
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

    // MARK: - Dual Shortcuts (per output mode)

    var overlayBufferShortcut: DictationShortcut? {
        guard overlayBufferShortcutEnabled else { return nil }

        let candidate = DictationShortcut(
            keyCode: overlayBufferShortcutKeyCode,
            carbonModifierFlags: overlayBufferShortcutCarbonModifierFlags
        ).normalized

        if DictationShortcutValidation.persistenceErrorMessage(for: candidate) != nil {
            return nil
        }

        return candidate
    }

    var livePasteShortcut: DictationShortcut? {
        guard livePasteShortcutEnabled else { return nil }

        let candidate = DictationShortcut(
            keyCode: livePasteShortcutKeyCode,
            carbonModifierFlags: livePasteShortcutCarbonModifierFlags
        ).normalized

        if DictationShortcutValidation.persistenceErrorMessage(for: candidate) != nil {
            return nil
        }

        return candidate
    }

    func setOverlayBufferShortcut(_ shortcut: DictationShortcut?) {
        guard let shortcut else {
            overlayBufferShortcutEnabled = false
            return
        }

        let normalizedShortcut = shortcut.normalized
        if DictationShortcutValidation.persistenceErrorMessage(for: normalizedShortcut) == nil {
            overlayBufferShortcutKeyCode = normalizedShortcut.keyCode
            overlayBufferShortcutCarbonModifierFlags = normalizedShortcut.carbonModifierFlags
        } else {
            overlayBufferShortcutKeyCode = Self.defaultDictationShortcut.keyCode
            overlayBufferShortcutCarbonModifierFlags = Self.defaultDictationShortcut.carbonModifierFlags
        }
        overlayBufferShortcutEnabled = true
    }

    func setLivePasteShortcut(_ shortcut: DictationShortcut?) {
        guard let shortcut else {
            livePasteShortcutEnabled = false
            return
        }

        let normalizedShortcut = shortcut.normalized
        if DictationShortcutValidation.persistenceErrorMessage(for: normalizedShortcut) == nil {
            livePasteShortcutKeyCode = normalizedShortcut.keyCode
            livePasteShortcutCarbonModifierFlags = normalizedShortcut.carbonModifierFlags
        } else {
            return
        }
        livePasteShortcutEnabled = true
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
        let trimmed = endpointURL(for: provider).trimmed
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
        let trimmed = raw.trimmed
        guard !trimmed.isEmpty else { return "" }

        let lines =
            trimmed
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmed }
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

    var llmPolishingConfiguration: LLMPolishingConfiguration? {
        guard llmPolishingEnabled else { return nil }
        let trimmedEndpoint = llmPolishingEndpointURL.trimmed
        guard !trimmedEndpoint.isEmpty, let url = URL(string: trimmedEndpoint) else { return nil }
        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let scheme = components.scheme?.lowercased(),
            (scheme == "http" || scheme == "https"),
            components.host != nil
        else {
            return nil
        }
        return LLMPolishingConfiguration(
            endpointURL: url,
            apiKey: llmPolishingAPIKey.trimmed,
            model: llmPolishingModel.trimmed.isEmpty
                ? "mlx-community/Qwen3.5-0.8B-8bit"
                : llmPolishingModel.trimmed
        )
    }
}

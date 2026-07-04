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

enum DictationOutputMode: String, CaseIterable, Identifiable, Sendable {
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

enum BackendMode: String, CaseIterable, Identifiable {
    case managedLocal = "managed_local"
    case externalURL = "external_url"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .managedLocal:
            return "Managed local"
        case .externalURL:
            return "External URL"
        }
    }

    var dictationDescription: String {
        switch self {
        case .managedLocal:
            return "Installs and runs voxmlx on this Mac."
        case .externalURL:
            return "Use an OpenAI Realtime-compatible endpoint you run yourself."
        }
    }

    var polishingDescription: String {
        switch self {
        case .managedLocal:
            return "Installs and runs mlx-lm on this Mac."
        case .externalURL:
            return "Use an OpenAI-compatible chat completions endpoint you run yourself."
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

        var id: String { rawValue }

        var displayName: String { "vLLM / OpenAI" }

        var defaultEndpoint: String { "ws://127.0.0.1:8000/v1/realtime" }

        var defaultModelName: String { "T0mSIlver/Voxtral-Mini-4B-Realtime-2602-MLX-4bit" }
    }

    private enum Keys {
        static let realtimeProvider = "settings.realtime_provider"
        static let realtimeAPIEndpointURL = "settings.realtime_api_endpoint_url"
        static let apiKey = "settings.api_key"
        static let realtimeAPIModelName = "settings.realtime_api_model_name"
        static let dictationBackendMode = "settings.dictation_backend_mode"
        static let polishingBackendMode = "settings.polishing_backend_mode"
        // Legacy global backend mode. Read only for one-time migration.
        static let backendMode = "settings.backend_mode"
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
        /// Hidden debug toggle (no UI). When true, every received realtime
        /// event's raw payload is logged to the `Deltas` category before any
        /// merge/preprocess/insertion processing — instrumentation for
        /// diagnosing issue #13 (mid-word punctuation in Live Auto-Paste).
        /// Note the `debug.` prefix (not `settings.`): this is not a
        /// user-facing preference and must never surface in the settings UI.
        static let debugLogRealtimeDeltas = "debug.log_realtime_deltas"
        static let modifierOnlyHotKeyEnabled = "settings.modifier_only_hotkey_enabled"
        static let modifierOnlyHotKeyModifier = "settings.modifier_only_hotkey_modifier"
        static let modifierOnlyHoldDelay = "settings.modifier_only_hold_delay"
        static let overlayBufferShortcutKeyCode = "settings.overlay_buffer_shortcut_key_code"
        static let overlayBufferShortcutModifiers =
            "settings.overlay_buffer_shortcut_carbon_modifiers"
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

    /// Default model for the OpenAI-compatible LLM polishing server. Used as
    /// the external-mode fallback and as the model the managed mlx-lm backend
    /// is expected to serve.
    static let defaultLLMPolishingModel = "mlx-community/Qwen3.5-0.8B-8bit"

    var realtimeProvider: RealtimeProvider {
        didSet { defaults.set(realtimeProvider.rawValue, forKey: Keys.realtimeProvider) }
    }

    var dictationBackendMode: BackendMode {
        didSet { defaults.set(dictationBackendMode.rawValue, forKey: Keys.dictationBackendMode) }
    }

    var polishingBackendMode: BackendMode {
        didSet { defaults.set(polishingBackendMode.rawValue, forKey: Keys.polishingBackendMode) }
    }

    var realtimeAPIEndpointURL: String {
        didSet { defaults.set(realtimeAPIEndpointURL, forKey: Keys.realtimeAPIEndpointURL) }
    }

    var apiKey: String {
        didSet { defaults.set(apiKey, forKey: Keys.apiKey) }
    }

    var realtimeAPIModelName: String {
        didSet { defaults.set(realtimeAPIModelName, forKey: Keys.realtimeAPIModelName) }
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

    /// Hidden debug flag for issue #13 instrumentation. Default false. When
    /// enabled, `DictationViewModel` logs the exact payload of every received
    /// realtime event (partial deltas quoted so whitespace is visible, final
    /// transcripts, and session boundaries) to `Log.deltas` (notice level)
    /// BEFORE any merge/preprocess/insertion processing.
    ///
    /// Privacy: this logs dictated content in cleartext. That is the explicit
    /// purpose of an opt-in debug flag, so payloads are marked `.public` to
    /// make whitespace and punctuation visible in `log stream` / Console. Only
    /// enable it for a capture you intend to share; leave it off otherwise.
    /// There is no UI for this setting — it is toggled via `defaults`:
    ///   `defaults write com.localvoxtral.app debug.log_realtime_deltas -bool true`
    var debugLogRealtimeDeltas: Bool {
        didSet { defaults.set(debugLogRealtimeDeltas, forKey: Keys.debugLogRealtimeDeltas) }
    }

    var modifierOnlyHotKeyEnabled: Bool {
        didSet { defaults.set(modifierOnlyHotKeyEnabled, forKey: Keys.modifierOnlyHotKeyEnabled) }
    }

    var modifierOnlyHotKeyModifier: ModifierOnlyHotKeyManager.ModifierKey {
        didSet {
            defaults.set(modifierOnlyHotKeyModifier.rawValue, forKey: Keys.modifierOnlyHotKeyModifier)
        }
    }

    /// Seconds to hold modifier before it triggers live auto-paste (0.1-0.8).
    var modifierOnlyHoldDelay: Double {
        didSet { defaults.set(modifierOnlyHoldDelay, forKey: Keys.modifierOnlyHoldDelay) }
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

        let resolvedBackendModes = Self.resolveBackendModes(defaults: defaults, environment: environment)
        dictationBackendMode = resolvedBackendModes.dictation
        polishingBackendMode = resolvedBackendModes.polishing
        defaults.set(resolvedBackendModes.dictation.rawValue, forKey: Keys.dictationBackendMode)
        defaults.set(resolvedBackendModes.polishing.rawValue, forKey: Keys.polishingBackendMode)

        let configuredProvider = Self.loadString(
            defaults: defaults, key: Keys.realtimeProvider,
            envKey: "REALTIME_PROVIDER", fallback: RealtimeProvider.realtimeAPI.rawValue,
            environment: environment
        )
        // A previously-selected provider may no longer exist (deprecated backends
        // have been removed). Fall back to the default rather than crash or
        // produce an invalid state.
        realtimeProvider = RealtimeProvider(rawValue: configuredProvider) ?? .realtimeAPI

        // The commit interval setting was removed. Clean up stale persisted
        // values so future defaults migrations do not preserve dead state.
        defaults.removeObject(forKey: "settings.commit_interval_seconds")

        realtimeAPIEndpointURL = Self.loadString(
            defaults: defaults, key: Keys.realtimeAPIEndpointURL,
            envKey: "REALTIME_ENDPOINT", fallback: RealtimeProvider.realtimeAPI.defaultEndpoint,
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
            envKey: "LLM_POLISHING_MODEL", fallback: Self.defaultLLMPolishingModel,
            environment: environment
        )
        replacementDictionaryEnabled = Self.loadBool(
            defaults: defaults, key: Keys.replacementDictionaryEnabled, fallback: false)
        debugLogRealtimeDeltas = Self.loadBool(
            defaults: defaults, key: Keys.debugLogRealtimeDeltas, fallback: false)
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
        modifierOnlyHoldDelay = min(max(storedHoldDelay, 0.1), 0.8)

        // --- Dual shortcut keys ---
        let hasExistingOverlayKeys = defaults.object(forKey: Keys.overlayBufferShortcutKeyCode) != nil
        var needsOverlayMigrationPersist = false

        if hasExistingOverlayKeys {
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
            overlayBufferShortcutKeyCode = resolvedShortcut.keyCode
            overlayBufferShortcutCarbonModifierFlags = resolvedShortcut.carbonModifierFlags
            overlayBufferShortcutEnabled = Self.loadBool(
                defaults: defaults, key: Keys.dictationShortcutEnabled, fallback: true)
            needsOverlayMigrationPersist = true
        } else {
            overlayBufferShortcutKeyCode = Self.defaultDictationShortcut.keyCode
            overlayBufferShortcutCarbonModifierFlags = Self.defaultDictationShortcut.carbonModifierFlags
            overlayBufferShortcutEnabled = true
        }

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

        if needsOverlayMigrationPersist {
            defaults.set(overlayBufferShortcutKeyCode, forKey: Keys.overlayBufferShortcutKeyCode)
            defaults.set(
                overlayBufferShortcutCarbonModifierFlags,
                forKey: Keys.overlayBufferShortcutModifiers)
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

    private static func resolveBackendModes(
        defaults: UserDefaults,
        environment: [String: String]
    ) -> (dictation: BackendMode, polishing: BackendMode) {
        let storedDictationMode = defaults.string(forKey: Keys.dictationBackendMode)
            .flatMap(BackendMode.init(rawValue:))
        let storedPolishingMode = defaults.string(forKey: Keys.polishingBackendMode)
            .flatMap(BackendMode.init(rawValue:))

        if let storedDictationMode, let storedPolishingMode {
            return (storedDictationMode, storedPolishingMode)
        }

        let migratedMode: BackendMode
        if let storedBackendMode = defaults.string(forKey: Keys.backendMode),
            let parsedBackendMode = BackendMode(rawValue: storedBackendMode)
        {
            migratedMode = parsedBackendMode
        } else if defaults.string(forKey: Keys.realtimeAPIEndpointURL) != nil
            || environment["REALTIME_ENDPOINT"] != nil
        {
            migratedMode = .externalURL
        } else {
            migratedMode = .managedLocal
        }

        return (
            storedDictationMode ?? migratedMode,
            storedPolishingMode ?? migratedMode
        )
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
        // `trimmedAPIKey` is only ever used as the realtime connection bearer
        // token (see RealtimeAPIWebSocketClient, which omits the Authorization
        // header when it is empty). Managed local servers need no key.
        dictationBackendMode == .managedLocal ? "" : apiKey.trimmed
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
        realtimeAPIModelName
    }

    func effectiveModelName(for provider: RealtimeProvider) -> String {
        if dictationBackendMode == .managedLocal {
            // Managed mode always serves the managed default model; a
            // user-typed override in external-mode fields is ignored.
            return RealtimeProvider.realtimeAPI.defaultModelName
        }
        let normalized = Self.normalizedModelName(from: modelName(for: provider))
        return normalized.isEmpty ? provider.defaultModelName : normalized
    }

    func endpointURL(for provider: RealtimeProvider) -> String {
        realtimeAPIEndpointURL
    }

    var resolvedWebSocketURL: URL? {
        resolvedWebSocketURL(for: realtimeProvider)
    }

    func resolvedWebSocketURL(for provider: RealtimeProvider) -> URL? {
        if dictationBackendMode == .managedLocal {
            return URL(string: ManagedBackendEndpoints.realtimeURLString)
        }
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

    var llmPolishingConfiguration: LLMPolishingConfiguration? {
        guard llmPolishingEnabled else { return nil }
        if polishingBackendMode == .managedLocal {
            guard let url = URL(string: ManagedBackendEndpoints.polishingURLString)
            else { return nil }
            return LLMPolishingConfiguration(
                endpointURL: url,
                apiKey: "",
                model: Self.defaultLLMPolishingModel
            )
        }
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
                ? Self.defaultLLMPolishingModel
                : llmPolishingModel.trimmed
        )
    }
}

import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Observation
import Synchronization

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

}

enum BackendMode: String, CaseIterable, Identifiable {
    case managedLocal = "managed_local"
    case externalURL = "external_url"
    /// Mistral's hosted API: the realtime transcription socket for dictation
    /// (`MistralRealtimeWebSocketClient`) and `/v1/chat/completions` for
    /// polishing, both authenticated with the one shared Mistral API key.
    case mistralAPI = "mistral_api"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .managedLocal:
            return "Managed local"
        case .externalURL:
            return "External URL"
        case .mistralAPI:
            return "Mistral API"
        }
    }

    /// Whether this mode runs on a bundled helper this app supervises. The
    /// engine lifecycle (warmup, shutdown, readiness) keys off this rather
    /// than off `.externalURL`, so every hosted mode behaves the same way.
    var isManaged: Bool { self == .managedLocal }
}

/// Metal buffer-pool cache limit for the managed dictation helper. `Auto`
/// omits the `--cache-limit-mb` flag so the helper's built-in default applies;
/// every other case pins an explicit ceiling.
enum SpeechdCacheLimit: String, CaseIterable, Identifiable, Sendable {
    case auto
    case gb2 = "2gb"
    case gb4 = "4gb"
    case gb6 = "6gb"
    case gb8 = "8gb"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .gb2: return "2 GB"
        case .gb4: return "4 GB"
        case .gb6: return "6 GB"
        case .gb8: return "8 GB"
        }
    }

    /// Megabytes to pass via `--cache-limit-mb`, or nil for `Auto` (the flag is
    /// omitted and the helper's built-in default applies).
    var megabytes: Int? {
        switch self {
        case .auto: return nil
        case .gb2: return 2048
        case .gb4: return 4096
        case .gb6: return 6144
        case .gb8: return 8192
        }
    }
}

/// How often the hosted "Suggest terms" pass runs by itself, in saved
/// dictations (`TermSuggestionCadence`). `never` leaves only the button.
enum TermSuggestionInterval: Int, CaseIterable, Identifiable, Sendable {
    case every25 = 25
    case every50 = 50
    case every100 = 100
    case every200 = 200
    case never = 0

    var id: Int { rawValue }

    /// Nil for `never`.
    var dictations: Int? { self == .never ? nil : rawValue }

    var displayName: String {
        dictations.map { "Every \($0) dictations" } ?? "Never"
    }
}

/// How long a saved dictation stays in the history store
/// (`DictationSessionStore`). The store holds everything the user said, in
/// plain text, so the rule is a privacy setting first and a disk one second.
enum DictationHistoryRetention: String, CaseIterable, Identifiable, Sendable {
    case forever
    case days90 = "90d"
    case days30 = "30d"
    case days7 = "7d"
    /// Nothing is saved, and what was saved is deleted.
    case off

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .forever: return "Forever"
        case .days90: return "90 days"
        case .days30: return "30 days"
        case .days7: return "7 days"
        case .off: return "Don't keep"
        }
    }

    /// Nil for `forever` and `off`, which are not an age.
    var days: Int? {
        switch self {
        case .forever, .off: return nil
        case .days90: return 90
        case .days30: return 30
        case .days7: return 7
        }
    }

    var savesDictations: Bool { self != .off }

    /// Dictations that started before this are deleted. Nil keeps everything;
    /// `off` answers `.distantFuture`, which is every dictation there is.
    func cutoff(now: Date) -> Date? {
        if self == .off { return .distantFuture }
        return days.map { now.addingTimeInterval(-Double($0) * 86_400) }
    }

    /// Whether moving to `other` deletes dictations this rule would keep.
    func keepsLonger(than other: DictationHistoryRetention) -> Bool {
        func reach(_ rule: DictationHistoryRetention) -> Int {
            switch rule {
            case .forever: return .max
            case .off: return 0
            default: return rule.days ?? 0
            }
        }
        return reach(self) > reach(other)
    }
}

/// Streaming step cadence for the managed dictation helper: how much audio is
/// batched before each incremental transcription step. Lower values show words
/// sooner; higher values leave more compute headroom. `Auto` omits the
/// `--step-ms` flag so the helper's built-in default applies.
enum SpeechdStepCadence: String, CaseIterable, Identifiable, Sendable {
    case auto
    case ms100 = "100ms"
    case ms240 = "240ms"
    case ms480 = "480ms"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .ms100: return "100 ms"
        case .ms240: return "240 ms"
        case .ms480: return "480 ms"
        }
    }

    /// Milliseconds to pass via `--step-ms`, or nil for `Auto` (the flag is
    /// omitted and the helper's built-in default applies).
    var milliseconds: Int? {
        switch self {
        case .auto: return nil
        case .ms100: return 100
        case .ms240: return 240
        case .ms480: return 480
        }
    }
}

enum DictationShortcutValidation {
    static let allowedModifierFlagsMask = UInt32(cmdKey | optionKey | shiftKey | controlKey)

    static func normalizedModifierFlags(_ flags: UInt32) -> UInt32 {
        flags & allowedModifierFlagsMask
    }

    /// The one key class accepted with no modifier at all. The bare-key rule
    /// exists so nobody binds the letter `a` and loses the ability to type it;
    /// a function key has no typing role to swallow, and F13-F20 in particular
    /// are dedicated keys whose only plausible use is a trigger like this one.
    /// Letters, digits, punctuation, Space and Return still need a modifier.
    ///
    /// F1-F12 are included (#377 asks for the whole range) but only fire on a
    /// keyboard that sends them as function keys: with macOS's default "Use
    /// F1, F2, etc. keys as standard function keys" OFF, the system claims the
    /// press for brightness or media and no app sees it. `docs/dictation.md`
    /// carries that caveat, since a shortcut that registers and never fires
    /// looks like a bug from the outside.
    ///
    /// What arrives here is already `normalized`: ShortcutRecorder reports
    /// F1-F20 with `NSFunctionKeyMask` set, and the mask above is what turns
    /// that into "no modifier" (`testValidation_stripsTheRecorderFunctionKeyBit`).
    static let functionKeyCodes: Set<UInt32> = [
        UInt32(kVK_F1), UInt32(kVK_F2), UInt32(kVK_F3), UInt32(kVK_F4),
        UInt32(kVK_F5), UInt32(kVK_F6), UInt32(kVK_F7), UInt32(kVK_F8),
        UInt32(kVK_F9), UInt32(kVK_F10), UInt32(kVK_F11), UInt32(kVK_F12),
        UInt32(kVK_F13), UInt32(kVK_F14), UInt32(kVK_F15), UInt32(kVK_F16),
        UInt32(kVK_F17), UInt32(kVK_F18), UInt32(kVK_F19), UInt32(kVK_F20),
    ]

    static func isFunctionKey(_ keyCode: UInt32) -> Bool {
        functionKeyCodes.contains(keyCode)
    }

    static func persistenceErrorMessage(for shortcut: DictationShortcut) -> String? {
        if shortcut.keyCode > UInt32(UInt16.max) {
            return "Shortcut key is not supported."
        }

        if normalizedModifierFlags(shortcut.carbonModifierFlags) == 0,
            !isFunctionKey(shortcut.keyCode)
        {
            return "Shortcut needs a modifier key. Only function keys work on their own."
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

        /// Placeholder/default for External URL mode only (managed mode always
        /// uses `SpeechModelCatalog.defaultOption`). The default endpoint above
        /// is the local speechd test service, so this tracks the same checkpoint
        /// the rest of the project pins.
        var defaultModelName: String { "T0mSIlver/Voxtral-Mini-4B-Realtime-2602-4bit-qhead" }
    }

    private enum Keys {
        static let realtimeProvider = "settings.realtime_provider"
        static let realtimeAPIEndpointURL = "settings.realtime_api_endpoint_url"
        /// LEGACY. The three API keys now live in the login Keychain
        /// (`SecretKey` / `KeychainSecretStore`); these defaults keys exist
        /// only so `migrateLegacySecrets` can find and remove a value
        /// written by a build that predates the move. Nothing else may read
        /// or write them.
        static let apiKey = "settings.api_key"
        static let realtimeAPIModelName = "settings.realtime_api_model_name"
        /// LEGACY, see `apiKey`. ONE key for both Mistral engines — the account
        /// is one account, and asking for the same secret twice is how a
        /// working dictation ends up beside a 401-ing polish.
        static let mistralAPIKey = "settings.mistral_api_key"
        /// Set once the whole sweep out of UserDefaults succeeded, so later
        /// launches never re-read the plist. Deliberately not cleared by
        /// anything: a false value only costs one extra (cheap) sweep.
        static let apiKeysMigratedToKeychain = "settings.api_keys_migrated_to_keychain"
        static let mistralDictationModel = "settings.mistral_dictation_model"
        static let mistralPolishingModel = "settings.mistral_polishing_model"
        static let mistralModelCatalog = "settings.mistral_model_catalog"
        static let dictationBackendMode = "settings.dictation_backend_mode"
        static let speechdCacheLimit = "settings.speechd_cache_limit"
        static let speechdStepCadence = "settings.speechd_step_cadence"
        static let managedSpeechModel = "settings.managed_speech_model"
        static let polishingBackendMode = "settings.polishing_backend_mode"
        // Legacy global backend mode. Read only for one-time migration.
        static let backendMode = "settings.backend_mode"
        static let onboardingCompleted = "settings.onboarding_completed"
        static let opensWindowAtLaunch = "settings.opens_window_at_launch"
        static let dictationOutputMode = "settings.dictation_output_mode"
        static let dictationShortcutMode = "settings.dictation_shortcut_mode"
        static let autoCopyEnabled = "settings.auto_copy_enabled"
        static let audioDuckingEnabled = "settings.audio_ducking_enabled"
        static let audioDuckingFadeDuration = "settings.audio_ducking_fade_duration"
        /// The device and volume a launch ducked away from, written at the
        /// duck and cleared when a restore lands. Present at startup only when
        /// the previous launch died mid-session. Both keys or neither.
        static let audioDuckingPendingRestoreVolume =
            "settings.audio_ducking_pending_restore_volume"
        static let audioDuckingPendingRestoreDeviceUID =
            "settings.audio_ducking_pending_restore_device_uid"
        static let selectedInputDeviceUID = "settings.selected_input_device_uid"
        static let selectedInputChannel = "settings.selected_input_channel"
        static let dictationShortcutEnabled = "settings.dictation_shortcut_enabled"
        static let dictationShortcutKeyCode = "settings.dictation_shortcut_key_code"
        static let dictationShortcutCarbonModifierFlags =
            "settings.dictation_shortcut_carbon_modifiers"
        static let llmPolishingEnabled = "settings.llm_polishing_enabled"
        static let llmPolishingEndpointURL = "settings.llm_polishing_endpoint_url"
        /// LEGACY, see `apiKey`.
        static let llmPolishingAPIKey = "settings.llm_polishing_api_key"
        static let llmPolishingModel = "settings.llm_polishing_model"
        static let managedLLMPolishingModel = "settings.managed_llm_polishing_model"
        static let replacementDictionaryEnabled = "settings.replacement_dictionary_enabled"
        static let agentPolishProfileEnabled = "settings.agent_polish_profile_enabled"
        static let polishClipboardContextEnabled = "settings.polish_clipboard_context_enabled"
        static let polishSpeakerProfile = "settings.polish_speaker_profile"
        static let polishSpeakerTerms = "settings.polish_speaker_terms"
        static let polishDismissedTermSuggestions = "settings.polish_dismissed_term_suggestions"
        static let termSuggestionInterval = "settings.term_suggestion_interval"
        static let termSuggestionDictationsSinceRun = "settings.term_suggestion_dictations_since_run"
        static let termSuggestionRetryAt = "settings.term_suggestion_retry_at"
        static let dictationHistoryRetention = "settings.dictation_history_retention"
        static let clipboardPayloadMacroEnabled = "settings.clipboard_payload_macro_enabled"
        static let terminalScreenContextEnabled = "settings.terminal_screen_context_enabled"
        static let repoVocabularyEnabled = "settings.repo_vocabulary_enabled"
        static let claudeRepoContextEnabled = "settings.claude_repo_context_enabled"
        static let cmuxSurfaceJoinEnabled = "settings.cmux_surface_join_enabled"
        static let polishContextTrustedEndpointEnabled =
            "settings.polish_context_trusted_endpoint_enabled"
        /// User-added terminal apps (Settings → Terminals → Add app…), stored
        /// as a JSON array of `UserTerminalApp`. Seeded from the legacy
        /// `terminal_apps.toml` once at startup (`UserTerminalAppsMigrator`).
        static let userTerminalApps = "settings.user_terminal_apps"
        /// Hidden debug toggle (no UI). When true, every received realtime
        /// event's raw payload is logged to the `Deltas` category before any
        /// merge/preprocess/insertion processing — instrumentation for
        /// diagnosing issue #13 (mid-word punctuation in Live Auto-Paste).
        /// Note the `debug.` prefix (not `settings.`): this is not a
        /// user-facing preference and must never surface in the settings UI.
        static let debugLogRealtimeDeltas = "debug.log_realtime_deltas"
        #if LOCALVOXTRAL_DOGFOOD
        /// The runtime half of the dogfooding gate. `debug.` prefixed like the
        /// flag above: it exists only in an instrumented build and is not a
        /// product preference.
        static let dogfoodCaptureEnabled = "debug.dogfood_capture_enabled"
        /// The runtime half of the control-socket gate, kept SEPARATE from the
        /// capture one: writing records and opening a socket that can start
        /// dictations are different consents, and an owner running an
        /// instrumented build for capture must not silently acquire a listener.
        static let dogfoodControlSocketEnabled = "debug.dogfood_control_socket_enabled"
        #endif
        static let modifierOnlyHotKeyEnabled = "settings.modifier_only_hotkey_enabled"
        static let modifierOnlyHotKeyModifier = "settings.modifier_only_hotkey_modifier"
        static let modifierOnlyHoldDelay = "settings.modifier_only_hold_delay"
        static let overlayBufferShortcutKeyCode = "settings.overlay_buffer_shortcut_key_code"
        static let overlayBufferShortcutModifiers =
            "settings.overlay_buffer_shortcut_carbon_modifiers"
        static let overlayBufferShortcutEnabled = "settings.overlay_buffer_shortcut_enabled"
        static let overlayBufferFontSize = "settings.overlay_buffer_font_size"
        static let overlayBufferVisibleLines = "settings.overlay_buffer_visible_lines"
        static let overlayBufferPositionScreenID = "settings.overlay_buffer_position_screen_id"
        static let overlayBufferPositionOffsetX = "settings.overlay_buffer_position_offset_x"
        static let overlayBufferPositionOffsetY = "settings.overlay_buffer_position_offset_y"
        static let livePasteShortcutKeyCode = "settings.live_paste_shortcut_key_code"
        static let livePasteShortcutModifiers = "settings.live_paste_shortcut_carbon_modifiers"
        static let livePasteShortcutEnabled = "settings.live_paste_shortcut_enabled"
    }

    private let defaults: UserDefaults
    /// Where the three API keys live. Injected so tests and previews can never
    /// reach the real login keychain (`KeychainSecretStore.init` traps under
    /// XCTest as a backstop).
    private let secretStore: any SecretStoring
    /// Kept past init for the deferred secret reads: an env-provided key has to
    /// resolve the same way later as it does at launch.
    @ObservationIgnored
    private let environment: [String: String]
    /// The secrets already read out of the store, whatever the read returned.
    /// A key not in here has never been fetched — see `ensureSecretsLoaded`.
    @ObservationIgnored
    private var loadedSecretKeys: Set<SecretKey> = []
    /// True only while a fetched value is being assigned to its property, so
    /// the `didSet` write-through does not push it straight back into the
    /// store (a write prompts exactly like a read).
    @ObservationIgnored
    private var isApplyingStoredSecret = false

    /// One short sentence when the secret store refused an operation, else nil.
    /// Rendered in the Engines pane so a locked or broken keychain reads as
    /// exactly that, instead of every key silently looking "not set".
    ///
    /// Sticky for the life of the process on purpose: a later successful write
    /// proves only that ONE key round-tripped, while the others are still blank
    /// in memory, and clearing the warning there would restore the very lie
    /// this property exists to prevent.
    private(set) var secretStoreFailureSummary: String?

    static let defaultDictationShortcut = DictationShortcut(
        keyCode: UInt32(kVK_Space),
        carbonModifierFlags: UInt32(optionKey)
    )

    /// Default model for the OpenAI-compatible LLM polishing server. Used as
    /// the external-mode fallback and as the model the managed polishd backend
    /// is expected to serve.
    static let defaultLLMPolishingModel = PolishModelCatalog.defaultOption.repoID

    var realtimeProvider: RealtimeProvider {
        didSet { defaults.set(realtimeProvider.rawValue, forKey: Keys.realtimeProvider) }
    }

    var dictationBackendMode: BackendMode {
        didSet {
            defaults.set(dictationBackendMode.rawValue, forKey: Keys.dictationBackendMode)
            // The newly selected engine may need a key this process has never
            // read (`ensureSecretsLoaded`).
            ensureSecretsForSelectedEnginesLoaded()
        }
    }

    var polishingBackendMode: BackendMode {
        didSet {
            defaults.set(polishingBackendMode.rawValue, forKey: Keys.polishingBackendMode)
            ensureSecretsForSelectedEnginesLoaded()
        }
    }

    /// Metal buffer-pool cache limit for the managed dictation helper. Changing
    /// it from Settings restarts the engine so the new argv applies immediately
    /// (`EnginesModel.applySpeechdCacheLimitChange`); direct writes apply
    /// on the next (re)start.
    var speechdCacheLimit: SpeechdCacheLimit {
        didSet { defaults.set(speechdCacheLimit.rawValue, forKey: Keys.speechdCacheLimit) }
    }

    /// Streaming step cadence for the managed dictation helper. Same restart
    /// contract as `speechdCacheLimit`.
    var speechdStepCadence: SpeechdStepCadence {
        didSet { defaults.set(speechdStepCadence.rawValue, forKey: Keys.speechdStepCadence) }
    }

    /// Hugging Face repo the managed dictation helper loads, chosen from
    /// `SpeechModelCatalog`. Same restart contract as `speechdCacheLimit`
    /// (`EnginesModel.applyManagedSpeechModelChange`). External URL mode keeps
    /// its own server-side model NAME in `realtimeAPIModelName`; separate keys
    /// so a leftover external value can never leak into a managed launch.
    var managedSpeechModel: String {
        didSet { defaults.set(managedSpeechModel, forKey: Keys.managedSpeechModel) }
    }

    /// True once the user has completed (or skipped) the first-launch onboarding
    /// wizard. Resolved once at init (see `resolveOnboardingCompleted`) and
    /// persisted immediately so the wizard shows exactly once for fresh installs.
    /// The General settings pane's "Re-run setup…" resets it to false.
    var onboardingCompleted: Bool {
        didSet { defaults.set(onboardingCompleted, forKey: Keys.onboardingCompleted) }
    }

    /// Whether a finished launch opens the localvoxtral window on History.
    /// Off by default: the app is a menu bar app, and a login-item launch
    /// would otherwise put a window on screen at every login (#449). A first
    /// launch ignores it — the onboarding wizard is the only window it shows.
    var opensWindowAtLaunch: Bool {
        didSet { defaults.set(opensWindowAtLaunch, forKey: Keys.opensWindowAtLaunch) }
    }

    var realtimeAPIEndpointURL: String {
        didSet { defaults.set(realtimeAPIEndpointURL, forKey: Keys.realtimeAPIEndpointURL) }
    }

    var apiKey: String {
        didSet { persistSecret(apiKey, for: .realtimeAPIKey) }
    }

    var realtimeAPIModelName: String {
        didSet { defaults.set(realtimeAPIModelName, forKey: Keys.realtimeAPIModelName) }
    }

    /// The Mistral API key, shared by the dictation socket and the polishing
    /// request. Stored in the login Keychain like the other two API keys this
    /// app holds — never in UserDefaults.
    var mistralAPIKey: String {
        didSet { persistSecret(mistralAPIKey, for: .mistralAPIKey) }
    }

    /// Hosted transcription model. Empty means
    /// `MistralRealtimeWebSocketClient.defaultModel`.
    var mistralDictationModel: String {
        didSet { defaults.set(mistralDictationModel, forKey: Keys.mistralDictationModel) }
    }

    /// Hosted polishing model. Empty means `MistralPolishDefaults.model`.
    var mistralPolishingModel: String {
        didSet { defaults.set(mistralPolishingModel, forKey: Keys.mistralPolishingModel) }
    }

    /// The models the Mistral key last listed. Kept across launches so the
    /// model pickers are whole before (or without) the next fetch, and so a
    /// polish request knows whether its model takes `reasoning_effort`.
    var mistralModelCatalog: [MistralModel] {
        didSet { persistMistralModelCatalog() }
    }

    var autoCopyEnabled: Bool {
        didSet { defaults.set(autoCopyEnabled, forKey: Keys.autoCopyEnabled) }
    }

    /// Lower other audio while dictating, and fade it back on stop. On by
    /// default (owner ruling, 2026-09-21, after hand-testing it): dictating
    /// over music is the common case, and the fade makes it unobtrusive
    /// enough not to need discovering first.
    var audioDuckingEnabled: Bool {
        didSet { defaults.set(audioDuckingEnabled, forKey: Keys.audioDuckingEnabled) }
    }

    /// Seconds each ducking fade takes, in both directions
    /// (`audioDuckingFadeDurationRange`).
    var audioDuckingFadeDuration: Double {
        didSet { defaults.set(audioDuckingFadeDuration, forKey: Keys.audioDuckingFadeDuration) }
    }

    static let audioDuckingFadeDurationRange: ClosedRange<Double> = 0.1...2.0
    static let defaultAudioDuckingFadeDuration: Double = 0.4

    /// The device and volume to put back at the next launch when this one dies
    /// ducked. Not surfaced in Settings — `AudioDuckingController` owns both
    /// ends. The device is stored with the volume because a restore aimed at
    /// whatever is default by then would push one device's level onto another.
    var audioDuckingPendingRestore: OutputVolumeReading? {
        get {
            guard let deviceUID = defaults.string(
                forKey: Keys.audioDuckingPendingRestoreDeviceUID), !deviceUID.isEmpty,
                defaults.object(forKey: Keys.audioDuckingPendingRestoreVolume) != nil
            else { return nil }
            let stored = defaults.double(forKey: Keys.audioDuckingPendingRestoreVolume)
            guard (0...1).contains(stored) else { return nil }
            return OutputVolumeReading(deviceUID: deviceUID, volume: Float(stored))
        }
        set {
            if let newValue {
                defaults.set(
                    newValue.deviceUID, forKey: Keys.audioDuckingPendingRestoreDeviceUID)
                defaults.set(
                    Double(newValue.volume), forKey: Keys.audioDuckingPendingRestoreVolume)
            } else {
                defaults.removeObject(forKey: Keys.audioDuckingPendingRestoreDeviceUID)
                defaults.removeObject(forKey: Keys.audioDuckingPendingRestoreVolume)
            }
        }
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

    /// Which input channel of a multi-channel device carries the microphone,
    /// zero-based. Only consulted for devices above stereo, where there is no
    /// meaningful downmix to mono (see `MicrophoneCaptureService`). Kept as a
    /// single global rather than per-device: users have one interface, and a
    /// stale index for another device is clamped away at capture start.
    var selectedInputChannel: Int {
        didSet { defaults.set(selectedInputChannel, forKey: Keys.selectedInputChannel) }
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
        didSet {
            defaults.set(llmPolishingEnabled, forKey: Keys.llmPolishingEnabled)
            ensureSecretsForSelectedEnginesLoaded()
        }
    }

    var llmPolishingEndpointURL: String {
        didSet { defaults.set(llmPolishingEndpointURL, forKey: Keys.llmPolishingEndpointURL) }
    }

    var llmPolishingAPIKey: String {
        didSet { persistSecret(llmPolishingAPIKey, for: .llmPolishingAPIKey) }
    }

    var llmPolishingModel: String {
        didSet { defaults.set(llmPolishingModel, forKey: Keys.llmPolishingModel) }
    }

    var managedLLMPolishingModel: String {
        didSet { defaults.set(managedLLMPolishingModel, forKey: Keys.managedLLMPolishingModel) }
    }

    var replacementDictionaryEnabled: Bool {
        didSet {
            defaults.set(replacementDictionaryEnabled, forKey: Keys.replacementDictionaryEnabled)
        }
    }

    /// When true (default), LLM polishing switches to the agent-prompt profile
    /// whenever the dictation target is a terminal-like app — extra cleanup
    /// duties for prompts dictated to coding agents (spoken-symbol
    /// normalization, backticking, self-correction resolution) without ever
    /// answering or expanding the dictated prompt.
    var agentPolishProfileEnabled: Bool {
        didSet {
            defaults.set(agentPolishProfileEnabled, forKey: Keys.agentPolishProfileEnabled)
        }
    }

    /// The user's own description of who they are and the names they use,
    /// sent with every polish request (any app, any endpoint — like the
    /// replacement dictionary, it is text they typed for this purpose).
    var polishSpeakerProfile: String {
        didSet {
            defaults.set(polishSpeakerProfile, forKey: Keys.polishSpeakerProfile)
        }
    }

    /// The user's names and terms, correct spelling only (`SpeakerTerms`).
    /// An ABSENT key means "never set", which is what lets the one-time import
    /// from the replacement dictionary tell a new install from an emptied list.
    var polishSpeakerTerms: [String] {
        didSet {
            defaults.set(polishSpeakerTerms, forKey: Keys.polishSpeakerTerms)
            // A term the user adds by hand is no longer a refusal.
            let added = Set(polishSpeakerTerms.map(SpeakerTermSuggestions.key))
            if polishDismissedTermSuggestions.contains(where: {
                added.contains(SpeakerTermSuggestions.key($0))
            }) {
                polishDismissedTermSuggestions.removeAll {
                    added.contains(SpeakerTermSuggestions.key($0))
                }
            }
        }
    }

    /// Suggested terms the user refused, oldest first. Never expires; only
    /// adding the term by hand or "Forget dismissed suggestions" removes one.
    var polishDismissedTermSuggestions: [String] {
        didSet {
            defaults.set(
                polishDismissedTermSuggestions, forKey: Keys.polishDismissedTermSuggestions)
        }
    }

    /// An absent key is `every50`: the pass runs by itself unless the user
    /// picks Never (owner ruling, 2026-09-21).
    var termSuggestionInterval: TermSuggestionInterval {
        didSet { defaults.set(termSuggestionInterval.rawValue, forKey: Keys.termSuggestionInterval) }
    }

    /// Dictations saved since the last completed suggestion run. Persisted:
    /// at fifty per run, a counter that restarted with the app would never
    /// get there.
    var termSuggestionDictationsSinceRun: Int {
        didSet {
            defaults.set(
                termSuggestionDictationsSinceRun, forKey: Keys.termSuggestionDictationsSinceRun)
        }
    }

    /// The counter value a failed background run waits for before the next
    /// attempt; 0 when nothing failed. Persisted, or a relaunch would retry
    /// at once against an API that is still down.
    var termSuggestionRetryAt: Int {
        didSet { defaults.set(termSuggestionRetryAt, forKey: Keys.termSuggestionRetryAt) }
    }

    /// Forever by default: an update must not delete what an earlier build
    /// saved without the user asking for it.
    var dictationHistoryRetention: DictationHistoryRetention {
        didSet {
            defaults.set(dictationHistoryRetention.rawValue, forKey: Keys.dictationHistoryRetention)
        }
    }

    func dismissTermSuggestion(_ term: String) {
        let key = SpeakerTermSuggestions.key(term)
        guard !key.isEmpty,
              !polishDismissedTermSuggestions.contains(where: {
                  SpeakerTermSuggestions.key($0) == key
              })
        else { return }
        polishDismissedTermSuggestions = Array(
            (polishDismissedTermSuggestions + [term])
                .suffix(SpeakerTermSuggestions.maxDismissed)
        )
    }

    var hasStoredPolishSpeakerTerms: Bool {
        defaults.object(forKey: Keys.polishSpeakerTerms) != nil
    }

    /// When true, a capped, sanitized excerpt of the clipboard is fed to the
    /// polish LLM as reference context so it can ground near-miss STT of
    /// technical terms (file names, identifiers, URLs, error names) to their
    /// exact spelling. Opt-in (default false), and applied only when the
    /// polishing endpoint is permitted (`PolishContextClipboardReader
    /// .isPermittedContextEndpoint`: loopback, or any endpoint under the
    /// explicit `polishContextTrustedEndpointEnabled` opt-in) — an endpoint the
    /// user has not consented to must never receive clipboard content. When off
    /// or the endpoint is not permitted, the pasteboard is never read at all.
    var polishClipboardContextEnabled: Bool {
        didSet {
            defaults.set(polishClipboardContextEnabled, forKey: Keys.polishClipboardContextEnabled)
        }
    }

    /// When true (default), an Overlay Buffer dictation that carries a spoken
    /// marker phrase ("paste clipboard", "colle le presse-papiers", …) has that
    /// marker replaced at commit with the actual clipboard contents, formatted
    /// as inline code or a fenced code block. Default on: it only ever fires on
    /// an explicit spoken marker, and the clipboard is read only then (once).
    /// See `ClipboardPayloadMacro`.
    var clipboardPayloadMacroEnabled: Bool {
        didSet {
            defaults.set(clipboardPayloadMacroEnabled, forKey: Keys.clipboardPayloadMacroEnabled)
        }
    }

    /// When true, the visible screen of a Claude Code terminal is read at
    /// dictation start and used to ground near-miss STT of technical terms
    /// (file names, commands, identifiers, error names) the user could actually
    /// see while speaking. Opt-in (default false), allowlisted terminals only
    /// (`TerminalScreenAllowlist`: Ghostty over its verified AX grid;
    /// iTerm2/Terminal.app over the AppleScript focused session/tab contents —
    /// NOT the broad terminal insertion allowlist,
    /// which spans editors like VS Code / Cursor), and applied only when the
    /// polishing endpoint is permitted (`PolishContextClipboardReader
    /// .isPermittedContextEndpoint`: loopback, or any endpoint under the
    /// explicit `polishContextTrustedEndpointEnabled` opt-in) — an endpoint the
    /// user has not consented to must never receive screen content. When off,
    /// the endpoint is not permitted, or an unlisted app is focused, the
    /// screen is never read at all (`TerminalScreenContext.shouldAttemptRead`).
    ///
    /// Scope, in two tiers — and the help text must state the second one,
    /// because it is the one that SENDS text:
    ///
    /// 1. Always: the screen feeds the deterministic vocabulary MATCHER, which
    ///    emits `(heard span, exact local term)` pairs. Input-side, no excerpt.
    /// 2. When `TerminalScreenRawAttachmentPolicy` positively joins the focused
    ///    pane to one live Claude Code session, a transcript-relevant EXCERPT of
    ///    the screen is attached to the polish prompt verbatim.
    ///
    /// Tier 2 is live (the broker configures the authorizer); an unjoined pane
    /// still contributes vocabulary only. Consent is asked for the union: a user
    /// who reads "fixes spellings" has not agreed to have their screen sent, so
    /// the help text names it.
    var terminalScreenContextEnabled: Bool {
        didSet {
            defaults.set(terminalScreenContextEnabled, forKey: Keys.terminalScreenContextEnabled)
        }
    }

    /// When true, and the polishing endpoint is permitted
    /// (`PolishContextClipboardReader.isPermittedContextEndpoint`), file names / path
    /// components / the branch name from the git repo in the focused terminal
    /// are harvested and the transcript-relevant ones injected into the polish
    /// prompt's replacement-dictionary section, so the model spells technical
    /// terms exactly. Opt-in (default false), prompt-context only (no
    /// deterministic replacement), permitted endpoints only — repo file names
    /// must never ride to an endpoint the user has not consented to. See
    /// `RepoVocabulary`.
    var repoVocabularyEnabled: Bool {
        didSet {
            defaults.set(repoVocabularyEnabled, forKey: Keys.repoVocabularyEnabled)
        }
    }

    /// When true, and the polishing endpoint is permitted (loopback, or any
    /// endpoint under the `polishContextTrustedEndpointEnabled` opt-in), and the focused
    /// terminal pane positively joins to one live Claude Code session, that
    /// session's repository CONTENT — status, uncommitted diffs, and the
    /// contents of files the agent just read or edited — plus the previous
    /// request the user sent that agent are attached to the polish prompt as
    /// untrusted reference material.
    ///
    /// For a session on a REMOTE host the same toggle attaches what that
    /// session's transport carries — the prior request, its recent file labels,
    /// and the bounded sanitized tool excerpts its hooks reported — and nothing
    /// else. There is no remote repository collector and no remote read: a
    /// remote cwd is an opaque label that cannot authorize a filesystem call.
    /// The consent is the same either way (this session's content reaches the
    /// polisher), which is why it is the same toggle.
    ///
    /// A separate toggle from `repoVocabularyEnabled`, deliberately, because it
    /// is a materially different consent. That one harvests NAMES — file
    /// basenames, path components, a branch — and injects the transcript-
    /// relevant ones as spelling hints. This one sends file CONTENTS and diff
    /// hunks: the user's actual source code, and a prompt they typed. Someone
    /// who agreed to "spell my filenames right" has not thereby agreed to "send
    /// the body of the file I am editing", so reusing the existing toggle would
    /// silently widen a consent they already gave. Opt-in (default false),
    /// permitted endpoints only — repository contents must never ride to an
    /// endpoint the user has not consented to. See `ClaudeRepoCollector`.
    var claudeRepoContextEnabled: Bool {
        didSet {
            defaults.set(claudeRepoContextEnabled, forKey: Keys.claudeRepoContextEnabled)
        }
    }

    /// Whether the cmux surface join arm may dial cmux's control socket.
    ///
    /// Off by default and separate from every other context toggle, because it
    /// is the only one that talks to ANOTHER application's automation socket —
    /// which the user must also have switched to password mode and given a
    /// password. Nothing about that is implied by "use my terminal screen as
    /// context", so it gets its own consent.
    var cmuxSurfaceJoinEnabled: Bool {
        didSet {
            defaults.set(cmuxSurfaceJoinEnabled, forKey: Keys.cmuxSurfaceJoinEnabled)
        }
    }

    /// Terminal apps the user added in Settings → Terminals (plus the
    /// one-time import from the legacy `terminal_apps.toml`). Insertion
    /// treats these bundle ids exactly as the TOML entries were treated:
    /// terminal-like for live dictation and the agent polish profile —
    /// nothing more (`TerminalScreenAllowlist` still excludes them from
    /// screen reads, which a user list was never able to grant).
    var userTerminalApps: [UserTerminalApp] {
        didSet { persistUserTerminalApps() }
    }

    /// The user-added apps' bundle ids — the runtime half of the old
    /// `terminal_apps.toml` list. Seeded once at launch by
    /// `UserTerminalAppsMigrator`, then owned by Settings → Terminals.
    var userTerminalAppBundleIDs: Set<String> {
        Set(userTerminalApps.map(\.bundleID))
    }

    private func persistMistralModelCatalog() {
        guard let data = try? JSONEncoder().encode(mistralModelCatalog) else { return }
        defaults.set(data, forKey: Keys.mistralModelCatalog)
    }

    private static func loadMistralModelCatalog(from defaults: UserDefaults) -> [MistralModel] {
        guard let data = defaults.data(forKey: Keys.mistralModelCatalog) else { return [] }
        do {
            return try JSONDecoder().decode([MistralModel].self, from: data)
        } catch {
            // A cache: the next fetch rebuilds it.
            Log.persistence.error(
                "Stored Mistral model list is unreadable; starting empty. \(error.localizedDescription, privacy: .public)"
            )
            return []
        }
    }

    private func persistUserTerminalApps() {
        guard let data = try? JSONEncoder().encode(userTerminalApps) else { return }
        defaults.set(data, forKey: Keys.userTerminalApps)
    }

    /// Appends a user-added terminal app and forgets any recorded removal of
    /// its id: re-adding is a fresh start for the migration ledger.
    func addUserTerminalApp(_ app: UserTerminalApp) {
        userTerminalApps.append(app)
        var removed = removedUserTerminalAppBundleIDs()
        guard removed.contains(app.bundleID) else { return }
        removed.removeAll { $0 == app.bundleID }
        defaults.set(removed, forKey: UserTerminalAppsMigrator.removedBundleIDsKey)
    }

    /// Removes a user-added terminal app and records the removal in the
    /// migration ledger (`UserTerminalAppsMigrator.removedBundleIDsKey`), so
    /// the launch-time `terminal_apps.toml` import cannot resurrect the id
    /// even if the imported-ids ledger is lost.
    func removeUserTerminalApp(bundleID: String) {
        userTerminalApps.removeAll { $0.bundleID == bundleID }
        var removed = removedUserTerminalAppBundleIDs()
        guard !removed.contains(bundleID) else { return }
        removed.append(bundleID)
        defaults.set(removed, forKey: UserTerminalAppsMigrator.removedBundleIDsKey)
    }

    private func removedUserTerminalAppBundleIDs() -> [String] {
        defaults.stringArray(forKey: UserTerminalAppsMigrator.removedBundleIDsKey) ?? []
    }

    private static func loadUserTerminalApps(from defaults: UserDefaults) -> [UserTerminalApp] {
        guard let data = defaults.data(forKey: Keys.userTerminalApps) else { return [] }
        do {
            return try JSONDecoder().decode([UserTerminalApp].self, from: data)
        } catch {
            // The failure, never the payload: this line must not become the
            // place a corrupt blob's contents reach the log.
            Log.persistence.error(
                "Stored user terminal apps are unreadable; starting from an empty list. \(error.localizedDescription, privacy: .public)"
            )
            return []
        }
    }

    /// The remote listen port this Mac's SSH `RemoteForward` binds on an
    /// enrolled host — derived once from a persisted per-install identity, and
    /// stable from then on (`ClaudeRemoteForwardPort`). Not a preference: there
    /// is nothing to choose, and a value the user could edit here would silently
    /// disagree with the `port` option already installed on the remote host.
    ///
    /// Reading it is what creates the identity, so it is cheap to read and
    /// never returns a different answer on a later launch.
    var claudeRemoteForwardPort: UInt16 {
        // The identity itself lives in a 0600 file beside the Claude host
        // registry, NOT in this domain: a preferences reset must not move an
        // enrolled host's port while the enrollment that used it survives.
        // `defaults` is passed only so an identity written by this feature's
        // first iteration migrates into that file instead of being replaced.
        ClaudeRemoteForwardPortAllocator(legacyDefaults: defaults).allocatedPort()
    }

    /// When true, the loopback-only endpoint gate that every polish-context
    /// surface shares (clipboard, terminal screen, repo vocabulary, Claude
    /// repo/session blocks — `PolishContextClipboardReader
    /// .isPermittedContextEndpoint`) also admits the configured polishing
    /// endpoint when it is NOT on this Mac: a machine on the user's LAN, or a
    /// remote provider they trust with that content.
    ///
    /// Opt-in (default false), and deliberately a SEPARATE consent from each
    /// context toggle: those decide WHAT may be collected, this decides WHERE
    /// it may be sent. Off, the per-surface promises ("local polishing
    /// endpoints only") hold unconditionally; on, the user has explicitly
    /// traded them for their chosen endpoint, and the Settings row's help text
    /// names exactly that trade. Each surface's own toggle still gates
    /// collection — this flag alone never causes a read.
    var polishContextTrustedEndpointEnabled: Bool {
        didSet {
            defaults.set(
                polishContextTrustedEndpointEnabled,
                forKey: Keys.polishContextTrustedEndpointEnabled
            )
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

    #if LOCALVOXTRAL_DOGFOOD
    /// Arms the dogfooding context capture. Default false, and it exists at all
    /// only in a build compiled with `LOCALVOXTRAL_DOGFOOD` (see `Package.swift`
    /// for why that gate is a compile flag rather than this toggle alone).
    ///
    /// While armed, every polished dictation writes a record containing the raw
    /// transcript, the harvested context, the rendered prompts, and the model's
    /// reply to `~/Library/Application Support/localvoxtral/dogfood`. That is
    /// content the shipped app deliberately never writes anywhere, which is why
    /// arming it is a deliberate act rather than a side effect of running an
    /// instrumented build.
    ///
    /// No UI yet — like `debugLogRealtimeDeltas`, and toggled the same way:
    ///   `defaults write com.localvoxtral.app debug.dogfood_capture_enabled -bool true`
    /// A Settings row and a status-item indicator belong with the flag-this-
    /// dictation affordance; until they exist, an armed build is only
    /// discoverable from this default and the capture directory.
    var dogfoodCaptureEnabled: Bool {
        didSet { defaults.set(dogfoodCaptureEnabled, forKey: Keys.dogfoodCaptureEnabled) }
    }

    /// Whether this instrumented build opens its local control socket
    /// (`DogfoodControlSocket`), which can start and stop dictations and report
    /// what the context pipeline resolved.
    ///
    /// Off by default, and separate from `dogfoodCaptureEnabled` on purpose: a
    /// capture writes a file, a socket accepts commands, and consenting to the
    /// first is not consenting to the second. Toggled the same way:
    ///   `defaults write com.localvoxtral.app debug.dogfood_control_socket_enabled -bool true`
    /// Read once at launch — the socket binds in `applicationDidFinishLaunching`
    /// or not at all, so flipping this needs a relaunch, which is the point:
    /// a listener must not appear under a running app.
    var dogfoodControlSocketEnabled: Bool {
        didSet {
            defaults.set(dogfoodControlSocketEnabled, forKey: Keys.dogfoodControlSocketEnabled)
        }
    }
    #endif

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

    /// Body font size (points) for the Overlay Buffer panel; the whole panel
    /// scales proportionally from it (see `OverlayLayoutMetrics`).
    var overlayBufferFontSize: Double {
        didSet { defaults.set(overlayBufferFontSize, forKey: Keys.overlayBufferFontSize) }
    }

    /// Body lines the Overlay Buffer panel shows before its text scrolls.
    var overlayBufferVisibleLines: Int {
        didSet { defaults.set(overlayBufferVisibleLines, forKey: Keys.overlayBufferVisibleLines) }
    }

    /// Where the user dragged the Overlay Buffer panel, or nil for the
    /// anchored position. Stored against the display it was on and
    /// re-validated against the attached displays on every use — see
    /// `OverlayManualPlacementResolver`.
    var overlayBufferPlacement: OverlayManualPlacement? {
        didSet { persistOverlayBufferPlacement() }
    }

    private func persistOverlayBufferPlacement() {
        guard let placement = overlayBufferPlacement, placement.isWellFormed else {
            defaults.removeObject(forKey: Keys.overlayBufferPositionScreenID)
            defaults.removeObject(forKey: Keys.overlayBufferPositionOffsetX)
            defaults.removeObject(forKey: Keys.overlayBufferPositionOffsetY)
            return
        }
        defaults.set(placement.screenID, forKey: Keys.overlayBufferPositionScreenID)
        defaults.set(Double(placement.topLeftOffset.x), forKey: Keys.overlayBufferPositionOffsetX)
        defaults.set(Double(placement.topLeftOffset.y), forKey: Keys.overlayBufferPositionOffsetY)
    }

    /// Reads a stored placement back, rejecting anything the resolver could not
    /// clamp: a half-written trio, an empty display id, a NaN offset. A first
    /// run has none of the three keys and lands here as nil, which is the
    /// anchored position.
    static func loadOverlayBufferPlacement(defaults: UserDefaults) -> OverlayManualPlacement? {
        guard let screenID = defaults.string(forKey: Keys.overlayBufferPositionScreenID),
              !screenID.isEmpty,
              defaults.object(forKey: Keys.overlayBufferPositionOffsetX) != nil,
              defaults.object(forKey: Keys.overlayBufferPositionOffsetY) != nil
        else { return nil }
        let placement = OverlayManualPlacement(
            screenID: screenID,
            topLeftOffset: CGPoint(
                x: defaults.double(forKey: Keys.overlayBufferPositionOffsetX),
                y: defaults.double(forKey: Keys.overlayBufferPositionOffsetY)
            )
        )
        return placement.isWellFormed ? placement : nil
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
        environment: [String: String] = ProcessInfo.processInfo.environment,
        secretStore: (any SecretStoring)? = nil
    ) {
        // Resolved from the INJECTED environment, not `ProcessInfo` — a test
        // that passes a suppressing environment must get the process-local
        // store, not the real keychain.
        let secretStore = secretStore ?? DefaultSecretStore.make(environment: environment)
        self.defaults = defaults
        self.secretStore = secretStore
        self.environment = environment

        // Resolve onboarding completion BEFORE any migration below persists the
        // per-backend mode keys — the freshness heuristic reads whether those
        // keys were *already* stored, so it must observe the untouched domain.
        let resolvedOnboardingCompleted = Self.resolveOnboardingCompleted(
            defaults: defaults, environment: environment)
        // Seed the out-of-box defaults on a never-launched install only, and
        // WRITE them rather than express them as a load fallback below: once
        // the wizard completes it persists onboarding as done, this install
        // stops looking fresh, and a fallback would silently flip the seeded
        // values back off.
        //
        // The gate needs the onboarding key to be ABSENT, not merely resolved
        // false. "Re-run setup…" resets that flag to false on an existing
        // install (DictationViewModel.reRunOnboarding), so a crash or force-quit
        // before the wizard closes would otherwise leave a configured user
        // looking fresh on the next launch — and claim Right Command from them.
        let isNeverLaunchedInstall = defaults.object(forKey: Keys.onboardingCompleted) == nil
        onboardingCompleted = resolvedOnboardingCompleted
        defaults.set(resolvedOnboardingCompleted, forKey: Keys.onboardingCompleted)

        if isNeverLaunchedInstall, !resolvedOnboardingCompleted {
            Self.seedFreshInstallDefaults(defaults: defaults)
        }

        let resolvedBackendModes = Self.resolveBackendModes(defaults: defaults, environment: environment)
        dictationBackendMode = resolvedBackendModes.dictation
        polishingBackendMode = resolvedBackendModes.polishing
        defaults.set(resolvedBackendModes.dictation.rawValue, forKey: Keys.dictationBackendMode)
        defaults.set(resolvedBackendModes.polishing.rawValue, forKey: Keys.polishingBackendMode)

        if let storedCacheLimit = defaults.string(forKey: Keys.speechdCacheLimit),
            let parsedCacheLimit = SpeechdCacheLimit(rawValue: storedCacheLimit)
        {
            speechdCacheLimit = parsedCacheLimit
        } else {
            speechdCacheLimit = .auto
        }

        if let storedStepCadence = defaults.string(forKey: Keys.speechdStepCadence),
            let parsedStepCadence = SpeechdStepCadence(rawValue: storedStepCadence)
        {
            speechdStepCadence = parsedStepCadence
        } else {
            speechdStepCadence = .auto
        }

        // A repo that left the catalog (or was hand-written into the plist)
        // must never reach a helper launch: fall back to the default and
        // rewrite the stored value so the picker and the launch agree.
        let storedSpeechModel = defaults.string(forKey: Keys.managedSpeechModel)?.trimmed ?? ""
        if let option = SpeechModelCatalog.option(forRepoID: storedSpeechModel) {
            managedSpeechModel = option.repoID
        } else {
            managedSpeechModel = SpeechModelCatalog.defaultOption.repoID
            defaults.set(SpeechModelCatalog.defaultOption.repoID, forKey: Keys.managedSpeechModel)
        }

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

        // One sweep out of UserDefaults, then the keychain is the only source
        // of truth. Done here rather than lazily so a plist copy of a secret
        // stops existing at the first launch that can remove it. Reading the
        // keys back is NOT done here — see `ensureSecretsLoaded`.
        // ... but NOT on a run whose secret store dies with the process: the
        // sweep removes the plist copy once the write "succeeds", and an
        // in-memory write always succeeds. A CI launch would take the user's
        // only copy of a not-yet-migrated key with it.
        let secrets =
            StartupPermissionSuppression.loginKeychainIsDisabled(environment: environment)
            ? ResolvedSecrets()
            : Self.migrateLegacySecrets(defaults: defaults, secretStore: secretStore)
        secretStoreFailureSummary = secrets.failureSummary

        apiKey = Self.resolveSecret(
            secrets, .realtimeAPIKey, envKey: "OPENAI_API_KEY", environment: environment)

        realtimeAPIModelName = Self.loadModelName(
            defaults: defaults, key: Keys.realtimeAPIModelName,
            envKey: "REALTIME_MODEL", provider: .realtimeAPI,
            environment: environment
        )

        mistralAPIKey = Self.resolveSecret(
            secrets, .mistralAPIKey, envKey: "MISTRAL_API_KEY", environment: environment)
        // Empty is the stored form of "use the pinned default": the defaults
        // live in one place (the client / MistralPolishDefaults) and a user who
        // clears the field gets them back, rather than a blank model name.
        mistralDictationModel = Self.loadString(
            defaults: defaults, key: Keys.mistralDictationModel,
            envKey: "MISTRAL_DICTATION_MODEL", fallback: "",
            environment: environment
        )
        mistralPolishingModel = Self.loadString(
            defaults: defaults, key: Keys.mistralPolishingModel,
            envKey: "MISTRAL_POLISHING_MODEL", fallback: "",
            environment: environment
        )
        mistralModelCatalog = Self.loadMistralModelCatalog(from: defaults)

        opensWindowAtLaunch = Self.loadBool(
            defaults: defaults, key: Keys.opensWindowAtLaunch, fallback: false)
        autoCopyEnabled = Self.loadBool(
            defaults: defaults, key: Keys.autoCopyEnabled, fallback: false)
        audioDuckingEnabled = Self.loadBool(
            defaults: defaults, key: Keys.audioDuckingEnabled, fallback: true)
        let storedDuckingFade = defaults.object(forKey: Keys.audioDuckingFadeDuration) != nil
            ? defaults.double(forKey: Keys.audioDuckingFadeDuration)
            : Self.defaultAudioDuckingFadeDuration
        audioDuckingFadeDuration = min(
            max(storedDuckingFade, Self.audioDuckingFadeDurationRange.lowerBound),
            Self.audioDuckingFadeDurationRange.upperBound
        )
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
        llmPolishingAPIKey = Self.resolveSecret(
            secrets, .llmPolishingAPIKey, envKey: "LLM_POLISHING_API_KEY",
            environment: environment)
        llmPolishingModel = Self.loadString(
            defaults: defaults, key: Keys.llmPolishingModel,
            envKey: "LLM_POLISHING_MODEL", fallback: Self.defaultLLMPolishingModel,
            environment: environment
        )
        managedLLMPolishingModel = Self.loadString(
            defaults: defaults, key: Keys.managedLLMPolishingModel,
            envKey: "MANAGED_LLM_POLISHING_MODEL", fallback: Self.defaultLLMPolishingModel,
            environment: environment
        )
        replacementDictionaryEnabled = Self.loadBool(
            defaults: defaults, key: Keys.replacementDictionaryEnabled, fallback: false)
        agentPolishProfileEnabled = Self.loadBool(
            defaults: defaults, key: Keys.agentPolishProfileEnabled, fallback: true)
        polishSpeakerProfile = defaults.string(forKey: Keys.polishSpeakerProfile) ?? ""
        polishDismissedTermSuggestions =
            defaults.stringArray(forKey: Keys.polishDismissedTermSuggestions) ?? []
        termSuggestionInterval =
            (defaults.object(forKey: Keys.termSuggestionInterval) as? Int)
            .flatMap(TermSuggestionInterval.init(rawValue:)) ?? .every50
        dictationHistoryRetention =
            defaults.string(forKey: Keys.dictationHistoryRetention)
            .flatMap(DictationHistoryRetention.init(rawValue:)) ?? .forever
        termSuggestionRetryAt = max(0, defaults.integer(forKey: Keys.termSuggestionRetryAt))
        termSuggestionDictationsSinceRun = max(
            0, defaults.integer(forKey: Keys.termSuggestionDictationsSinceRun))
        polishSpeakerTerms = SpeakerTerms.sanitized(
            defaults.stringArray(forKey: Keys.polishSpeakerTerms) ?? [])
        polishClipboardContextEnabled = Self.loadBool(
            defaults: defaults, key: Keys.polishClipboardContextEnabled, fallback: false)
        clipboardPayloadMacroEnabled = Self.loadBool(
            defaults: defaults, key: Keys.clipboardPayloadMacroEnabled, fallback: true)
        terminalScreenContextEnabled = Self.loadBool(
            defaults: defaults, key: Keys.terminalScreenContextEnabled, fallback: false)
        repoVocabularyEnabled = Self.loadBool(
            defaults: defaults, key: Keys.repoVocabularyEnabled, fallback: false)
        claudeRepoContextEnabled = Self.loadBool(
            defaults: defaults, key: Keys.claudeRepoContextEnabled, fallback: false)
        cmuxSurfaceJoinEnabled = Self.loadBool(
            defaults: defaults, key: Keys.cmuxSurfaceJoinEnabled, fallback: false)
        userTerminalApps = Self.loadUserTerminalApps(from: defaults)
        polishContextTrustedEndpointEnabled = Self.loadBool(
            defaults: defaults, key: Keys.polishContextTrustedEndpointEnabled, fallback: false)
        debugLogRealtimeDeltas = Self.loadBool(
            defaults: defaults, key: Keys.debugLogRealtimeDeltas, fallback: false)
        #if LOCALVOXTRAL_DOGFOOD
        dogfoodCaptureEnabled = Self.loadBool(
            defaults: defaults, key: Keys.dogfoodCaptureEnabled, fallback: false)
        dogfoodControlSocketEnabled = Self.loadBool(
            defaults: defaults, key: Keys.dogfoodControlSocketEnabled, fallback: false)
        #endif
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

        let storedOverlayFontSize = defaults.object(forKey: Keys.overlayBufferFontSize) != nil
            ? defaults.double(forKey: Keys.overlayBufferFontSize)
            : OverlayLayoutMetrics.defaultBodyFontSize
        overlayBufferFontSize = OverlayLayoutMetrics.clampedBodyFontSize(storedOverlayFontSize)

        let storedOverlayVisibleLines = defaults.object(forKey: Keys.overlayBufferVisibleLines) != nil
            ? defaults.integer(forKey: Keys.overlayBufferVisibleLines)
            : OverlayLayoutMetrics.defaultVisibleLines
        overlayBufferVisibleLines = OverlayLayoutMetrics.clampedVisibleLines(storedOverlayVisibleLines)

        overlayBufferPlacement = Self.loadOverlayBufferPlacement(defaults: defaults)

        // Zero-based; negatives are meaningless and an index past the device's
        // channel count is clamped again at capture start (the device can
        // change between launches).
        selectedInputChannel = max(0, defaults.integer(forKey: Keys.selectedInputChannel))

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

        // The sweep above already holds these values; reading them back would
        // be a second keychain operation for nothing.
        loadedSecretKeys = Set(secrets.values.keys)
        ensureSecretsForSelectedEnginesLoaded()
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

    // MARK: - API keys (login Keychain)

    /// Engines-pane copy for a secret store that refused. One short sentence
    /// each: Settings shows the summary, the `Secrets` log carries the OSStatus.
    static let secretStoreReadFailureSummary =
        "Keychain unavailable; API keys could not be read."
    static let secretStoreWriteFailureSummary =
        "Keychain unavailable; the API key was not saved."

    /// Where each secret used to live in UserDefaults. Read ONLY by the
    /// one-time migration below — nothing else may touch these keys again.
    private static func legacyDefaultsKey(for key: SecretKey) -> String {
        switch key {
        case .realtimeAPIKey: return Keys.apiKey
        case .llmPolishingAPIKey: return Keys.llmPolishingAPIKey
        case .mistralAPIKey: return Keys.mistralAPIKey
        }
    }

    /// What the migration sweep learned, plus the sentence the UI must show
    /// when something refused.
    private struct ResolvedSecrets {
        var values: [SecretKey: String] = [:]
        var failureSummary: String?
    }

    /// Migrates any plist-era keys into the secret store, once per install.
    ///
    /// Returns only what the sweep itself learned — a value it migrated, or one
    /// it could not migrate and left in the plist. Every other key is read
    /// later and on demand (`ensureSecretsLoaded`): each read of a stored item
    /// can cost the user a modal keychain prompt, so launch must not pay for
    /// engines the user has not selected.
    ///
    /// Two rules make the sweep safe to run on a half-migrated install:
    /// - a plist value is only written when the store has nothing, so a stale
    ///   copy can never clobber a newer key;
    /// - a failed write leaves the plist value alone and keeps using it for
    ///   this process, because losing a user's API key is worse than leaving a
    ///   copy of it where it already was.
    private static func migrateLegacySecrets(
        defaults: UserDefaults,
        secretStore: any SecretStoring
    ) -> ResolvedSecrets {
        var resolved = ResolvedSecrets()
        var strandedInDefaults: [SecretKey: String] = [:]

        if !defaults.bool(forKey: Keys.apiKeysMigratedToKeychain) {
            var sweptEverything = true
            for key in SecretKey.allCases {
                let defaultsKey = legacyDefaultsKey(for: key)
                guard
                    let legacy = defaults.string(forKey: defaultsKey)?.trimmed,
                    !legacy.isEmpty
                else {
                    // Nothing worth keeping; drop any blank leftover so the
                    // plist stops carrying these keys at all.
                    defaults.removeObject(forKey: defaultsKey)
                    continue
                }

                do {
                    let existing = try secretStore.secret(for: key) ?? ""
                    if existing.isEmpty {
                        try secretStore.setSecret(legacy, for: key)
                        resolved.values[key] = legacy
                    } else {
                        // A newer key is already stored; the plist copy is
                        // stale, and the store still wins.
                        resolved.values[key] = existing
                    }
                    defaults.removeObject(forKey: defaultsKey)
                    Log.secrets.notice(
                        "Migrated \(key.rawValue, privacy: .public) from UserDefaults into the keychain"
                    )
                } catch {
                    sweptEverything = false
                    strandedInDefaults[key] = legacy
                    resolved.failureSummary = Self.secretStoreWriteFailureSummary
                    Log.secrets.error(
                        "Keychain migration of \(key.rawValue, privacy: .public) failed; the UserDefaults copy stays in place and is used for this launch: \(String(describing: error), privacy: .public)"
                    )
                }
            }
            if sweptEverything {
                defaults.set(true, forKey: Keys.apiKeysMigratedToKeychain)
            }
        }

        // A key the store refused stays on the plist copy for this launch, and
        // that copy is the value this process runs with.
        for (key, stranded) in strandedInDefaults {
            resolved.values[key] = stranded
        }

        return resolved
    }

    /// Reads `keys` out of the secret store, at most once each per process, and
    /// publishes what it finds on the matching property.
    ///
    /// Why this is not done at launch for all three: the app has no Team ID, so
    /// macOS partitions its keychain items by the build's code-signing hash and
    /// the first read from a newly installed build raises a modal prompt. A
    /// user who dictates locally should never see one, so a key is fetched only
    /// when something can actually use it — the engines selected at launch, an
    /// engine switched on later, and the Settings window when it opens to show
    /// the field.
    ///
    /// A key whose store read fails or comes back empty keeps whatever the
    /// environment resolved at init; the store is authoritative only when it
    /// answers with a value.
    func ensureSecretsLoaded(_ keys: Set<SecretKey>) {
        for key in SecretKey.allCases where keys.contains(key) {
            loadSecretIfNeeded(key)
        }
    }

    /// Every key, for the places that display or report all three: the Settings
    /// window and the diagnostics export.
    func ensureAllSecretsLoaded() {
        ensureSecretsLoaded(Set(SecretKey.allCases))
    }

    /// The secrets the current configuration can actually use. Managed local
    /// engines authenticate with nothing, so the common setup needs no key at
    /// all.
    static func secretsInUse(
        dictationMode: BackendMode,
        polishingMode: BackendMode,
        polishingEnabled: Bool
    ) -> Set<SecretKey> {
        var keys: Set<SecretKey> = []
        switch dictationMode {
        case .managedLocal: break
        case .externalURL: keys.insert(.realtimeAPIKey)
        case .mistralAPI: keys.insert(.mistralAPIKey)
        }
        guard polishingEnabled else { return keys }
        switch polishingMode {
        case .managedLocal: break
        case .externalURL: keys.insert(.llmPolishingAPIKey)
        case .mistralAPI: keys.insert(.mistralAPIKey)
        }
        return keys
    }

    /// Loads whatever the engines currently selected need. Called at the end of
    /// init and whenever one of those selections changes.
    func ensureSecretsForSelectedEnginesLoaded() {
        ensureSecretsLoaded(
            Self.secretsInUse(
                dictationMode: dictationBackendMode,
                polishingMode: polishingBackendMode,
                polishingEnabled: llmPolishingEnabled
            )
        )
    }

    private func loadSecretIfNeeded(_ key: SecretKey) {
        guard !loadedSecretKeys.contains(key) else { return }
        // Inserted before the read, not after: a read that throws must not be
        // retried on every mode change and every Settings open — one prompt is
        // the budget.
        loadedSecretKeys.insert(key)

        let stored: String
        do {
            stored = try secretStore.secret(for: key) ?? ""
        } catch {
            secretStoreFailureSummary = Self.secretStoreReadFailureSummary
            Log.secrets.error(
                "Reading \(key.rawValue, privacy: .public) from the keychain failed; it reads as unset for this launch: \(String(describing: error), privacy: .public)"
            )
            return
        }
        guard !stored.isEmpty else { return }

        // The write-through in these properties' `didSet` would store the value
        // that just came out of the store — another keychain operation, and
        // another chance to prompt.
        isApplyingStoredSecret = true
        defer { isApplyingStoredSecret = false }
        switch key {
        case .realtimeAPIKey: apiKey = stored
        case .llmPolishingAPIKey: llmPolishingAPIKey = stored
        case .mistralAPIKey: mistralAPIKey = stored
        }
    }

    /// The precedence `loadString` gave these keys, with the secret store
    /// standing in for the plist: a stored key wins, then the env override,
    /// then empty. An env value is never written back — it belongs to the
    /// process that exported it, not to the user's keychain.
    private static func resolveSecret(
        _ secrets: ResolvedSecrets,
        _ key: SecretKey,
        envKey: String,
        environment: [String: String]
    ) -> String {
        let stored = secrets.values[key] ?? ""
        guard stored.isEmpty else { return stored }
        return environment[envKey] ?? ""
    }

    /// Write-through for the three key properties. Trimmed, because a pasted
    /// key routinely carries a trailing newline the wire never wants; empty
    /// deletes the item rather than storing a blank.
    private func persistSecret(_ value: String, for key: SecretKey) {
        // A value the store just handed us is not a change to write back.
        guard !isApplyingStoredSecret else { return }
        // Marked loaded either way. On success the store holds exactly this
        // value, so there is nothing to fetch. On failure the value is still
        // the one this process runs with ("works this session but is not
        // saved"), and a later fetch would overwrite what the user just typed
        // with the stale stored key.
        loadedSecretKeys.insert(key)
        do {
            try secretStore.setSecret(value.trimmed, for: key)
        } catch {
            secretStoreFailureSummary = Self.secretStoreWriteFailureSummary
            Log.secrets.error(
                "Storing \(key.rawValue, privacy: .public) in the keychain failed: \(String(describing: error), privacy: .public)"
            )
        }
    }

    /// What a first-time user gets out of the box: the tap/hold gesture works
    /// without a trip to Settings, instead of the ⌥Space shortcut.
    ///
    /// Only ever called for a fresh install (see init), and only writes keys
    /// that are absent, so it can never overwrite a choice the user made. The
    /// load fallback stays `false` on purpose — that is what an EXISTING
    /// install reads, and an update must not claim Right Command behind the
    /// user's back.
    ///
    /// Polishing is deliberately NOT seeded here: the onboarding wizard already
    /// enables it by default (`polishingConsent`), and does so together with
    /// downloading the model. Seeding it would strand a user who declines —
    /// that path leaves the key unwritten and relies on this fallback, so a
    /// seeded `true` would survive as polishing-on with no model on disk.
    private static func seedFreshInstallDefaults(defaults: UserDefaults) {
        let outOfBoxDefaults: [String: Bool] = [
            Keys.modifierOnlyHotKeyEnabled: true
        ]
        for (key, value) in outOfBoxDefaults where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
    }

    /// Decide whether the first-launch wizard should be skipped.
    ///
    /// - If the flag was already persisted, honor it verbatim.
    /// - Otherwise treat the install as "not fresh" (skip the wizard) when any
    ///   signal of a prior configured install is present: the legacy global
    ///   backend-mode key, a persisted realtime endpoint, the REALTIME_ENDPOINT
    ///   env override, or either per-backend mode key. These mirror the exact
    ///   signals the backend-mode migration keys off, plus the newer mode keys.
    /// - A genuinely fresh install has none of these → show the wizard.
    private static func resolveOnboardingCompleted(
        defaults: UserDefaults,
        environment: [String: String]
    ) -> Bool {
        if defaults.object(forKey: Keys.onboardingCompleted) != nil {
            return defaults.bool(forKey: Keys.onboardingCompleted)
        }

        let isExistingInstall =
            defaults.string(forKey: Keys.backendMode) != nil
            || defaults.string(forKey: Keys.realtimeAPIEndpointURL) != nil
            || environment["REALTIME_ENDPOINT"] != nil
            || defaults.string(forKey: Keys.dictationBackendMode) != nil
            || defaults.string(forKey: Keys.polishingBackendMode) != nil

        return isExistingInstall
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
        switch dictationBackendMode {
        case .managedLocal:
            return ""
        case .externalURL:
            return apiKey.trimmed
        case .mistralAPI:
            return trimmedMistralAPIKey
        }
    }

    // MARK: - Mistral API

    var trimmedMistralAPIKey: String { mistralAPIKey.trimmed }

    var resolvedMistralDictationModel: String {
        let model = mistralDictationModel.trimmed
        return model.isEmpty ? MistralRealtimeWebSocketClient.defaultModel : model
    }

    var resolvedMistralPolishingModel: String {
        let model = mistralPolishingModel.trimmed
        return model.isEmpty ? MistralPolishDefaults.model : model
    }

    /// Whether the Mistral engines have everything they need. The key is the
    /// only thing a user can get wrong here — the endpoints are pinned and the
    /// models have defaults.
    var isMistralAPIConfigured: Bool { !trimmedMistralAPIKey.isEmpty }

    /// The Engines pane's one-line Mistral status. Deliberately says nothing
    /// about reachability: Settings never fires a request of its own, and the
    /// "Check key" row is where a user asks Mistral anything.
    var mistralAPIStatusSummary: String {
        // A keychain that will not answer must never read as "API key missing":
        // that sends the user to paste a key they already have.
        if let secretStoreFailureSummary { return secretStoreFailureSummary }
        return isMistralAPIConfigured ? "Ready" : "API key missing"
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

    /// True when a keyboard trigger can start an Overlay Buffer session: the
    /// single-modifier tap gesture, or a dedicated Overlay Buffer shortcut.
    /// LLM polishing runs only on Overlay Buffer commits, so when this is
    /// false Settings shows polishing as unavailable and managed polishd is
    /// kept stopped. The menu-bar Start Dictation button deliberately does
    /// not count (owner call, 2026-07-06): an overlay session started from
    /// the popover still polishes via the session-time ensureReady backstop,
    /// paying the polishd cold start.
    var isOverlayBufferSessionReachable: Bool {
        modifierOnlyHotKeyEnabled || overlayBufferShortcut != nil
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

    /// Both shortcut slots exactly as stored, enabled flags included and a
    /// value the validator rejects kept verbatim.
    ///
    /// The getters cannot express this: they return nil both for a disabled
    /// slot and for a stored value that fails validation, and a caller that
    /// means to put things back the way they were would restore the default
    /// shortcut over the second case — installing a trigger the user never
    /// chose. Anything that writes a slot speculatively takes a snapshot
    /// first and restores it verbatim.
    struct ShortcutSlotSnapshot: Equatable {
        var overlayKeyCode: UInt32
        var overlayCarbonModifierFlags: UInt32
        var overlayEnabled: Bool
        var livePasteKeyCode: UInt32
        var livePasteCarbonModifierFlags: UInt32
        var livePasteEnabled: Bool
    }

    var shortcutSlotSnapshot: ShortcutSlotSnapshot {
        ShortcutSlotSnapshot(
            overlayKeyCode: overlayBufferShortcutKeyCode,
            overlayCarbonModifierFlags: overlayBufferShortcutCarbonModifierFlags,
            overlayEnabled: overlayBufferShortcutEnabled,
            livePasteKeyCode: livePasteShortcutKeyCode,
            livePasteCarbonModifierFlags: livePasteShortcutCarbonModifierFlags,
            livePasteEnabled: livePasteShortcutEnabled
        )
    }

    func restoreShortcutSlots(_ snapshot: ShortcutSlotSnapshot) {
        overlayBufferShortcutKeyCode = snapshot.overlayKeyCode
        overlayBufferShortcutCarbonModifierFlags = snapshot.overlayCarbonModifierFlags
        overlayBufferShortcutEnabled = snapshot.overlayEnabled
        livePasteShortcutKeyCode = snapshot.livePasteKeyCode
        livePasteShortcutCarbonModifierFlags = snapshot.livePasteCarbonModifierFlags
        livePasteShortcutEnabled = snapshot.livePasteEnabled
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
        if dictationBackendMode == .mistralAPI {
            // Hosted Voxtral ids have nothing to do with the external
            // provider's placeholder or the managed HF repo pin.
            return resolvedMistralDictationModel
        }
        if dictationBackendMode == .managedLocal {
            // The bundled Swift engine needs its dedicated HF-layout pin.
            // Keep the external provider's placeholder/default independent:
            // user-typed external values remain ignored in managed mode, but
            // an existing external endpoint still sees its historical model.
            return resolvedManagedSpeechModel.repoID
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
        if dictationBackendMode == .mistralAPI {
            // Pinned, not user-editable: the client appends the `?model=` query
            // item itself, so a hand-typed endpoint could only break it.
            return MistralRealtimeWebSocketClient.defaultEndpoint
        }
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
            let model = resolvedManagedLLMPolishingModel
            let option = PolishModelCatalog.option(forRepoID: model)
            return LLMPolishingConfiguration(
                endpointURL: url,
                apiKey: "",
                model: model,
                samplingDefaults: option?.samplingDefaults,
                chatTemplateArguments: option?.chatTemplateArguments
            )
        }
        if polishingBackendMode == .mistralAPI {
            // No key, no request. A polish sent to Mistral without credentials
            // can only come back 401, and the commit path reports a nil
            // configuration as one actionable line — which is strictly better
            // than an HTTP status the user cannot act on.
            let key = trimmedMistralAPIKey
            guard !key.isEmpty else { return nil }
            return LLMPolishingConfiguration(
                endpointURL: MistralPolishDefaults.endpoint,
                apiKey: key,
                model: resolvedMistralPolishingModel,
                requestShape: .mistral,
                mistralReasoningEffort: MistralReasoningEffort.forModel(
                    resolvedMistralPolishingModel, catalog: mistralModelCatalog
                )
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

    /// The managed picker's stored selection, hardened against an empty env
    /// override. External mode's `llmPolishingModel` is a server-side model
    /// NAME; this is an HF repo the helper must download — separate keys so a
    /// leftover external value can never leak into a managed launch.
    var resolvedManagedLLMPolishingModel: String {
        let model = managedLLMPolishingModel.trimmed
        return model.isEmpty ? Self.defaultLLMPolishingModel : model
    }

    /// The catalog entry the managed dictation helper runs. Resolves only
    /// entries the bundled helper knows how to load, so a stale stored repo
    /// falls back to the default instead of failing the launch.
    var resolvedManagedSpeechModel: SpeechModelOption {
        SpeechModelCatalog.option(forRepoID: managedSpeechModel.trimmed)
            ?? SpeechModelCatalog.defaultOption
    }
}

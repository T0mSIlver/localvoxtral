import Carbon.HIToolbox
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
            return "Runs the bundled dictation engine on this Mac."
        case .externalURL:
            return "Use an OpenAI Realtime-compatible endpoint you run yourself."
        }
    }

    var polishingDescription: String {
        switch self {
        case .managedLocal:
            return "Runs the bundled polishing engine on this Mac."
        case .externalURL:
            return "Use an OpenAI-compatible chat completions endpoint you run yourself."
        }
    }
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

/// Sendable bridge from the main-actor settings model to the broker's POSIX
/// connection threads. A reference wrapper is intentional: `Mutex` itself is
/// noncopyable, while the broker predicate needs to retain shared state.
private final class ClaudeLocalTitleMarkerFallbackState: Sendable {
    private let enabled: Mutex<Bool>

    init(_ enabled: Bool = false) {
        self.enabled = Mutex(enabled)
    }

    func get() -> Bool {
        enabled.withLock { $0 }
    }

    func set(_ value: Bool) {
        enabled.withLock { $0 = value }
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
        static let apiKey = "settings.api_key"
        static let realtimeAPIModelName = "settings.realtime_api_model_name"
        static let dictationBackendMode = "settings.dictation_backend_mode"
        static let speechdCacheLimit = "settings.speechd_cache_limit"
        static let speechdStepCadence = "settings.speechd_step_cadence"
        static let polishingBackendMode = "settings.polishing_backend_mode"
        // Legacy global backend mode. Read only for one-time migration.
        static let backendMode = "settings.backend_mode"
        static let onboardingCompleted = "settings.onboarding_completed"
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
        static let managedLLMPolishingModel = "settings.managed_llm_polishing_model"
        static let replacementDictionaryEnabled = "settings.replacement_dictionary_enabled"
        static let agentPolishProfileEnabled = "settings.agent_polish_profile_enabled"
        static let polishClipboardContextEnabled = "settings.polish_clipboard_context_enabled"
        static let clipboardPayloadMacroEnabled = "settings.clipboard_payload_macro_enabled"
        static let terminalScreenContextEnabled = "settings.terminal_screen_context_enabled"
        static let repoVocabularyEnabled = "settings.repo_vocabulary_enabled"
        static let claudeRepoContextEnabled = "settings.claude_repo_context_enabled"
        static let claudeLocalTitleMarkerFallbackEnabled =
            "settings.claude_local_title_marker_fallback_enabled"
        static let cmuxSurfaceJoinEnabled = "settings.cmux_surface_join_enabled"
        static let polishContextTrustedEndpointEnabled =
            "settings.polish_context_trusted_endpoint_enabled"
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
        #endif
        static let modifierOnlyHotKeyEnabled = "settings.modifier_only_hotkey_enabled"
        static let modifierOnlyHotKeyModifier = "settings.modifier_only_hotkey_modifier"
        static let modifierOnlyHoldDelay = "settings.modifier_only_hold_delay"
        static let overlayBufferShortcutKeyCode = "settings.overlay_buffer_shortcut_key_code"
        static let overlayBufferShortcutModifiers =
            "settings.overlay_buffer_shortcut_carbon_modifiers"
        static let overlayBufferShortcutEnabled = "settings.overlay_buffer_shortcut_enabled"
        static let overlayBufferFontSize = "settings.overlay_buffer_font_size"
        static let livePasteShortcutKeyCode = "settings.live_paste_shortcut_key_code"
        static let livePasteShortcutModifiers = "settings.live_paste_shortcut_carbon_modifiers"
        static let livePasteShortcutEnabled = "settings.live_paste_shortcut_enabled"
    }

    private let defaults: UserDefaults
    @ObservationIgnored private let claudeLocalTitleMarkerFallbackState =
        ClaudeLocalTitleMarkerFallbackState()

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
        didSet { defaults.set(dictationBackendMode.rawValue, forKey: Keys.dictationBackendMode) }
    }

    var polishingBackendMode: BackendMode {
        didSet { defaults.set(polishingBackendMode.rawValue, forKey: Keys.polishingBackendMode) }
    }

    /// Metal buffer-pool cache limit for the managed dictation helper. Changing
    /// it from Settings restarts the engine so the new argv applies immediately
    /// (`DictationViewModel.applySpeechdCacheLimitChange`); direct writes apply
    /// on the next (re)start.
    var speechdCacheLimit: SpeechdCacheLimit {
        didSet { defaults.set(speechdCacheLimit.rawValue, forKey: Keys.speechdCacheLimit) }
    }

    /// Streaming step cadence for the managed dictation helper. Same restart
    /// contract as `speechdCacheLimit`.
    var speechdStepCadence: SpeechdStepCadence {
        didSet { defaults.set(speechdStepCadence.rawValue, forKey: Keys.speechdStepCadence) }
    }

    /// True once the user has completed (or skipped) the first-launch onboarding
    /// wizard. Resolved once at init (see `resolveOnboardingCompleted`) and
    /// persisted immediately so the wizard shows exactly once for fresh installs.
    /// The General settings pane's "Re-run Setup…" resets it to false.
    var onboardingCompleted: Bool {
        didSet { defaults.set(onboardingCompleted, forKey: Keys.onboardingCompleted) }
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

    /// Whether LOCAL Claude Code hook responses may write the broker-allocated
    /// session marker into the terminal window title. Opt-in (default false):
    /// focused-pane TTY is the normal local join, while users on terminals
    /// without that capability can explicitly restore the title fallback.
    ///
    /// This preference does not govern remote hook responses. SSH sessions can
    /// only join through their title marker, so the remote listener always
    /// emits one independently.
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

    var claudeLocalTitleMarkerFallbackEnabled: Bool {
        didSet {
            claudeLocalTitleMarkerFallbackState.set(claudeLocalTitleMarkerFallbackEnabled)
            defaults.set(
                claudeLocalTitleMarkerFallbackEnabled,
                forKey: Keys.claudeLocalTitleMarkerFallbackEnabled
            )
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

    /// A sendable, live view of the preference for the broker's background
    /// connection threads. The synchronized mirror keeps actor-isolated UI
    /// state and non-Sendable `UserDefaults` out of the socket service, while a
    /// Settings toggle still takes effect without restarting the app.
    func makeClaudeLocalTitleMarkerFallbackProvider() -> @Sendable () -> Bool {
        let state = claudeLocalTitleMarkerFallbackState
        return { state.get() }
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
        // false. "Re-run Setup…" resets that flag to false on an existing
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
        managedLLMPolishingModel = Self.loadString(
            defaults: defaults, key: Keys.managedLLMPolishingModel,
            envKey: "MANAGED_LLM_POLISHING_MODEL", fallback: Self.defaultLLMPolishingModel,
            environment: environment
        )
        replacementDictionaryEnabled = Self.loadBool(
            defaults: defaults, key: Keys.replacementDictionaryEnabled, fallback: false)
        agentPolishProfileEnabled = Self.loadBool(
            defaults: defaults, key: Keys.agentPolishProfileEnabled, fallback: true)
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
        claudeLocalTitleMarkerFallbackEnabled = Self.loadBool(
            defaults: defaults,
            key: Keys.claudeLocalTitleMarkerFallbackEnabled,
            fallback: false
        )
        cmuxSurfaceJoinEnabled = Self.loadBool(
            defaults: defaults, key: Keys.cmuxSurfaceJoinEnabled, fallback: false)
        polishContextTrustedEndpointEnabled = Self.loadBool(
            defaults: defaults, key: Keys.polishContextTrustedEndpointEnabled, fallback: false)
        debugLogRealtimeDeltas = Self.loadBool(
            defaults: defaults, key: Keys.debugLogRealtimeDeltas, fallback: false)
        #if LOCALVOXTRAL_DOGFOOD
        dogfoodCaptureEnabled = Self.loadBool(
            defaults: defaults, key: Keys.dogfoodCaptureEnabled, fallback: false)
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

        claudeLocalTitleMarkerFallbackState.set(claudeLocalTitleMarkerFallbackEnabled)
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
            // The bundled Swift engine needs its dedicated HF-layout pin.
            // Keep the external provider's placeholder/default independent:
            // user-typed external values remain ignored in managed mode, but
            // an existing external endpoint still sees its historical model.
            return SpeechModelCatalog.defaultOption.repoID
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
}

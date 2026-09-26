import Foundation
#if canImport(os)
import os
#endif

/// Centralised loggers for the application. Each subsystem component gets its
/// own category so messages can be filtered in Console.app with:
///   `subsystem:com.localvoxtral  category:Microphone`
///
/// In localvoxtralCore so Foundation-only code that logs can build on Linux,
/// where every category is a `SilentLogger` (`CoreLog.swift`) that drops its
/// messages. On Apple platforms nothing changes.
package enum Log {
    #if canImport(os)
    private static let subsystem = "com.localvoxtral"
    #endif

    #if canImport(os)
    package static let microphone = Logger(subsystem: subsystem, category: "Microphone")
    #else
    package static let microphone = SilentLogger()
    #endif
    #if canImport(os)
    package static let dictation = Logger(subsystem: subsystem, category: "Dictation")
    #else
    package static let dictation = SilentLogger()
    #endif
    #if canImport(os)
    package static let realtime = Logger(subsystem: subsystem, category: "Realtime")
    #else
    package static let realtime = SilentLogger()
    #endif
    #if canImport(os)
    package static let mlxRealtime = Logger(subsystem: subsystem, category: "MlxRealtime")
    #else
    package static let mlxRealtime = SilentLogger()
    #endif
    #if canImport(os)
    package static let insertion = Logger(subsystem: subsystem, category: "Insertion")
    #else
    package static let insertion = SilentLogger()
    #endif
    #if canImport(os)
    package static let overlay = Logger(subsystem: subsystem, category: "Overlay")
    #else
    package static let overlay = SilentLogger()
    #endif
    #if canImport(os)
    package static let polishing = Logger(subsystem: subsystem, category: "Polishing")
    #else
    package static let polishing = SilentLogger()
    #endif
    #if canImport(os)
    package static let persistence = Logger(subsystem: subsystem, category: "Persistence")
    #else
    package static let persistence = SilentLogger()
    #endif
    #if canImport(os)
    package static let config = Logger(subsystem: subsystem, category: "Config")
    #else
    package static let config = SilentLogger()
    #endif
    #if canImport(os)
    package static let backends = Logger(subsystem: subsystem, category: "Backends")
    #else
    package static let backends = SilentLogger()
    #endif
    #if canImport(os)
    package static let widgets = Logger(subsystem: subsystem, category: "Widgets")
    #else
    package static let widgets = SilentLogger()
    #endif
    #if canImport(os)
    package static let replacements = Logger(subsystem: subsystem, category: "Replacements")
    #else
    package static let replacements = SilentLogger()
    #endif
    #if canImport(os)
    package static let corrector = Logger(subsystem: subsystem, category: "Corrector")
    #else
    package static let corrector = SilentLogger()
    #endif
    /// Opt-in raw realtime delta instrumentation for issue #13. Emits at notice
    /// level so it is visible by default under `log stream` / Console. Gated by
    /// `SettingsStore.debugLogRealtimeDeltas`; see that property's docs for the
    /// privacy trade-off.
    #if canImport(os)
    package static let deltas = Logger(subsystem: subsystem, category: "Deltas")
    #else
    package static let deltas = SilentLogger()
    #endif
    #if canImport(os)
    package static let escape = Logger(subsystem: subsystem, category: "Escape")
    #else
    package static let escape = SilentLogger()
    #endif
    /// Session-start target detection: terminal-like verdicts and Secure
    /// Keyboard Entry warnings (see `TerminalTargetDetector`).
    #if canImport(os)
    package static let target = Logger(subsystem: subsystem, category: "Target")
    #else
    package static let target = SilentLogger()
    #endif
    #if canImport(os)
    package static let modifierKeys = Logger(subsystem: subsystem, category: "ModifierKeys")
    #else
    package static let modifierKeys = SilentLogger()
    #endif
    /// Output-volume ducking around a dictation session
    /// (`AudioDuckingController`): every duck, restore and refused volume
    /// write. A volume failure is otherwise invisible — the user just ends up
    /// quiet — and expensive to diagnose remotely.
    #if canImport(os)
    package static let ducking = Logger(subsystem: subsystem, category: "Ducking")
    #else
    package static let ducking = SilentLogger()
    #endif
    #if canImport(os)
    package static let diagnostics = Logger(subsystem: subsystem, category: "Diagnostics")
    #else
    package static let diagnostics = SilentLogger()
    #endif
    /// Keychain access for the stored API keys (`KeychainSecretStore`) and the
    /// one-time migration out of UserDefaults. Logs operations, accounts and
    /// OSStatus values only — never a key, not even truncated.
    #if canImport(os)
    package static let secrets = Logger(subsystem: subsystem, category: "Secrets")
    #else
    package static let secrets = SilentLogger()
    #endif
    /// Claude Code context ingest: broker lifecycle, rejected connections and
    /// records. NEVER logs hook content — a record carries the user's prompt
    /// and their file paths. Only event names, counts, and failure reasons.
    #if canImport(os)
    package static let claudeContext = Logger(subsystem: subsystem, category: "ClaudeContext")
    #else
    package static let claudeContext = SilentLogger()
    #endif
}

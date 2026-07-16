import os

/// Centralised loggers for the application. Each subsystem component gets its
/// own category so messages can be filtered in Console.app with:
///   `subsystem:com.localvoxtral  category:Microphone`
enum Log {
    private static let subsystem = "com.localvoxtral"

    static let microphone = Logger(subsystem: subsystem, category: "Microphone")
    static let dictation = Logger(subsystem: subsystem, category: "Dictation")
    static let realtime = Logger(subsystem: subsystem, category: "Realtime")
    static let mlxRealtime = Logger(subsystem: subsystem, category: "MlxRealtime")
    static let insertion = Logger(subsystem: subsystem, category: "Insertion")
    static let overlay = Logger(subsystem: subsystem, category: "Overlay")
    static let polishing = Logger(subsystem: subsystem, category: "Polishing")
    static let persistence = Logger(subsystem: subsystem, category: "Persistence")
    static let config = Logger(subsystem: subsystem, category: "Config")
    static let backends = Logger(subsystem: subsystem, category: "Backends")
    static let replacements = Logger(subsystem: subsystem, category: "Replacements")
    static let corrector = Logger(subsystem: subsystem, category: "Corrector")
    /// Opt-in raw realtime delta instrumentation for issue #13. Emits at notice
    /// level so it is visible by default under `log stream` / Console. Gated by
    /// `SettingsStore.debugLogRealtimeDeltas`; see that property's docs for the
    /// privacy trade-off.
    static let deltas = Logger(subsystem: subsystem, category: "Deltas")
    static let escape = Logger(subsystem: subsystem, category: "Escape")
    /// Session-start target detection: terminal-like verdicts and Secure
    /// Keyboard Entry warnings (see `TerminalTargetDetector`).
    static let target = Logger(subsystem: subsystem, category: "Target")
    static let modifierKeys = Logger(subsystem: subsystem, category: "ModifierKeys")
    static let diagnostics = Logger(subsystem: subsystem, category: "Diagnostics")
    /// Claude Code context ingest: broker lifecycle, rejected connections and
    /// records. NEVER logs hook content — a record carries the user's prompt
    /// and their file paths. Only event names, counts, and failure reasons.
    static let claudeContext = Logger(subsystem: subsystem, category: "ClaudeContext")
}

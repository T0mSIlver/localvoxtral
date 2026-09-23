import Foundation

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

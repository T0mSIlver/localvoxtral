import Foundation

/// Streaming step cadence for the managed dictation helper, passed as
/// `--step-ms`: how much audio is batched before each incremental
/// transcription step. Lower values show words sooner; higher values leave
/// more compute headroom.
enum SpeechdStepCadence: String, CaseIterable, Identifiable, Sendable {
    case ms100 = "100ms"
    case ms240 = "240ms"
    case ms480 = "480ms"

    static let defaultCadence: SpeechdStepCadence = .ms100

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ms100: return "100 ms"
        case .ms240: return "240 ms"
        case .ms480: return "480 ms"
        }
    }

    var milliseconds: Int {
        switch self {
        case .ms100: return 100
        case .ms240: return 240
        case .ms480: return 480
        }
    }
}

import Foundation

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

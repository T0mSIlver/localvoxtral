import Foundation

package enum DictationOutputMode: String, CaseIterable, Identifiable, Sendable {
    case overlayBuffer = "overlay_buffer"
    case liveAutoPaste = "live_auto_paste"

    package var id: String { rawValue }

    package var displayName: String {
        switch self {
        case .overlayBuffer:
            return "Overlay Buffer"
        case .liveAutoPaste:
            return "Live Auto-Paste"
        }
    }

}

import Foundation

/// Metal buffer-pool cache limit for the managed dictation helper, passed as
/// `--cache-limit-mb`. It caps MLX's buffer cache, not the weights or the live
/// working set. On Voxtral the cache fills to whatever limit is set while time
/// per step stays flat, so the smallest preset is the default (#486).
enum SpeechdCacheLimit: String, CaseIterable, Identifiable, Sendable {
    case gb2 = "2gb"
    case gb4 = "4gb"
    case gb6 = "6gb"
    case gb8 = "8gb"

    static let defaultLimit: SpeechdCacheLimit = .gb2

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gb2: return "2 GB"
        case .gb4: return "4 GB"
        case .gb6: return "6 GB"
        case .gb8: return "8 GB"
        }
    }

    var megabytes: Int {
        switch self {
        case .gb2: return 2048
        case .gb4: return 4096
        case .gb6: return 6144
        case .gb8: return 8192
        }
    }
}

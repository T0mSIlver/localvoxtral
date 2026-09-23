import Foundation

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

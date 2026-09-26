import Foundation

/// Whether the Overlay Buffer keeps a word on its line while it is still being
/// dictated, and how long a word that covers. Off by default: the text then
/// wraps at the full panel width, and a half-streamed word that stops fitting
/// moves down a line as it grows. On, `OverlayStableLineWrapper` keeps room
/// for a word of `letters` length at the end of each line, which stops that
/// move at the cost of a ragged right edge up to that wide (#640).
enum OverlayWordHold: Int, CaseIterable, Identifiable, Sendable {
    case off = 0
    case upTo6Letters = 6
    case upTo10Letters = 10
    case upTo14Letters = 14

    var id: Int { rawValue }

    /// Nil for `off`.
    var letters: Int? { self == .off ? nil : rawValue }

    var displayName: String {
        self == .off ? "Off" : "Up to \(rawValue) letters"
    }
}

import Foundation

/// The status dot a sidebar row or a pane status line renders. The meanings
/// are fixed by the owner decision (2026-09-07, modelled on CodexBar):
///
/// - green: detected and set up — dictation joins will work.
/// - yellow: detected, but a setup step is pending (a plugin not installed, a
///   version floor not met, a socket not configured) — dictation only.
/// - grey: not installed / not detected.
package enum SettingsStatusDot: Equatable, Sendable {
    case green
    case yellow
    case grey
}

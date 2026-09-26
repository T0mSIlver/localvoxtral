import Foundation

/// Why a dictation's join never reached the resolver. The raw value is the
/// cause the outcome line and the dogfood record carry: a category, never a
/// path, host, address or id.
package enum ClaudeJoinGate: String, Equatable, Sendable {
    case noPolishingEndpoint = "gate: no polishing endpoint"
    case noResolver = "gate: no resolver installed"
    case contextSettingsOff = "gate: both context settings off"
    case endpointNotPermitted = "gate: endpoint not permitted"
    case accessibilityNotTrusted = "gate: accessibility not trusted"
    case noFrontmostTarget = "gate: no frontmost supported terminal"
    case browserWithoutSessionContext = "gate: browser target without session context"
    case desktopWithoutSessionContext = "gate: Claude Desktop target without session context"
}

/// How far one dictation's join got: stopped by a gate before the resolver
/// was asked, or answered by it.
package enum ClaudeJoinAttempt: Equatable, Sendable {
    case gated(ClaudeJoinGate)
    case resolved(ClaudeJoinResolution)

    package var join: ClaudeSessionJoin? {
        guard case .resolved(let resolution) = self else { return nil }
        return resolution.join
    }
}

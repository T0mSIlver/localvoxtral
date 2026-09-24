import Foundation

/// How long an Overlay Buffer tap session may go without new transcript
/// text before it stops on its own, as if the user had tapped stop. Off by
/// default. Hold sessions and Live Auto-Paste never auto-stop: a hold ends
/// on release, and live text is already typed.
enum SilenceAutoStop: Int, CaseIterable, Identifiable, Sendable {
    case off = 0
    case after5 = 5
    case after8 = 8
    case after15 = 15
    case after30 = 30

    var id: Int { rawValue }

    /// Nil for `off`.
    var seconds: TimeInterval? { self == .off ? nil : TimeInterval(rawValue) }

    var displayName: String {
        self == .off ? "Never" : "After \(rawValue) s"
    }
}

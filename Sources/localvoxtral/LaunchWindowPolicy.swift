import Foundation

/// What a finished launch puts on screen.
enum LaunchWindowDecision: Equatable, Sendable {
    /// The first-launch onboarding wizard.
    case onboarding
    /// The localvoxtral window, on History.
    case window
    case nothing
}

/// Decides it. A menu bar app has no launch window scene, so this is a choice
/// the app delegate makes rather than something a `WindowGroup` settles.
enum LaunchWindowPolicy {
    /// Onboarding outranks the setting: a first launch shows the wizard and
    /// nothing else (#449), and the window the user then turns on at launch
    /// arrives at the launch after that.
    static func decide(
        onboardingCompleted: Bool,
        opensWindowAtLaunch: Bool
    ) -> LaunchWindowDecision {
        guard onboardingCompleted else { return .onboarding }
        return opensWindowAtLaunch ? .window : .nothing
    }
}

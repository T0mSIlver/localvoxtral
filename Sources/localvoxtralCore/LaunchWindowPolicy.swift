import Foundation

/// What a finished launch puts on screen.
package enum LaunchWindowDecision: Equatable, Sendable {
    /// The first-launch onboarding wizard.
    case onboarding
    /// The localvoxtral window, on History.
    case window
    case nothing
}

/// Decides it. A menu bar app has no launch window scene, so this is a choice
/// the app delegate makes rather than something a `WindowGroup` settles.
package enum LaunchWindowPolicy {
    /// Onboarding outranks the setting: a first launch shows the wizard and
    /// nothing else (#449), and the window the user then turns on at launch
    /// arrives at the launch after that.
    /// A launch smoke shows nothing: it runs under a throwaway home whose
    /// preferences say onboarding never ran, and the wizard would take focus
    /// on the owner's desktop (#985).
    package static func decide(
        onboardingCompleted: Bool,
        opensWindowAtLaunch: Bool,
        isLaunchSmoke: Bool = false
    ) -> LaunchWindowDecision {
        guard !isLaunchSmoke else { return .nothing }
        guard onboardingCompleted else { return .onboarding }
        return opensWindowAtLaunch ? .window : .nothing
    }
}

import Foundation

/// When the app may update itself (LVX-57).
///
/// Sparkle downloads a new release in the background and hands the app a
/// handler that installs it and relaunches. A menu bar app rarely quits, so
/// the app calls that handler itself, at a moment the relaunch costs nothing:
/// no dictation listening or finalizing, and nobody at the keyboard.
package enum AppUpdatePolicy {
    /// The Developer ID team every release is signed by. Only a copy signed by
    /// it updates itself: Sparkle would accept a release over a self-signed or
    /// ad-hoc copy too (same feed key), and that copy is a try-pr build or a
    /// CI artifact that must stay what it is.
    package static let releaseTeamIdentifier = "3N63N7U9R3"

    /// The code requirement a release satisfies (`codesign -d -r-` on any
    /// release since #1430 names the team the same way).
    package static var releaseTeamRequirement: String {
        "anchor apple generic and certificate leaf[subject.OU] = \"\(releaseTeamIdentifier)\""
    }

    /// No keyboard or mouse input for this long counts as away.
    package static let userIdleBeforeInstall: TimeInterval = 5 * 60

    /// How often a downloaded update looks for its moment.
    package static let installRetryInterval: Duration = .seconds(60)

    package enum DisabledReason: Equatable, Sendable {
        /// A debug or harness build.
        case developmentBuild
        /// A CI launch beside the owner's copy (launch smoke, lanes).
        case ciCopy
        /// Not signed by the release team: try-pr, a self-signed dev build,
        /// an ad-hoc nightly.
        case notReleaseSigned
    }

    /// Why this copy must not update itself, or nil when it may.
    package static func disabledReason(
        isReleaseBuild: Bool,
        isCICopy: Bool,
        isSignedByReleaseTeam: Bool
    ) -> DisabledReason? {
        if !isReleaseBuild { return .developmentBuild }
        if isCICopy { return .ciCopy }
        if !isSignedByReleaseTeam { return .notReleaseSigned }
        return nil
    }

    /// A downloaded update installs now only if the relaunch loses nothing.
    package static func installsNow(isDictationIdle: Bool, secondsSinceUserInput: TimeInterval) -> Bool {
        isDictationIdle && secondsSinceUserInput >= userIdleBeforeInstall
    }
}

/// Holds Sparkle's install handler until `AppUpdatePolicy.installsNow` holds,
/// checking every `installRetryInterval` on the injected sleep.
@MainActor
package final class PendingUpdateInstall {
    package struct Environment {
        package var isDictationIdle: @MainActor () -> Bool
        package var secondsSinceUserInput: @MainActor () -> TimeInterval
        package var sleep: @Sendable (Duration) async -> Void

        package init(
            isDictationIdle: @escaping @MainActor () -> Bool,
            secondsSinceUserInput: @escaping @MainActor () -> TimeInterval,
            sleep: @escaping @Sendable (Duration) async -> Void
        ) {
            self.isDictationIdle = isDictationIdle
            self.secondsSinceUserInput = secondsSinceUserInput
            self.sleep = sleep
        }
    }

    private let environment: Environment
    private let log: @MainActor (String) -> Void
    private var task: Task<Void, Never>?

    package init(environment: Environment, log: @escaping @MainActor (String) -> Void) {
        self.environment = environment
        self.log = log
    }

    package var isWaiting: Bool { task != nil }

    /// Replaces any handler already waiting: Sparkle's newest one wins.
    package func hold(version: String, install: @escaping @MainActor () -> Void) {
        task?.cancel()
        log("update \(version) downloaded; installing once dictation is idle and the user is away")
        task = Task { @MainActor [environment, log] in
            var deferrals = 0
            while !Task.isCancelled {
                let idle = environment.isDictationIdle()
                let away = environment.secondsSinceUserInput()
                if AppUpdatePolicy.installsNow(isDictationIdle: idle, secondsSinceUserInput: away) {
                    log("installing update \(version) after \(deferrals) deferral(s)")
                    self.task = nil
                    install()
                    return
                }
                deferrals += 1
                await environment.sleep(AppUpdatePolicy.installRetryInterval)
            }
        }
    }

    package func cancel() {
        task?.cancel()
        task = nil
    }
}

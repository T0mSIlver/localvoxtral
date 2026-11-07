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
        /// an ad-hoc rc.
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

    /// A downloaded update installs now only if the relaunch loses nothing:
    /// never during a dictation, and, unless the user asked for it, only
    /// once they are away.
    package static func installsNow(
        isDictationIdle: Bool,
        secondsSinceUserInput: TimeInterval,
        userAsked: Bool
    ) -> Bool {
        isDictationIdle && (userAsked || secondsSinceUserInput >= userIdleBeforeInstall)
    }
}

/// Holds Sparkle's install handler until `AppUpdatePolicy.installsNow` holds,
/// checking every `installRetryInterval` on the injected sleep.
///
/// Sparkle keeps its update cycle open while the app holds the handler, so
/// the handler is never dropped: with automatic installs off it waits for the
/// user (Check for Updates…, or Sparkle installing it on quit), and turning
/// them back on resumes the wait.
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

    private struct Held {
        let version: String
        let install: @MainActor () -> Void
        var userAsked: Bool
    }

    private let environment: Environment
    private let log: @MainActor (String) -> Void
    private var held: Held?
    private var task: Task<Void, Never>?

    /// Mirrors Sparkle's automatic-install preference.
    package var installsAutomatically: Bool {
        didSet { if installsAutomatically != oldValue { reschedule() } }
    }

    package init(
        installsAutomatically: Bool,
        environment: Environment,
        log: @escaping @MainActor (String) -> Void
    ) {
        self.installsAutomatically = installsAutomatically
        self.environment = environment
        self.log = log
    }

    /// An update is downloaded and not yet installed.
    package var isHolding: Bool { held != nil }

    /// Sparkle downloaded an update on its own. Replaces any update already
    /// held: Sparkle's newest handler wins.
    package func hold(version: String, install: @escaping @MainActor () -> Void) {
        held = Held(version: version, install: install, userAsked: false)
        log(
            installsAutomatically
                ? "update \(version) downloaded; installing once dictation is idle and the user is away"
                : "update \(version) downloaded; automatic installs are off, waiting for the user"
        )
        reschedule()
    }

    /// The user asked to install (Sparkle's Install button, or Check for
    /// Updates… with an update held): install as soon as no dictation runs.
    package func installWhenDictationIdle(version: String, install: @escaping @MainActor () -> Void) {
        held = Held(version: version, install: install, userAsked: true)
        log("update \(version): installing once dictation is idle")
        reschedule()
    }

    /// Check for Updates… with an update already held installs that one.
    /// False when nothing is held.
    package func installHeldUpdateForUser() -> Bool {
        guard var held else { return false }
        held.userAsked = true
        self.held = held
        log("update \(held.version): the user asked; installing once dictation is idle")
        reschedule()
        return true
    }

    private func reschedule() {
        task?.cancel()
        task = nil
        guard let held, held.userAsked || installsAutomatically else { return }
        task = Task { @MainActor [environment, log] in
            var deferrals = 0
            while !Task.isCancelled {
                if AppUpdatePolicy.installsNow(
                    isDictationIdle: environment.isDictationIdle(),
                    secondsSinceUserInput: environment.secondsSinceUserInput(),
                    userAsked: held.userAsked
                ) {
                    log("installing update \(held.version) after \(deferrals) deferral(s)")
                    self.task = nil
                    self.held = nil
                    held.install()
                    return
                }
                deferrals += 1
                await environment.sleep(AppUpdatePolicy.installRetryInterval)
            }
        }
    }
}

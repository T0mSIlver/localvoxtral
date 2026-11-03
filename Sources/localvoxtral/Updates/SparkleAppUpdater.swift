import AppKit
import CoreGraphics
import Foundation
import Security
import Sparkle

/// Sparkle 2, set up so a release installs itself while nobody is using it
/// (LVX-57, card d_network-local-grief). The feed and its public key are in
/// Info.plist (`scripts/package_app.sh`); `release.yml` publishes the appcast
/// as an asset of each stable release.
///
/// Sparkle downloads in the background and, by default, installs on quit. A
/// menu bar app rarely quits, so `willInstallUpdateOnQuit` hands the install
/// to `PendingUpdateInstall`, which runs it once no dictation is active and
/// the user has been away for `AppUpdatePolicy.userIdleBeforeInstall`.
@MainActor
final class SparkleAppUpdater: NSObject {
    private let model: AppUpdateModel
    private let pending: PendingUpdateInstall
    private var controller: SPUStandardUpdaterController?

    init(model: AppUpdateModel, isDictationIdle: @escaping @MainActor () -> Bool) {
        self.model = model
        self.pending = PendingUpdateInstall(
            environment: .init(
                isDictationIdle: isDictationIdle,
                secondsSinceUserInput: {
                    // kCGAnyInputEventType: keyboard, mouse and trackpad.
                    CGEventSource.secondsSinceLastEventType(
                        .combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
                },
                sleep: { try? await Task.sleep(for: $0) }
            ),
            log: { Log.backends.info("updates: \($0, privacy: .public)") }
        )
        super.init()
    }

    /// Starts Sparkle, unless this copy must not update itself.
    func start() {
        let reason = AppUpdatePolicy.disabledReason(
            isReleaseBuild: Self.isReleaseBuild,
            isCICopy: StartupPermissionSuppression.leavesHookSocketsAlone(),
            isSignedByReleaseTeam: Self.mainBundleIsSignedByReleaseTeam()
        )
        if let reason {
            Log.backends.info("updates: off for this copy (\(String(describing: reason), privacy: .public))")
            return
        }
        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        do {
            try controller.updater.start()
        } catch {
            Log.backends.error("updates: Sparkle did not start: \(error.localizedDescription, privacy: .public)")
            return
        }
        self.controller = controller
        let updater = controller.updater
        model.connect(
            installsAutomatically: updater.automaticallyDownloadsUpdates,
            setInstallsAutomatically: { [weak self] on in
                updater.automaticallyDownloadsUpdates = on
                if !on { self?.pending.cancel() }
                Log.backends.info("updates: install automatically \(on ? "on" : "off", privacy: .public)")
            },
            checkForUpdates: { [weak controller] in controller?.checkForUpdates(nil) }
        )
        Log.backends.info(
            "updates: Sparkle started, feed \(updater.feedURL?.absoluteString ?? "none", privacy: .public)"
        )
    }

    private static var isReleaseBuild: Bool {
        #if DEBUG || LOCALVOXTRAL_E2E_HARNESS
        false
        #else
        true
        #endif
    }

    private static func mainBundleIsSignedByReleaseTeam() -> Bool {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess,
              let code,
              SecRequirementCreateWithString(AppUpdatePolicy.releaseTeamRequirement as CFString, [], &requirement)
                == errSecSuccess,
              let requirement
        else { return false }
        return SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
}

extension SparkleAppUpdater: SPUUpdaterDelegate {
    nonisolated func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        let version = item.displayVersionString
        let install = UncheckedSendableBox(immediateInstallHandler)
        MainActor.assumeIsolated {
            pending.hold(version: version) { install.value() }
        }
        return true
    }

    nonisolated func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        if let error = error as NSError?, error.code != Int(SUError.noUpdateError.rawValue) {
            Log.backends.error("updates: check failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        Log.backends.info("updates: found \(item.displayVersionString, privacy: .public) (build \(item.versionString, privacy: .public))")
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        Log.backends.error("updates: aborted: \(error.localizedDescription, privacy: .public)")
    }
}

extension SparkleAppUpdater: SPUStandardUserDriverDelegate {
    /// A menu bar app has no Dock icon for Sparkle's window to come up
    /// behind; with automatic installs off, the window shows without taking
    /// focus from whatever the user is dictating into.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        true
    }
}

/// Sparkle calls its delegate on the main thread and its handler is safe to
/// call there; the box only carries it across the `assumeIsolated` boundary.
private struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

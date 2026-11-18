import Foundation
import Observation

/// What Settings → About shows about updates (LVX-57). `SparkleAppUpdater`
/// drives it; a copy that must not update itself (a debug, CI or try-pr
/// build) leaves it unavailable, and the rows stay hidden.
@MainActor
@Observable
final class AppUpdateModel {
    private(set) var isAvailable = false
    /// Sparkle's own preference (`SUAutomaticallyUpdate`), on by default
    /// through Info.plist. Off: Sparkle offers each update in its window.
    var installsAutomatically = true {
        didSet {
            guard installsAutomatically != oldValue else { return }
            setInstallsAutomatically(installsAutomatically)
        }
    }

    @ObservationIgnored private var setInstallsAutomatically: (Bool) -> Void = { _ in }
    @ObservationIgnored private var checkNow: () -> Void = {}

    func connect(
        installsAutomatically: Bool,
        setInstallsAutomatically: @escaping (Bool) -> Void,
        checkForUpdates: @escaping () -> Void
    ) {
        self.setInstallsAutomatically = { _ in }
        self.installsAutomatically = installsAutomatically
        self.setInstallsAutomatically = setInstallsAutomatically
        self.checkNow = checkForUpdates
        isAvailable = true
    }

    func checkForUpdates() {
        checkNow()
    }
}

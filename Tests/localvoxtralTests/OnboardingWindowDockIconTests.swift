import AppKit
import XCTest

@testable import localvoxtral

/// The wizard registers with `DockIconPolicy` by hand rather than through
/// `DockIconWindowRegistrar` — it owns a plain `NSWindow`, not a SwiftUI
/// scene — so the pairing is its own code and gets its own test. A wizard that
/// registered and never deregistered would leave a Dock icon behind for the
/// rest of the session, on the one flow a user sees exactly once.
@MainActor
final class OnboardingWindowDockIconTests: XCTestCase {
    private var applied: [NSApplication.ActivationPolicy] = []

    private func makeController(
        policy: DockIconPolicy
    ) -> OnboardingWindowController {
        // An isolated suite and an in-memory secret store: `SettingsStore`
        // traps under XCTest rather than touch the runner's login keychain.
        let defaults = UserDefaults(suiteName: "OnboardingWindowDockIconTests.\(UUID().uuidString)")!
        let settings = SettingsStore(
            defaults: defaults,
            environment: [:],
            secretStore: InMemorySecretStore()
        )
        let backendManager = OnboardingTestBackendManager()
        let viewModel = DictationViewModel(
            settings: settings,
            backendManager: backendManager,
            startRuntimeServices: false
        )
        return OnboardingWindowController(
            settings: settings,
            viewModel: viewModel,
            backendManager: backendManager,
            dockIconPolicy: policy,
            openEndpointsSettings: {}
        )
    }

    private func makePolicy() -> DockIconPolicy {
        applied = []
        return DockIconPolicy(initialPolicy: .accessory) { [weak self] policy in
            self?.applied.append(policy)
            return true
        }
    }

    func testPresentingTheWizardShowsTheDockIcon() {
        let policy = makePolicy()
        let controller = makeController(policy: policy)

        controller.present()

        XCTAssertEqual(policy.currentPolicy, .regular)
        XCTAssertEqual(applied, [.regular])

        controller.debugCloseWindowForTesting()
    }

    /// Closing the wizard is how it is skipped as well as how it is finished,
    /// so the Dock icon has to go on the same path either way.
    func testClosingTheWizardHidesTheDockIcon() {
        let policy = makePolicy()
        let controller = makeController(policy: policy)
        controller.present()

        controller.debugCloseWindowForTesting()

        XCTAssertEqual(policy.currentPolicy, .accessory)
        XCTAssertEqual(applied, [.regular, .accessory])
    }

    /// Presenting an already-open wizard re-activates it rather than making a
    /// second window; the Dock icon must not be applied twice, because each
    /// application activates the app.
    func testPresentingTwiceDoesNotReapplyThePolicy() {
        let policy = makePolicy()
        let controller = makeController(policy: policy)

        controller.present()
        controller.present()

        XCTAssertEqual(applied, [.regular])

        controller.debugCloseWindowForTesting()
    }
}

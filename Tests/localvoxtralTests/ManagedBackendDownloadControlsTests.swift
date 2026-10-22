import XCTest
@testable import localvoxtral

final class ManagedBackendDownloadControlsTests: XCTestCase {
    /// Before setup finishes the Engines warmup is skipped, so Settings'
    /// Try again would do nothing; the wizard's own button retries instead.
    func testTryAgainIsOfferedOnlyOnceSetupIsDone() {
        let failed = ManagedBackendStatus.failed(summary: "offline", detail: nil)

        XCTAssertFalse(ManagedBackendDownloadControls.offersRetry(for: failed, onboardingCompleted: false))
        XCTAssertTrue(ManagedBackendDownloadControls.offersRetry(for: failed, onboardingCompleted: true))
        XCTAssertFalse(ManagedBackendDownloadControls.offersRetry(for: .ready, onboardingCompleted: true))
        XCTAssertFalse(ManagedBackendDownloadControls.offersRetry(for: .stopped, onboardingCompleted: true))
    }
}

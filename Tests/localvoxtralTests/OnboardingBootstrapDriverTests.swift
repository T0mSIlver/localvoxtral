import Foundation
import XCTest
@testable import localvoxtral

// MARK: - Status → item-state mapping

@MainActor
final class OnboardingItemStateMappingTests: XCTestCase {
    func testStopped_isPending() {
        XCTAssertEqual(OnboardingItemState(managedStatus: .stopped), .pending)
    }

    func testStarting_isIndeterminateWorking() {
        XCTAssertEqual(
            OnboardingItemState(managedStatus: .starting),
            .working(detail: "Loading the model…", fraction: nil)
        )
    }

    func testReady_isReady() {
        XCTAssertEqual(OnboardingItemState(managedStatus: .ready), .ready)
    }

    func testFailed_carriesSummary() {
        XCTAssertEqual(
            OnboardingItemState(managedStatus: .failed(summary: "boom", detail: "trace")),
            .failed(summary: "boom")
        )
    }

    func testPreparingModel_withKnownTotal_isDeterminateWorking() {
        XCTAssertEqual(
            OnboardingItemState(
                managedStatus: .preparingModel(
                    progress: ModelDownloadProgress(downloadedBytes: 64, totalBytes: 128)
                )
            ),
            .working(detail: "Downloading model 50%", fraction: 0.5)
        )
    }

    func testPreparingModel_withoutKnownTotal_isCheckingWorking() {
        XCTAssertEqual(
            OnboardingItemState(
                managedStatus: .preparingModel(
                    progress: ModelDownloadProgress(downloadedBytes: 0, totalBytes: nil)
                )
            ),
            .working(detail: "Checking model...", fraction: nil)
        )
    }
}

// MARK: - Live driver

@MainActor
final class LiveOnboardingBootstrapDriverTests: XCTestCase {
    func testStart_seedsItemStatesFromCurrentBackendStatus() {
        let manager = OnboardingTestBackendManager()
        manager.speechdStatus = .preparingModel(
            progress: ModelDownloadProgress(downloadedBytes: 50, totalBytes: 100)
        )
        manager.polishdStatus = .stopped
        let driver = LiveOnboardingBootstrapDriver(backendManager: manager)

        driver.start(dictation: true, polishing: true)

        XCTAssertEqual(
            driver.itemStates[.dictation],
            .working(detail: "Downloading model 50%", fraction: 0.5)
        )
        XCTAssertEqual(driver.itemStates[.polishing], .pending)
    }

    func testStart_requestsEnsureReadyWithRequestedFlags() async {
        let manager = OnboardingTestBackendManager()
        let driver = LiveOnboardingBootstrapDriver(backendManager: manager)

        driver.start(dictation: true, polishing: false)
        await manager.waitForEnsure()

        XCTAssertEqual(
            manager.ensureCalls,
            [OnboardingTestBackendManager.EnsureCall(dictation: true, polishing: false)]
        )
    }

    func testStart_polishingOnly_onlyTracksPolishingItem() {
        let manager = OnboardingTestBackendManager()
        let driver = LiveOnboardingBootstrapDriver(backendManager: manager)

        driver.start(dictation: false, polishing: true)

        XCTAssertEqual(Set(driver.itemStates.keys), [.polishing])
    }

    func testObservation_reflectsBackendStatusChanges() async {
        let manager = OnboardingTestBackendManager()
        manager.speechdStatus = .starting
        let driver = LiveOnboardingBootstrapDriver(backendManager: manager)

        driver.start(dictation: true, polishing: false)
        XCTAssertEqual(
            driver.itemStates[.dictation],
            .working(detail: "Loading the model…", fraction: nil)
        )

        let states = await awaitReadyStateChange(from: driver) {
            manager.speechdStatus = .ready
        }

        XCTAssertEqual(states[.dictation], .ready)
        XCTAssertEqual(driver.itemStates[.dictation], .ready)
    }

    private func awaitReadyStateChange(
        from driver: LiveOnboardingBootstrapDriver,
        afterStartingObservation mutate: () -> Void
    ) async -> [OnboardingItemID: OnboardingItemState] {
        await withCheckedContinuation { continuation in
            driver.onItemStatesChanged = { [weak driver] states in
                guard states[.dictation] == .ready else { return }
                driver?.onItemStatesChanged = nil
                continuation.resume(returning: states)
            }
            mutate()
        }
    }
}

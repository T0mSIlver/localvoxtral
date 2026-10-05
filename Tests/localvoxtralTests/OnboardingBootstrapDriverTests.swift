import Foundation
import XCTest
@testable import localvoxtral

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

    /// Local → Mistral → Local while speechd still shuts down: the start
    /// waits for that stop, or the dying helper reads as ready and the stop
    /// then leaves the page with nothing running and no retry (#1763).
    func testStartWaitsForAPendingShutdownBeforeEnsuringReady() async {
        let manager = OnboardingTestBackendManager()
        let shutdown = BoundedWait()
        let ensureCallsWhileShuttingDown = Box<[Int]>([])
        let driver = LiveOnboardingBootstrapDriver(
            backendManager: manager,
            waitForPendingShutdowns: {
                ensureCallsWhileShuttingDown.value.append(manager.ensureCalls.count)
                _ = await shutdown.value(failAfter: 10)
            }
        )

        driver.start(dictation: true, polishing: false)
        shutdown.resolve()
        await manager.waitForEnsure()

        XCTAssertEqual(ensureCallsWhileShuttingDown.value, [0], "the start must wait for the shutdown first")
        XCTAssertEqual(manager.ensureCalls.count, 1)
    }

    /// A start superseded while it waits never reaches the backend.
    func testAStartSupersededDuringTheShutdownEnsuresOnce() async {
        let manager = OnboardingTestBackendManager()
        let firstShutdown = BoundedWait()
        let waits = Box(0)
        let driver = LiveOnboardingBootstrapDriver(
            backendManager: manager,
            waitForPendingShutdowns: {
                waits.value += 1
                if waits.value == 1 { _ = await firstShutdown.value(failAfter: 10) }
            }
        )

        driver.start(dictation: true, polishing: true)
        driver.start(dictation: true, polishing: false)
        await manager.waitForEnsure()
        firstShutdown.resolve()
        await driver.debugRunTask?.value

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

    private final class Box<Value> {
        var value: Value
        init(_ value: Value) { self.value = value }
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

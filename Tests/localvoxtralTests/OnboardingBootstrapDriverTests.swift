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

// MARK: - Preview driver

@MainActor
final class PreviewOnboardingBootstrapDriverTests: XCTestCase {
    func testStart_recordsRequestAndSeedsPending() {
        let driver = PreviewOnboardingBootstrapDriver()

        driver.start(dictation: true, polishing: true)

        XCTAssertEqual(driver.startCallCount, 1)
        XCTAssertEqual(driver.lastStart?.dictation, true)
        XCTAssertEqual(driver.lastStart?.polishing, true)
        XCTAssertEqual(driver.itemStates, [.dictation: .pending, .polishing: .pending])
    }

    func testStart_dictationOnly_seedsOnlyDictation() {
        let driver = PreviewOnboardingBootstrapDriver()

        driver.start(dictation: true, polishing: false)

        XCTAssertEqual(driver.itemStates, [.dictation: .pending])
    }

    func testAdvance_appliesScriptedFrames() {
        let driver = PreviewOnboardingBootstrapDriver(frames: [
            [.dictation: .working(detail: "Downloading 10%", fraction: 0.1)],
            [.dictation: .ready],
        ])
        driver.start(dictation: true, polishing: false)

        XCTAssertTrue(driver.advance())
        XCTAssertEqual(
            driver.itemStates[.dictation],
            .working(detail: "Downloading 10%", fraction: 0.1)
        )

        XCTAssertTrue(driver.advance())
        XCTAssertEqual(driver.itemStates[.dictation], .ready)

        XCTAssertFalse(driver.advance())
    }

    func testSetState_updatesSingleItem() {
        let driver = PreviewOnboardingBootstrapDriver()
        driver.start(dictation: true, polishing: true)

        driver.setState(.failed(summary: "no disk"), for: .polishing)

        XCTAssertEqual(driver.itemStates[.polishing], .failed(summary: "no disk"))
        XCTAssertEqual(driver.itemStates[.dictation], .pending)
    }

    func testCancel_isRecorded() {
        let driver = PreviewOnboardingBootstrapDriver()
        driver.cancel()
        XCTAssertEqual(driver.cancelCallCount, 1)
    }
}

// MARK: - Shared test doubles

/// Observable fake used by the onboarding tests. `@Observable` so the live
/// driver's `withObservationTracking` mirror fires on status mutation.
@MainActor
@Observable
final class OnboardingTestBackendManager: ManagedBackendManaging {
    struct EnsureCall: Equatable {
        var dictation: Bool
        var polishing: Bool
    }

    var speechdStatus: ManagedBackendStatus = .stopped
    var polishdStatus: ManagedBackendStatus = .stopped
    @ObservationIgnored private var statusUpdateContinuations: [UUID: AsyncStream<ManagedBackendStatusUpdate>.Continuation] = [:]
    var statusUpdates: AsyncStream<ManagedBackendStatusUpdate> {
        let id = UUID()
        let stream = AsyncStream<ManagedBackendStatusUpdate>.makeStream(of: ManagedBackendStatusUpdate.self)
        statusUpdateContinuations[id] = stream.continuation
        stream.continuation.onTermination = { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                self?.statusUpdateContinuations[id] = nil
            }
        }
        return stream.stream
    }

    @ObservationIgnored private(set) var ensureCalls: [EnsureCall] = []
    @ObservationIgnored private(set) var stopAllCallCount = 0
    @ObservationIgnored private(set) var stopDictationCallCount = 0
    @ObservationIgnored private(set) var stopPolishingCallCount = 0
    @ObservationIgnored private var ensureContinuation: CheckedContinuation<Void, Never>?

    func ensureReady(dictation: Bool, polishing: Bool) async throws {
        ensureCalls.append(EnsureCall(dictation: dictation, polishing: polishing))
        ensureContinuation?.resume()
        ensureContinuation = nil
    }

    func stopAll() async { stopAllCallCount += 1 }
    func stopDictation() async { stopDictationCallCount += 1 }
    func stopPolishing() async { stopPolishingCallCount += 1 }
    func recentOutput(for spec: ManagedBackendSpec) -> [String] { [] }

    /// Suspends until `ensureReady` has been invoked at least once.
    func waitForEnsure() async {
        if !ensureCalls.isEmpty { return }
        await withCheckedContinuation { continuation in
            ensureContinuation = continuation
        }
    }
}

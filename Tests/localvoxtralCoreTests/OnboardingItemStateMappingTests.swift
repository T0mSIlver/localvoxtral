import Foundation
import XCTest
@testable import localvoxtralCore

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

import Foundation
import XCTest
@testable import localvoxtralCore

final class OnboardingItemStateMappingTests: XCTestCase {
    func testManagedStatusMapsToItemState() {
        let cases: [(name: String, status: ManagedBackendStatus, expected: OnboardingItemState)] = [
            ("stopped", .stopped, .pending),
            ("starting", .starting, .working(detail: "Loading the model…", fraction: nil)),
            ("ready", .ready, .ready),
            ("failed carries the summary", .failed(summary: "boom", detail: "trace"), .failed(summary: "boom")),
            (
                "preparingModel with a known total",
                .preparingModel(progress: ModelDownloadProgress(downloadedBytes: 64, totalBytes: 128)),
                .working(detail: "Downloading model 50%", fraction: 0.5)
            ),
            (
                "preparingModel without a known total",
                .preparingModel(progress: ModelDownloadProgress(downloadedBytes: 0, totalBytes: nil)),
                .working(detail: "Checking model...", fraction: nil)
            ),
        ]

        for (name, status, expected) in cases {
            XCTAssertEqual(OnboardingItemState(managedStatus: status), expected, name)
        }
    }
}

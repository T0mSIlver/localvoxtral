import Foundation
import XCTest
@testable import localvoxtral

@MainActor
final class RealtimeConnectionFailureTests: XCTestCase {

    // MARK: - classify(socketErrorMessage:)

    func testClassifyNilOrEmptyIsUnknown() {
        XCTAssertEqual(RealtimeConnectionFailureClassifier.classify(socketErrorMessage: nil), .unknown)
        XCTAssertEqual(RealtimeConnectionFailureClassifier.classify(socketErrorMessage: ""), .unknown)
        XCTAssertEqual(
            RealtimeConnectionFailureClassifier.classify(socketErrorMessage: "   "), .unknown
        )
    }

    func testClassifiesConnectionRefusedByNSURLErrorCode() {
        let message = "WebSocket failed: The operation couldn't be completed. [NSURLErrorDomain:-1004] url=ws://127.0.0.1:8000/v1/realtime"
        XCTAssertEqual(
            RealtimeConnectionFailureClassifier.classify(socketErrorMessage: message), .connectionRefused
        )
    }

    func testClassifiesHostUnreachableByNSURLErrorCode() {
        let message = "WebSocket failed: Could not find host. [NSURLErrorDomain:-1003] url=ws://missing-host:8000/realtime"
        XCTAssertEqual(
            RealtimeConnectionFailureClassifier.classify(socketErrorMessage: message), .hostUnreachable
        )
    }

    func testClassifiesTimedOutByNSURLErrorCode() {
        let message = "WebSocket failed: The request timed out. [NSURLErrorDomain:-1001] url=ws://10.0.0.5:8000/realtime"
        XCTAssertEqual(
            RealtimeConnectionFailureClassifier.classify(socketErrorMessage: message), .timedOut
        )
    }

    func testClassifiesNetworkLostByNSURLErrorCodes() {
        XCTAssertEqual(
            RealtimeConnectionFailureClassifier.classify(
                socketErrorMessage: "lost [NSURLErrorDomain:-1005] url=ws://x/realtime"
            ), .networkLost
        )
        XCTAssertEqual(
            RealtimeConnectionFailureClassifier.classify(
                socketErrorMessage: "offline [NSURLErrorDomain:-1009] url=ws://x/realtime"
            ), .networkLost
        )
    }

    func testClassifiesLocalizedPhrasesWhenErrorCodeAbsent() {
        XCTAssertEqual(
            RealtimeConnectionFailureClassifier.classify(socketErrorMessage: "connection refused"), .connectionRefused
        )
        XCTAssertEqual(
            RealtimeConnectionFailureClassifier.classify(socketErrorMessage: "Could not connect to the server."), .connectionRefused
        )
        XCTAssertEqual(
            RealtimeConnectionFailureClassifier.classify(socketErrorMessage: "Could not find host."), .hostUnreachable
        )
        XCTAssertEqual(
            RealtimeConnectionFailureClassifier.classify(socketErrorMessage: "The request timed out."), .timedOut
        )
        XCTAssertEqual(
            RealtimeConnectionFailureClassifier.classify(socketErrorMessage: "Internet connection appears to be offline."), .networkLost
        )
    }

    func testClassifiesUnknownForUnrecognizedMessages() {
        XCTAssertEqual(
            RealtimeConnectionFailureClassifier.classify(socketErrorMessage: "WebSocket closed (1011)."), .unknown
        )
    }

    // MARK: - describe(kind:endpointDescription:...)

    private let endpoint = "ws://127.0.0.1:8000/v1/realtime"

    func testDescribeConnectionRefusedNamesEndpoint() {
        let description = RealtimeConnectionFailureClassifier.describe(
            kind: .connectionRefused,
            endpointDescription: endpoint,
            rawError: "refused [NSURLErrorDomain:-1004]"
        )
        XCTAssertEqual(description.status, "Connection refused.")
        XCTAssertTrue(description.message.contains(endpoint), "message should name the endpoint")
        XCTAssertTrue(description.message.localizedCaseInsensitiveContains("refused"))
        XCTAssertEqual(description.technicalDetails, "refused [NSURLErrorDomain:-1004]")
    }

    func testDescribeHostUnreachableNamesEndpoint() {
        let description = RealtimeConnectionFailureClassifier.describe(
            kind: .hostUnreachable,
            endpointDescription: "ws://missing-host:8000/realtime",
            rawError: nil
        )
        XCTAssertEqual(description.status, "Host unreachable.")
        XCTAssertTrue(description.message.contains("ws://missing-host:8000/realtime"))
    }

    func testDescribeTimedOutKeepsStablePhraseAndNamesEndpoint() {
        let description = RealtimeConnectionFailureClassifier.describe(
            kind: .timedOut,
            endpointDescription: endpoint,
            timeoutSeconds: 1.0,
            rawError: nil
        )
        XCTAssertEqual(description.status, "Connection timed out.")
        // Stable phrase asserted by existing timeout regression test:
        XCTAssertTrue(description.message.contains("No connection response received in 1 seconds"))
        XCTAssertTrue(description.message.contains(endpoint))
    }

    func testDescribeInvalidEndpointDoesNotRequireEndpoint() {
        let description = RealtimeConnectionFailureClassifier.describe(
            kind: .invalidEndpoint,
            endpointDescription: "",
            rawError: nil
        )
        XCTAssertEqual(description.status, "Invalid endpoint URL.")
        XCTAssertTrue(description.message.contains("Settings"))
        XCTAssertNotNil(description.technicalDetails)
    }

    func testDescribeNetworkLostMatchesStatusTokenString() {
        let description = RealtimeConnectionFailureClassifier.describe(
            kind: .networkLost,
            endpointDescription: endpoint,
            rawError: nil
        )
        // Must equal StatusStrings.networkLostDictationStopped so the menu-bar /
        // popover status token mapping still recognizes it.
        XCTAssertEqual(description.status, "Network lost. Dictation stopped.")
        XCTAssertTrue(description.message.contains(endpoint))
    }

    func testDescribeUnknownNamesEndpoint() {
        let description = RealtimeConnectionFailureClassifier.describe(
            kind: .unknown,
            endpointDescription: endpoint,
            rawError: "some error"
        )
        XCTAssertEqual(description.status, "Connection failed.")
        XCTAssertTrue(description.message.contains(endpoint))
    }

    func testDescribeFallsBackToPlaceholderForEmptyEndpoint() {
        let description = RealtimeConnectionFailureClassifier.describe(
            kind: .connectionRefused,
            endpointDescription: "  ",
            rawError: nil
        )
        XCTAssertTrue(description.message.contains(RealtimeConnectionFailureClassifier.unknownEndpointDescription))
    }

    // MARK: - Divergence guard

    func testNetworkLostStatusMatchesStatusStringsConstant() {
        // Guards against the hardcoded classifier string drifting from
        // DictationViewModel.StatusStrings.networkLostDictationStopped.
        let description = RealtimeConnectionFailureClassifier.describe(
            kind: .networkLost,
            endpointDescription: endpoint,
            rawError: nil
        )
        XCTAssertEqual(description.status, DictationViewModel.StatusStrings.networkLostDictationStopped)
    }
}

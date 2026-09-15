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

    func testClassifiesEndpointRejectedByBadServerResponse() {
        let message = "WebSocket failed: The operation couldn't be completed. [NSURLErrorDomain:-1011] url=ws://127.0.0.1:8000/v1/realtimeaa"
        XCTAssertEqual(
            RealtimeConnectionFailureClassifier.classify(socketErrorMessage: message), .endpointRejected
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
            RealtimeConnectionFailureClassifier.classify(socketErrorMessage: "WebSocket upgrade failed with HTTP 404."), .endpointRejected
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

    // MARK: - Hosted-provider credential and quota rejections

    func testClassifiesUnauthorizedAheadOfTheBadServerResponseBucket() {
        // A hosted provider's 401 arrives as a bare NSURLErrorBadServerResponse;
        // only the status the client folds in tells it apart from a wrong path,
        // and "check the path" is the wrong advice for a rejected key.
        let message = "Mistral rejected the connection (HTTP 401): check the API key. "
            + "WebSocket failed: The operation couldn't be completed. [NSURLErrorDomain:-1011]"
        XCTAssertEqual(
            RealtimeConnectionFailureClassifier.classify(socketErrorMessage: message), .unauthorized
        )
    }

    func testClassifiesForbiddenAsUnauthorized() {
        let message = "Rejected the connection (HTTP 403). [NSURLErrorDomain:-1011]"
        XCTAssertEqual(
            RealtimeConnectionFailureClassifier.classify(socketErrorMessage: message), .unauthorized
        )
    }

    func testClassifiesRateLimitedAheadOfTheBadServerResponseBucket() {
        let message = "Rejected the connection (HTTP 429): rate limit reached; wait and retry. "
            + "[NSURLErrorDomain:-1011]"
        XCTAssertEqual(
            RealtimeConnectionFailureClassifier.classify(socketErrorMessage: message), .rateLimited
        )
    }

    func testClassifiesCredentialAndQuotaPhrasesWithoutAStatusCode() {
        XCTAssertEqual(
            RealtimeConnectionFailureClassifier.classify(socketErrorMessage: "Unauthorized"),
            .unauthorized
        )
        XCTAssertEqual(
            RealtimeConnectionFailureClassifier.classify(socketErrorMessage: "invalid api key"),
            .unauthorized
        )
        XCTAssertEqual(
            RealtimeConnectionFailureClassifier.classify(socketErrorMessage: "Too Many Requests"),
            .rateLimited
        )
    }

    func testUnrelatedHTTPStatusesKeepTheirExistingClassification() {
        // The new buckets must not swallow the path-rejection cases.
        XCTAssertEqual(
            RealtimeConnectionFailureClassifier.classify(
                socketErrorMessage: "WebSocket upgrade failed with HTTP 404."
            ),
            .endpointRejected
        )
        XCTAssertEqual(
            RealtimeConnectionFailureClassifier.classify(
                socketErrorMessage: "WebSocket failed: The request timed out. [NSURLErrorDomain:-1001]"
            ),
            .timedOut
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
        XCTAssertTrue(description.message.contains("No connection response received in 1 second"))
        XCTAssertFalse(description.message.contains("1 seconds"))
        XCTAssertTrue(description.message.contains(endpoint))
    }

    func testDescribeTimedOutPluralizesMultipleSeconds() {
        let description = RealtimeConnectionFailureClassifier.describe(
            kind: .timedOut,
            endpointDescription: endpoint,
            timeoutSeconds: 3.0,
            rawError: nil
        )
        XCTAssertTrue(description.message.contains("No connection response received in 3 seconds"))
    }

    func testDescribeEndpointRejectedNamesPathGuidance() {
        let description = RealtimeConnectionFailureClassifier.describe(
            kind: .endpointRejected,
            endpointDescription: endpoint,
            rawError: "bad server response [NSURLErrorDomain:-1011]"
        )

        XCTAssertEqual(description.status, "Endpoint path rejected.")
        XCTAssertTrue(description.message.contains(endpoint))
        XCTAssertTrue(description.message.localizedCaseInsensitiveContains("check the path"))
        XCTAssertEqual(description.technicalDetails, "bad server response [NSURLErrorDomain:-1011]")
    }

    func testDescribeTimedOutOmitsDuplicateTechnicalDetails() {
        let description = RealtimeConnectionFailureClassifier.describe(
            kind: .timedOut,
            endpointDescription: endpoint,
            timeoutSeconds: 1.0,
            rawError: "No connection response received in 1 seconds for endpoint \(endpoint)."
        )
        XCTAssertNil(description.technicalDetails)
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
        XCTAssertEqual(description.status, "Dictation stopped after the network disconnected.")
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

    func testDescribeOmitsTechnicalDetailsThatDuplicateMessageForAllKinds() {
        let cases: [(RealtimeConnectionFailureKind, TimeInterval?)] = [
            (.invalidEndpoint, nil),
            (.connectionRefused, nil),
            (.hostUnreachable, nil),
            (.timedOut, 2.0),
            (.endpointRejected, nil),
            (.networkLost, nil),
            (.unknown, nil),
        ]

        for (kind, timeoutSeconds) in cases {
            let baseline = RealtimeConnectionFailureClassifier.describe(
                kind: kind,
                endpointDescription: endpoint,
                timeoutSeconds: timeoutSeconds,
                rawError: nil
            )
            let withDuplicateDetails = RealtimeConnectionFailureClassifier.describe(
                kind: kind,
                endpointDescription: endpoint,
                timeoutSeconds: timeoutSeconds,
                rawError: baseline.message
            )
            XCTAssertNil(
                withDuplicateDetails.technicalDetails,
                "\(kind) should omit details that repeat the user-facing message"
            )
        }
    }

    func testDescribeUnauthorizedPointsAtTheKeyInSettings() {
        let description = RealtimeConnectionFailureClassifier.describe(
            kind: .unauthorized,
            endpointDescription: endpoint,
            rawError: "HTTP 401 [NSURLErrorDomain:-1011]"
        )
        XCTAssertEqual(description.status, "API key rejected.")
        XCTAssertTrue(description.message.contains(endpoint), "message should name the endpoint")
        XCTAssertTrue(description.message.contains("Settings"))
        XCTAssertFalse(
            description.message.localizedCaseInsensitiveContains("check the path"),
            "A rejected key must not be reported as a wrong endpoint path"
        )
        XCTAssertEqual(description.technicalDetails, "HTTP 401 [NSURLErrorDomain:-1011]")
    }

    func testDescribeRateLimitedIsProviderNeutralAndNamesEndpoint() {
        let description = RealtimeConnectionFailureClassifier.describe(
            kind: .rateLimited,
            endpointDescription: endpoint,
            rawError: nil
        )
        XCTAssertEqual(description.status, "Rate limited.")
        XCTAssertTrue(description.message.contains(endpoint))
        XCTAssertFalse(description.message.localizedCaseInsensitiveContains("mistral"))
    }

    func testDescribeOmitsDuplicateTechnicalDetailsForTheNewKinds() {
        for kind in [RealtimeConnectionFailureKind.unauthorized, .rateLimited] {
            let baseline = RealtimeConnectionFailureClassifier.describe(
                kind: kind, endpointDescription: endpoint, rawError: nil
            )
            let duplicated = RealtimeConnectionFailureClassifier.describe(
                kind: kind, endpointDescription: endpoint, rawError: baseline.message
            )
            XCTAssertNil(
                duplicated.technicalDetails,
                "\(kind) should omit details that repeat the user-facing message"
            )
        }
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

    // MARK: - Missing credentials

    func testClientRefusalForAMissingKeyIsNotAnEndpointProblem() {
        // The Mistral client throws before it opens a socket when no key is
        // configured. Classifying that as `.unknown` would print "check the
        // endpoint in Settings" — the wrong field entirely.
        let kind = RealtimeConnectionFailureClassifier.classify(
            socketErrorMessage:
                "Mistral API key is missing. Add your Mistral API key in Settings → Engines."
        )
        XCTAssertEqual(kind, .credentialsMissing)
    }

    func testCredentialsMissingSurfacesTheClientsOwnSentence() {
        let clientMessage =
            "Mistral API key is missing. Add your Mistral API key in Settings → Engines."
        let description = RealtimeConnectionFailureClassifier.describe(
            kind: .credentialsMissing,
            endpointDescription: endpoint,
            rawError: clientMessage
        )

        XCTAssertEqual(description.status, "API key missing.")
        XCTAssertEqual(description.message, clientMessage)
        XCTAssertNil(
            description.technicalDetails,
            "the details would only repeat the message"
        )
    }

    func testCredentialsMissingFallsBackToEndpointNamingCopy() {
        let description = RealtimeConnectionFailureClassifier.describe(
            kind: .credentialsMissing,
            endpointDescription: endpoint,
            rawError: nil
        )

        XCTAssertEqual(description.status, "API key missing.")
        XCTAssertTrue(description.message.contains(endpoint))
    }

    func testAServerSideRejectionIsStillUnauthorizedNotCredentialsMissing() {
        // A key that IS set and got refused is a different problem with a
        // different fix; the two must not collapse into one.
        let kind = RealtimeConnectionFailureClassifier.classify(
            socketErrorMessage:
                "Mistral rejected the connection (HTTP 401): check the API key. WebSocket failed"
        )
        XCTAssertEqual(kind, .unauthorized)
    }

}

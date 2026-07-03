import Foundation

/// User-facing classification of a realtime backend connection failure.
///
/// The realtime backend can fail to connect in several distinct ways that each
/// suggest a different user action (start the server, fix the port, fix DNS,
/// reconnect to the network, fix the URL scheme). This enum captures the
/// classification; `RealtimeConnectionFailureClassifier` maps it (plus the
/// resolved endpoint) to the copy surfaced in the popover and failure alert.
enum RealtimeConnectionFailureKind: Sendable, Equatable {
    /// The configured endpoint could not be resolved to a valid ws/wss URL.
    case invalidEndpoint
    /// The host was reached but actively refused the connection (server not
    /// running, wrong port, firewall refused).
    case connectionRefused
    /// The host itself could not be found or reached (DNS failure, host down,
    /// unreachable network).
    case hostUnreachable
    /// The connection attempt did not complete within the connect timeout.
    case timedOut
    /// The host/port accepted a connection but rejected the websocket upgrade,
    /// usually because the configured path is not a realtime websocket route.
    case endpointRejected
    /// The system reported the network path was lost while opening the socket.
    case networkLost
    /// Any other failure (unexpected socket close, TLS error, etc.).
    case unknown
}

/// Copy produced for a connection failure, ready to surface to the user.
struct RealtimeConnectionFailureDescription: Sendable, Equatable {
    /// Short status line (popover "Status:" + menu-bar context).
    let status: String
    /// Primary user-facing message. Always names the resolved endpoint when one
    /// is known, so a wrong port is instantly visible.
    let message: String
    /// Raw technical/system error preserved for logs and the Console affordance.
    let technicalDetails: String?
}

/// Pure mapping from a classified failure (+ endpoint) to user-facing copy.
///
/// Kept free of app state on purpose so the message construction is unit-testable
/// without a view model or live socket.
enum RealtimeConnectionFailureClassifier {
    /// Placeholder used when the configured endpoint could not be resolved.
    static let unknownEndpointDescription = "<unresolved endpoint>"

    /// Describes a connection failure for the user.
    /// - Parameters:
    ///   - kind: Classified failure kind.
    ///   - endpointDescription: Sanitized resolved endpoint string (scheme + host
    ///     + port + path, no credentials/query). Pass `unknownEndpointDescription`
    ///     when no endpoint could be resolved.
    ///   - timeoutSeconds: Connect timeout, only meaningful for `.timedOut`.
    ///   - rawError: Raw underlying error string (socket error / thrown error),
    ///     surfaced as technical details. May be nil.
    static func describe(
        kind: RealtimeConnectionFailureKind,
        endpointDescription: String,
        timeoutSeconds: TimeInterval? = nil,
        rawError: String?
    ) -> RealtimeConnectionFailureDescription {
        let endpoint = endpointDescription.trimmed.isEmpty
            ? Self.unknownEndpointDescription
            : endpointDescription

        switch kind {
        case .invalidEndpoint:
            let message = "Set a valid `ws://` or `wss://` endpoint for the selected backend in Settings."
            return RealtimeConnectionFailureDescription(
                status: "Invalid endpoint URL.",
                message: message,
                technicalDetails: Self.technicalDetails(
                    rawError,
                    fallback: "Settings value could not be normalized to a websocket endpoint URL.",
                    message: message
                )
            )

        case .connectionRefused:
            let message = "Connection refused at \(endpoint). Make sure the backend is running and the port is correct."
            return RealtimeConnectionFailureDescription(
                status: "Connection refused.",
                message: message,
                technicalDetails: Self.technicalDetails(rawError, message: message)
            )

        case .hostUnreachable:
            let message = "Could not reach the backend host at \(endpoint). The host could not be found or the network can't reach it."
            return RealtimeConnectionFailureDescription(
                status: "Host unreachable.",
                message: message,
                technicalDetails: Self.technicalDetails(rawError, message: message)
            )

        case .timedOut:
            let seconds = max(1, Int((timeoutSeconds ?? 0).rounded()))
            let unit = seconds == 1 ? "second" : "seconds"
            // The leading phrase is intentionally stable: existing regression
            // tests assert on "No connection response received in <n> second(s)".
            let message = "No connection response received in \(seconds) \(unit) at \(endpoint). The backend may be slow to start or unreachable."
            return RealtimeConnectionFailureDescription(
                status: "Connection timed out.",
                message: message,
                technicalDetails: nil
            )

        case .endpointRejected:
            let message = "Endpoint path rejected by server at \(endpoint). Check the path."
            return RealtimeConnectionFailureDescription(
                status: "Endpoint path rejected.",
                message: message,
                technicalDetails: Self.technicalDetails(rawError, message: message)
            )

        case .networkLost:
            // Matches DictationViewModel.StatusStrings.networkLostDictationStopped
            // (kept verbatim so StatusToken mapping continues to recognize it).
            let message = "Network connection was lost while connecting to \(endpoint). Reconnect to a network and try again."
            return RealtimeConnectionFailureDescription(
                status: "Network lost. Dictation stopped.",
                message: message,
                technicalDetails: Self.technicalDetails(
                    rawError,
                    fallback: "Network path changed to unavailable while opening websocket.",
                    message: message
                )
            )

        case .unknown:
            let message = "Could not connect to the realtime backend at \(endpoint). Check the endpoint in Settings and try again."
            return RealtimeConnectionFailureDescription(
                status: "Connection failed.",
                message: message,
                technicalDetails: Self.technicalDetails(rawError, message: message)
            )
        }
    }

    /// Classifies a raw socket/system error message string into a failure kind.
    ///
    /// `BaseRealtimeWebSocketClient.describeSocketError` formats errors as
    /// `"<prefix> <localizedDescription> [<domain>:<code>] url=<url>"`, so the
    /// NSError code is the most reliable signal. Localized-text fallbacks cover
    /// transports that omit the structured code.
    static func classify(socketErrorMessage message: String?) -> RealtimeConnectionFailureKind {
        guard let message, !message.trimmed.isEmpty else {
            return .unknown
        }

        if matches(any: [
            ":-1001", "NSURLErrorTimedOut", "timed out", "timed out)"
        ], in: message) {
            return .timedOut
        }

        if matches(any: [
            ":-1011", "NSURLErrorBadServerResponse", "bad server response",
            "not a websocket", "not a web socket", "websocket upgrade",
            "web socket upgrade", "expected http 101", "http 400",
            "http 404", "http 426", "status code 400", "status code 404",
            "status code 426"
        ], in: message) {
            return .endpointRejected
        }

        if matches(any: [
            ":-1003", "NSURLErrorCannotFindHost", "could not find host",
            "cannot find host", "nodename nor servname", "name resolution"
        ], in: message) {
            return .hostUnreachable
        }

        if matches(any: [
            ":-1004", "NSURLErrorCannotConnectToHost", "connection refused",
            "could not connect to the server", "cannot connect to host"
        ], in: message) {
            return .connectionRefused
        }

        if matches(any: [
            ":-1005", ":-1009", "NSURLErrorNetworkConnectionLost",
            "NSURLErrorNotConnectedToInternet", "network connection was lost",
            "not connected to the internet", "internet connection appears to be offline"
        ], in: message) {
            return .networkLost
        }

        return .unknown
    }

    private static func matches(any candidates: [String], in message: String) -> Bool {
        let lowercased = message.lowercased()
        return candidates.contains { candidate in
            // Match the candidate verbatim (preserves NSError code casing/symbols)
            // or case-insensitively for natural-language phrases.
            message.contains(candidate) || lowercased.contains(candidate.lowercased())
        }
    }

    private static func technicalDetails(
        _ rawError: String?,
        fallback: String? = nil,
        message: String
    ) -> String? {
        if let rawError {
            let trimmed = rawError.trimmed
            guard !trimmed.isEmpty else { return nil }
            guard isDistinctTechnicalDetail(trimmed, from: message) else {
                return nil
            }
            return trimmed
        }
        return fallback
    }

    private static func isDistinctTechnicalDetail(_ details: String, from message: String) -> Bool {
        let normalizedDetails = normalizedForDetailComparison(details)
        let normalizedMessage = normalizedForDetailComparison(message)
        guard !normalizedDetails.isEmpty else { return false }
        if normalizedDetails == normalizedMessage {
            return false
        }
        if normalizedMessage.contains(normalizedDetails) {
            return false
        }
        return true
    }

    private static func normalizedForDetailComparison(_ value: String) -> String {
        let lowercased = value.lowercased()
        var words: [String] = []
        var current = ""

        for scalar in lowercased.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                words.append(current)
                current.removeAll(keepingCapacity: true)
            }
        }

        if !current.isEmpty {
            words.append(current)
        }

        return words.joined(separator: " ")
    }
}

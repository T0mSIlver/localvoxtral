import Foundation

/// What a polish reply means for the commit: the placeholder-integrity check
/// on the model's text, and the status line, message and technical details a
/// failed request earns. Pure; the strings are what the goldens pin.
enum PolishOutcomeClassifier {
    struct Failure: Equatable {
        let title: String
        let message: String
        let technicalDetails: String?
    }

    /// The text the overlay commits for a reply, given the grounded text the
    /// request carried.
    static func committedText(
        polished: String,
        groundedWorkingText: String,
        clipboardPayload: String?
    ) -> String {
        var committedText = polished
        if clipboardPayload != nil {
            let expectedPlaceholders =
                ClipboardPayloadMacro.standalonePlaceholderCount(
                    in: groundedWorkingText
                )
            let actualPlaceholders =
                ClipboardPayloadMacro.standalonePlaceholderCount(
                    in: committedText
                )
            if actualPlaceholders != expectedPlaceholders {
                committedText = groundedWorkingText
                Log.polishing.warning(
                    "Clipboard payload macro: polish changed placeholder count (\(expectedPlaceholders, privacy: .public) -> \(actualPlaceholders, privacy: .public)); polish discarded"
                )
            }
        }
        return committedText
    }

    /// Nil for the errors the commit path reports only in the log.
    static func failure(for error: Error, endpointURL: URL) -> Failure? {
        switch error as? LLMPolishingError {
        case .some(.networkError(let details)):
            return Failure(
                title: "LLM Polishing Connection Failed",
                message: "Unable to connect to the configured LLM polishing endpoint.",
                // Name the endpoint the request was ACTUALLY
                // sent to — in managed mode the external-URL
                // setting (its untouched placeholder default,
                // typically :8080) was never used, and naming
                // it sent field debugging to the wrong
                // process (2026-07-11).
                technicalDetails: connectionTechnicalDetails(
                    details,
                    endpointURL: endpointURL
                )
            )
        case .some(.requestFailed(let statusCode, let body)):
            // A hosted provider answers a bad key, an
            // unaccepted body field or an exhausted quota
            // with an HTTP status and a JSON error body.
            // The connection was fine, so "unable to
            // connect" would send debugging the wrong way;
            // surface the status and the provider's own
            // one-line reason instead. The raw body stays
            // in the log line below — never in
            // `lastError`, which Settings renders as the
            // one-line failure summary.
            let summary = llmPolishingRejectionMessage(
                statusCode: statusCode,
                body: body
            )
            return Failure(
                title: "LLM Polishing Request Rejected",
                message: summary,
                technicalDetails: connectionTechnicalDetails(
                    summary,
                    endpointURL: endpointURL
                )
            )
        case .some(.timedOut(let seconds)):
            // The endpoint was reachable and simply slow — a long
            // transcript or a cold prefix cache. "Unable to connect"
            // would send debugging after a network that was fine (#314).
            let summary = llmPolishingTimeoutMessage(seconds: seconds)
            return Failure(
                title: "LLM Polishing Timed Out",
                message: summary,
                technicalDetails: connectionTechnicalDetails(
                    summary,
                    endpointURL: endpointURL
                )
            )
        case .some(.emptyInput), .some(.invalidResponse), .none:
            return nil
        }
    }

    /// ONE LINE for a polish request the endpoint answered with a non-2xx
    /// status — the hosted-provider failure mode (a wrong API key, a body
    /// field the provider does not accept, an exhausted quota). It names the
    /// status, what that status generally means, and the provider's own
    /// one-sentence reason when the body carries one. A live Mistral probe
    /// (2026-09-15) answered an unsupported `top_k` with HTTP 400 and
    /// `{"object":"error","message":"top_k sampling is not enabled for this
    /// model", …}`: that `message` is the whole diagnosis, and the status
    /// alone would say only "something in the body".
    ///
    /// The RAW body never appears here — this text reaches the alert and (via
    /// the technical details) `lastError`, which Settings renders as the
    /// one-line failure summary. The body goes to the log.
    /// One line for a polish request that outlived its timeout. The overlay commits the
    /// unpolished transcript on any polish failure, so nothing dictated is lost.
    static func llmPolishingTimeoutMessage(seconds: TimeInterval) -> String {
        "Polishing took longer than \(Int(seconds.rounded())) seconds, so the transcript was not polished."
    }

    static func llmPolishingRejectionMessage(statusCode: Int, body: String) -> String {
        let reason: String
        switch statusCode {
        case 401, 403:
            reason = "rejected the API key"
        case 404:
            reason = "has no such model or path"
        case 422:
            reason = "rejected the request body"
        case 429:
            reason = "is rate limiting or out of quota"
        case 500...599:
            reason = "failed to answer"
        default:
            reason = "rejected the request"
        }
        let head = "The LLM polishing endpoint \(reason) (HTTP \(statusCode))"
        guard let detail = providerErrorMessage(inBody: body) else {
            return head + "."
        }
        return "\(head): \(detail)"
    }

    /// The provider's own error sentence, pulled out of a JSON error body and
    /// flattened to one bounded line. Mistral answers
    /// `{"object":"error","message":"…"}`; OpenAI-shaped servers answer
    /// `{"error":{"message":"…"}}`; the realtime surface can nest a `detail`.
    /// Anything else (HTML, a stack trace, an empty body) yields nil and the
    /// caller falls back to the status alone, rather than pasting bytes into
    /// the UI.
    static func providerErrorMessage(inBody body: String) -> String? {
        // One line in a popover-sized surface: a provider that answers with a
        // paragraph gets truncated rather than widening the alert.
        let characterLimit = 160

        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let nested = json["error"] as? [String: Any]
        let candidate =
            (json["message"] as? String)
            ?? ((json["message"] as? [String: Any])?["detail"] as? String)
            ?? (nested?["message"] as? String)
            ?? ((nested?["message"] as? [String: Any])?["detail"] as? String)
            ?? (nested?["detail"] as? String)
            ?? (json["error"] as? String)
            ?? (json["detail"] as? String)

        guard let candidate else { return nil }
        let flattened = candidate
            .replacingOccurrences(of: "[\r\n\t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: " +", with: " ", options: .regularExpression)
            .trimmed
        guard !flattened.isEmpty else { return nil }

        if flattened.count > characterLimit {
            return String(flattened.prefix(characterLimit)).trimmed + "…"
        }
        return flattened.hasSuffix(".") ? flattened : flattened + "."
    }

    /// Failure details for the alert/`lastError`, naming `endpointURL` — the
    /// endpoint the failing request was actually sent to, captured from the
    /// request's own configuration (Settings may have changed since).
    static func connectionTechnicalDetails(
        _ details: String,
        endpointURL: URL
    ) -> String {
        let endpoint = URLLogSanitizer.sanitized(endpointURL)
        let normalizedDetails = details.trimmed
        if normalizedDetails.isEmpty {
            return "Unable to connect to endpoint \(endpoint)."
        }
        return "\(normalizedDetails) [endpoint: \(endpoint)]"
    }
}

/// Strips credentials, query, and fragment from a URL for safe logging.
enum URLLogSanitizer {
    static func sanitized(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string ?? url.absoluteString
    }
}

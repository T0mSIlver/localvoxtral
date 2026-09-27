import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Jev, Typesafe's classifier (released 2026-09-15), asked one `choice`
/// question per capture: which project is this about. It returns a
/// probability per option, never generated text.
///
/// Two hosts serve it with the same question shape:
/// - TypeSafe: `POST https://api.typesafe.ai/v1/systemone`, model
///   `jev-latest` (docs.typesafe.ai/primitives/choice). The body must name
///   the model; without it the API answers 422.
/// - Vercel AI Gateway: `POST https://ai-gateway.vercel.sh/v1/evaluate`,
///   model `typesafe-ai/jev` (vercel.com/changelog, "AI Gateway now supports
///   TypeSafe clients and an HTTP API for Jev").
///
/// A choice answer: `{"model": …, "answers": {"<question>": {"type":
/// "choice", "choice": …, "confidence": …, "probabilities": {option: p}}}}`.
/// Limits: 255 options per choice, 32k tokens for the state plus the longest
/// question.
package enum Jev {
    package enum Host: String, Codable, Equatable, Sendable, CaseIterable {
        case typesafe
        case vercelGateway

        package var endpoint: URL {
            switch self {
            case .typesafe: URL(string: "https://api.typesafe.ai/v1/systemone")!
            case .vercelGateway: URL(string: "https://ai-gateway.vercel.sh/v1/evaluate")!
            }
        }

        package var model: String {
            switch self {
            case .typesafe: "jev-latest"
            case .vercelGateway: "typesafe-ai/jev"
            }
        }
    }

    package static let questionID = "project"
    /// Measured on the replay (2026-09-26): naming the speaker a developer
    /// and asking for the catch-all "unless the note clearly concerns one
    /// project" took wrong-project routes on the owner's joined list from 2
    /// to 0 at the 0.9 bar, with no right one lost.
    package static let instructions =
        "A developer dictated this note. Which of their software projects is it about? Choose inbox unless the note clearly concerns one project."
    package static let maxOptions = 255
    /// Jev answers in well under a second (liteLLM measured a 127 ms
    /// median). A capture waits on this, so a slow answer falls back.
    package static let requestTimeout: TimeInterval = 5

    package static func requestBody(model: String, capture: String, options: [QuickCaptureOption]) -> Data {
        var criteria: [String: String] = [:]
        for option in options.prefix(maxOptions) {
            criteria[option.id] = option.description
        }
        let body: [String: Any] = [
            "model": model,
            "state": capture,
            "questions": [
                questionID: [
                    "type": "choice",
                    "instructions": instructions,
                    "criteria": criteria,
                ],
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
    }

    package static func request(
        host: Host,
        apiKey: String,
        capture: String,
        options: [QuickCaptureOption]
    ) -> URLRequest {
        var request = URLRequest(url: host.endpoint, timeoutInterval: requestTimeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = requestBody(model: host.model, capture: capture, options: options)
        return request
    }

    package enum Failure: Error, Equatable, Sendable {
        /// A non-2xx answer, with the API's message when it gave one.
        case http(status: Int, message: String?)
        case malformedResponse
    }

    /// The probability per option id of a 2xx answer.
    package static func probabilities(status: Int, body: Data) throws -> [String: Double] {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        guard (200..<300).contains(status) else {
            throw Failure.http(status: status, message: errorMessage(in: json))
        }
        guard let answers = (json?["answers"] ?? (json?["result"] as? [String: Any])?["answers"]) as? [String: Any],
              let answer = answers[questionID] as? [String: Any]
        else { throw Failure.malformedResponse }
        if let probabilities = answer["probabilities"] as? [String: Any] {
            let parsed = probabilities.compactMapValues { ($0 as? NSNumber)?.doubleValue }
            if !parsed.isEmpty { return parsed }
        }
        // A choice without its distribution still names the winner.
        guard let choice = answer["choice"] as? String else { throw Failure.malformedResponse }
        return [choice: (answer["confidence"] as? NSNumber)?.doubleValue ?? 1]
    }

    /// `{"detail": "…"}`, `{"detail": [{"msg": …}]}` (422), `{"error": {"message": …}}`
    /// or `{"message": …}`.
    private static func errorMessage(in json: [String: Any]?) -> String? {
        guard let json else { return nil }
        if let detail = json["detail"] as? String { return detail }
        if let details = json["detail"] as? [[String: Any]] {
            return details.compactMap { $0["msg"] as? String }.joined(separator: "; ")
        }
        if let error = json["error"] as? [String: Any], let message = error["message"] as? String { return message }
        if let error = json["error"] as? String { return error }
        return json["message"] as? String
    }
}

extension Jev {
    /// Waits before the second, third and fourth attempt. The gateway
    /// answered 429 "high demand" to most calls on the evening of the replay
    /// (2026-09-26), and most succeeded within a few retries. A capture routes
    /// in the background, so seven seconds of waiting costs the user nothing,
    /// and the chat model takes over after the last.
    package static let retryDelays: [TimeInterval] = [1, 2, 4]

    /// Runs `attempt`, again after each delay while the answer is a 429 or a
    /// 503. Any other failure, and the last one, is thrown.
    package static func withRetries<Value>(
        delays: [TimeInterval] = retryDelays,
        sleep: (TimeInterval) async throws -> Void,
        _ attempt: () async throws -> Value
    ) async throws -> Value {
        var remaining = delays[...]
        while true {
            do {
                return try await attempt()
            } catch Failure.http(let status, _) where (status == 429 || status == 503) && !remaining.isEmpty {
                let delay = remaining.removeFirst()
                Log.backends.info(
                    "Quick capture: Jev answered \(status, privacy: .public), retrying in \(delay, privacy: .public) s"
                )
                try await sleep(delay)
            }
        }
    }
}

package struct JevClassifier: QuickCaptureClassifying {
    private let host: Jev.Host
    private let apiKey: String
    private let session: URLSession
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let usageRecorder: (any UsageRecording)?
    private let now: @Sendable () -> Date

    package init(
        host: Jev.Host,
        apiKey: String,
        session: URLSession = .shared,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
        usageRecorder: (any UsageRecording)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.host = host
        self.apiKey = apiKey
        self.session = session
        self.sleep = sleep
        self.usageRecorder = usageRecorder
        self.now = now
    }

    package var kind: QuickCaptureRoute.Classifier { .jev }

    package func classify(capture: String, options: [QuickCaptureOption]) async throws -> [String: Double] {
        let request = Jev.request(host: host, apiKey: apiKey, capture: capture, options: options)
        return try await Jev.withRetries(sleep: sleep) {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            // Jev reports no token counts: the ledger gets the call, unpriced.
            // A 429 or 503 did no work and is not counted.
            if (200..<300).contains(status) {
                usageRecorder?.record(UsageEntry(
                    date: now(), feature: .quickCaptureRouting, backend: .jev, model: host.model))
            }
            return try Jev.probabilities(status: status, body: data)
        }
    }
}

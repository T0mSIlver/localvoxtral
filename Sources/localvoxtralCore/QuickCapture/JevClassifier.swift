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
    package static let instructions =
        "Someone spoke this idea, task or note aloud while working. Which of their projects is it about?"
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

package struct JevClassifier: QuickCaptureClassifying {
    private let host: Jev.Host
    private let apiKey: String
    private let session: URLSession

    package init(host: Jev.Host, apiKey: String, session: URLSession = .shared) {
        self.host = host
        self.apiKey = apiKey
        self.session = session
    }

    package var kind: QuickCaptureRoute.Classifier { .jev }

    package func classify(capture: String, options: [QuickCaptureOption]) async throws -> [String: Double] {
        let request = Jev.request(host: host, apiKey: apiKey, capture: capture, options: options)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return try Jev.probabilities(status: status, body: data)
    }
}

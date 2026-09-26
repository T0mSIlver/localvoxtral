import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The fallback when Jev is off, has no key, or fails: the polishing model
/// asked to route instead of polish. One OpenAI-compatible
/// `chat/completions` call answering `{"project": <id>, "confidence": 0–1}`.
/// A chat model has no calibrated distribution, so its own confidence
/// stands in for Jev's probability, and the same bars apply.
package enum QuickCaptureChatRouting {
    package static let requestTimeout: TimeInterval = 20
    /// Room for a reasoning model's thinking before the JSON.
    package static let maxTokens = 1024

    package static let systemPrompt = """
        You route a spoken note to one of the speaker's software projects. \
        Read the note and the project descriptions, then pick the one project \
        the note is about. Pick "\(QuickCaptureRouting.catchAllID)" when it fits \
        none of them, when two fit equally, or when you would be guessing. \
        Reply with JSON only: {"project": "<id>", "confidence": <0 to 1>}.
        """

    package static func userMessage(capture: String, options: [QuickCaptureOption]) -> String {
        let list = options.map { "- \($0.id): \($0.description)" }.joined(separator: "\n")
        return "Projects:\n\(list)\n\nNote:\n\(capture)"
    }

    /// - Parameter extraBody: fields the polishing configuration adds to
    ///   every request (a thinking switch, a reasoning effort), merged last.
    package static func requestBody(
        model: String,
        capture: String,
        options: [QuickCaptureOption],
        extraBody: [String: any Sendable] = [:]
    ) -> Data {
        var body: [String: Any] = [
            "model": model,
            "temperature": 0,
            "max_tokens": maxTokens,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userMessage(capture: capture, options: options)],
            ],
        ]
        for (key, value) in extraBody { body[key] = value }
        return (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
    }

    package enum Failure: Error, Equatable, Sendable {
        case http(status: Int)
        case malformedResponse
        /// The model named an id that is not an option.
        case unknownOption
    }

    package static func probabilities(
        status: Int,
        body: Data,
        options: [QuickCaptureOption]
    ) throws -> [String: Double] {
        guard (200..<300).contains(status) else { throw Failure.http(status: status) }
        guard let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String,
              let answer = jsonObject(in: content),
              let id = answer["project"] as? String
        else { throw Failure.malformedResponse }
        guard options.contains(where: { $0.id == id }) else { throw Failure.unknownOption }
        let confidence = (answer["confidence"] as? NSNumber)?.doubleValue ?? 1
        return [id: min(max(confidence, 0), 1)]
    }

    /// The last `{…}` in the reply: bare, fenced, or after a reasoning
    /// model's `<think>` block.
    static func jsonObject(in text: String) -> [String: Any]? {
        var body = text
        if let thinkEnd = body.range(of: "</think>", options: .backwards) {
            body = String(body[thinkEnd.upperBound...])
        }
        guard let open = body.firstIndex(of: "{"), let close = body.lastIndex(of: "}"), open < close,
              let data = String(body[open...close]).data(using: .utf8)
        else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

package struct QuickCaptureChatClassifier: QuickCaptureClassifying {
    private let endpoint: URL
    private let apiKey: String
    private let model: String
    private let extraBody: [String: any Sendable]
    private let session: URLSession

    /// - Parameter endpoint: the full `chat/completions` URL.
    package init(
        endpoint: URL,
        apiKey: String,
        model: String,
        extraBody: [String: any Sendable] = [:],
        session: URLSession = .shared
    ) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.model = model
        self.extraBody = extraBody
        self.session = session
    }

    package var kind: QuickCaptureRoute.Classifier { .chatModel }

    package func classify(capture: String, options: [QuickCaptureOption]) async throws -> [String: Double] {
        var request = URLRequest(url: endpoint, timeoutInterval: QuickCaptureChatRouting.requestTimeout)
        request.httpMethod = "POST"
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = QuickCaptureChatRouting.requestBody(
            model: model, capture: capture, options: options, extraBody: extraBody
        )
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return try QuickCaptureChatRouting.probabilities(status: status, body: data, options: options)
    }
}

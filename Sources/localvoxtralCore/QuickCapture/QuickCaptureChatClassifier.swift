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
    /// Room for a reasoning model's thinking before the JSON; a ceiling,
    /// so a model that does not think spends nothing extra.
    package static let maxTokens = 4096

    package static let systemPrompt = """
        You route a spoken note to one of the speaker's software projects. \
        Read the note and the project descriptions, then pick the one project \
        the note is about. Pick "\(QuickCaptureRouting.catchAllID)" when it fits \
        none of them, when two fit equally, or when you would be guessing. \
        Reply with JSON only: {"project": "<id>", "confidence": <0 to 1>}. \
        Confidence: 0.95 when the note names the project or can only be about it; \
        0.5 or less when you are guessing.
        """

    /// Added to `systemPrompt` only when open captures are options (#965),
    /// so a request with none is what it was before.
    package static let followUpInstruction = """
        Some options are earlier notes the speaker made in the last hour and \
        has not filed. When this note continues one of them (a detail, a \
        correction or a second thought about the same thing), pick that \
        earlier note, not its project. A new idea for the same project picks \
        the project.
        """

    package static func systemPrompt(for options: [QuickCaptureOption]) -> String {
        options.contains { $0.captureID != nil } ? systemPrompt + " " + followUpInstruction : systemPrompt
    }

    package static func userMessage(capture: String, options: [QuickCaptureOption]) -> String {
        let list = options.filter { $0.captureID == nil }.map { "- \($0.id): \($0.description)" }.joined(separator: "\n")
        let earlier = options.filter { $0.captureID != nil }.map { "- \($0.id): \($0.description)" }
        let notes = earlier.isEmpty ? "" : "\n\nEarlier notes:\n" + earlier.joined(separator: "\n")
        return "Projects:\n\(list)\(notes)\n\nNote:\n\(capture)"
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
                ["role": "system", "content": systemPrompt(for: options)],
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
              let content = text(ofContent: message["content"]),
              let answer = jsonObject(in: content),
              let id = answer["project"] as? String
        else { throw Failure.malformedResponse }
        guard options.contains(where: { $0.id == id }) else { throw Failure.unknownOption }
        let confidence = (answer["confidence"] as? NSNumber)?.doubleValue ?? 1
        return [id: min(max(confidence, 0), 1)]
    }

    /// A plain string on OpenAI-compatible servers. A reasoning model on
    /// Mistral answers a list of chunks instead, `{"type": "thinking"}` for
    /// the trace and `{"type": "text"}` for the answer; only the text counts
    /// (the same reading as `LLMPolishingService.assistantText`).
    static func text(ofContent content: Any?) -> String? {
        if let string = content as? String { return string }
        guard let chunks = content as? [[String: Any]] else { return nil }
        let text = chunks
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        return text.isEmpty ? nil : text
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
    private let usageBackend: UsageEntry.Backend
    private let usageRecorder: (any UsageRecording)?
    private let now: @Sendable () -> Date

    /// - Parameter endpoint: the full `chat/completions` URL.
    /// - Parameter usageBackend: who answers, for the usage ledger: the
    ///   polishing backend this classifier borrows.
    package init(
        endpoint: URL,
        apiKey: String,
        model: String,
        extraBody: [String: any Sendable] = [:],
        session: URLSession = SameOriginHTTP.shared,
        usageBackend: UsageEntry.Backend = .userServer,
        usageRecorder: (any UsageRecording)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.model = model
        self.extraBody = extraBody
        self.session = session
        self.usageBackend = usageBackend
        self.usageRecorder = usageRecorder
        self.now = now
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
        // A 2xx is billed whether or not its answer is usable, so it is
        // recorded before the answer is judged.
        if (200..<300).contains(status), let usageRecorder {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            usageRecorder.record(UsageEntry.chat(
                date: now(),
                feature: .quickCaptureRouting,
                backend: usageBackend,
                requestedModel: model,
                usage: json.flatMap(LLMTokenUsage.init(responseObject:))
            ))
        }
        return try QuickCaptureChatRouting.probabilities(status: status, body: data, options: options)
    }
}

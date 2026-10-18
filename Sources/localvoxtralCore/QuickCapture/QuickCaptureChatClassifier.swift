import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The fallback when Jev is off, has no key, or fails: the polishing model
/// asked to route instead of polish. One request in the polishing server's
/// dialect (`PolishWire`) answering `{"project": <id>, "confidence": 0–1}`.
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

    package static func wireRequest(capture: String, options: [QuickCaptureOption]) -> PolishWireRequest {
        PolishWireRequest(
            systemPrompt: systemPrompt(for: options),
            userPrompts: [userMessage(capture: capture, options: options)],
            maxTokens: maxTokens,
            timeout: requestTimeout,
            purpose: .quickCapture
        )
    }

    /// A pick with a missing or quoted confidence: the prompt's guess,
    /// under the bars, so it can only be the router's suggestion.
    package static let unstatedConfidence = 0.5

    package enum Failure: Error, Equatable, Sendable {
        case http(status: Int)
        case malformedResponse
        /// The model named an id that is not an option.
        case unknownOption
    }

    /// - Parameter answer: the reply's text, nil when it had none.
    package static func probabilities(
        status: Int,
        answer: String?,
        options: [QuickCaptureOption]
    ) throws -> [String: Double] {
        guard (200..<300).contains(status) else { throw Failure.http(status: status) }
        guard let answer,
              let object = jsonObject(in: answer),
              let id = object["project"] as? String
        else { throw Failure.malformedResponse }
        guard options.contains(where: { $0.id == id }) else { throw Failure.unknownOption }
        let confidence = (object["confidence"] as? NSNumber)?.doubleValue ?? unstatedConfidence
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
    private let configuration: LLMPolishingConfiguration
    private let session: URLSession
    private let usageRecorder: (any UsageRecording)?
    private let now: @Sendable () -> Date

    /// - Parameter configuration: the polishing server this classifier
    ///   borrows, its dialect and its usage-ledger backend.
    package init(
        configuration: LLMPolishingConfiguration,
        session: URLSession = SameOriginHTTP.shared,
        usageRecorder: (any UsageRecording)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.session = session
        self.usageRecorder = usageRecorder
        self.now = now
    }

    package var kind: QuickCaptureRoute.Classifier { .chatModel }

    package func classify(capture: String, options: [QuickCaptureOption]) async throws -> [String: Double] {
        let request = try configuration.urlRequest(
            for: QuickCaptureChatRouting.wireRequest(capture: capture, options: options))
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let reply = configuration.reply(to: data)
        // A 2xx is billed whether or not its answer is usable, so it is
        // recorded before the answer is judged.
        if (200..<300).contains(status), let usageRecorder {
            usageRecorder.record(UsageEntry.chat(
                date: now(),
                feature: .quickCaptureRouting,
                backend: configuration.usageBackend,
                requestedModel: configuration.model,
                usage: reply?.usage
            ))
        }
        return try QuickCaptureChatRouting.probabilities(status: status, answer: reply?.text, options: options)
    }
}

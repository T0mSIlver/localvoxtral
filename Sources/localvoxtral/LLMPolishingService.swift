import Foundation
import os

// Test seams need to substitute a suspending polishing service so stop cleanup
// can be proven idempotent while post-processing is still in flight.
protocol LLMPolishingServicing: Sendable {
    func polish(
        request: LLMPolishingRequest,
        configuration: LLMPolishingConfiguration
    ) async throws -> LLMPolishingResult
}

struct LLMPolishingRequest: Sendable {
    let inputText: String
    let systemPrompt: String
    let userPrompts: [String]
    /// Optional generation cap forwarded as `max_tokens`. Production polish
    /// requests leave it nil (the helper applies its own default); the
    /// prompt-prefix warmup sets 1 so the throwaway generation costs a
    /// single token.
    let maxTokens: Int?
    /// Nil for a polish, which the user is waiting on. The term-suggestion
    /// request reads weeks of dictations in one go and is started from
    /// Settings, so it may take longer than a polish is allowed to.
    let timeoutSeconds: TimeInterval?
    /// False for a polish, which has to be fast. True asks a hosted reasoning
    /// model to think before answering (`MistralReasoningEffort.high`);
    /// self-hosted shapes ignore it and keep their configured behaviour.
    let prefersDeepReasoning: Bool
    /// The feature the usage ledger charges this request to. Nil records
    /// nothing: the warmup's one-token throwaway on the bundled helper.
    let usageFeature: UsageEntry.Feature?

    init(
        inputText: String,
        systemPrompt: String,
        userPrompts: [String],
        maxTokens: Int? = nil,
        timeoutSeconds: TimeInterval? = nil,
        prefersDeepReasoning: Bool = false,
        usageFeature: UsageEntry.Feature? = .polish
    ) {
        self.inputText = inputText
        self.systemPrompt = systemPrompt
        self.userPrompts = userPrompts
        self.maxTokens = maxTokens
        self.timeoutSeconds = timeoutSeconds
        self.prefersDeepReasoning = prefersDeepReasoning
        self.usageFeature = usageFeature
    }

    /// The characters of every message sent, for the usage ledger.
    var promptCharacters: Int {
        userPrompts.reduce(systemPrompt.count) { $0 + $1.count }
    }

    /// The request as every polishing server's dialect takes it.
    var wire: PolishWireRequest {
        PolishWireRequest(
            systemPrompt: systemPrompt,
            userPrompts: userPrompts,
            maxTokens: maxTokens,
            timeout: LLMPolishingService.timeoutInterval(for: self),
            purpose: .polish,
            effort: prefersDeepReasoning ? .deep : .standard
        )
    }
}

/// Endpoint and model for Mistral's hosted polishing API. Settings wires these
/// in separately; they live here so the request shape and its defaults are
/// stated in one place.
enum MistralPolishDefaults {
    /// Base URL — `LLMPolishingConfiguration.requestURL` turns it into
    /// `https://api.mistral.ai/v1/chat/completions`.
    static let endpoint = URL(string: "https://api.mistral.ai")!
    /// `mistral-medium-3-5` (aliases `mistral-medium-latest`,
    /// `mistral-medium-3`).
    static let model = "mistral-medium-3-5"
}

struct LLMPolishingResult: Sendable {
    let rawText: String
    let polishedText: String
    let durationSeconds: Double
    var usage: LLMTokenUsage? = nil
}

struct LLMPolishingService: LLMPolishingServicing {
    /// Receives one entry per request that carries a usage feature, on every
    /// backend; only Mistral's are priced. Nil records nothing.
    var usageRecorder: (any UsageRecording)?
    let session: URLSession
    /// Times the request's whole budget (#1688). Injected so tests run it
    /// on a manual clock.
    let sleep: @Sendable (Duration) async -> Void

    init(
        usageRecorder: (any UsageRecording)? = nil,
        session: URLSession = SameOriginHTTP.shared,
        sleep: @escaping @Sendable (Duration) async -> Void = SessionClock.live.sleep
    ) {
        self.usageRecorder = usageRecorder
        self.session = session
        self.sleep = sleep
    }

    /// One rule for every backend. The timeout is only the client's cap: a
    /// fast hosted model finishes long before it, and a long transcript takes
    /// longer on an external server or Mistral too.
    static func timeoutInterval(for request: LLMPolishingRequest) -> TimeInterval {
        PolishRequestTimeout.seconds(
            forInputCharacters: request.inputText.count,
            override: request.timeoutSeconds
        )
    }

    /// Classify a URLSession transport failure. A timeout keeps its own case; every other
    /// failure stays a network error carrying the system's description.
    static func polishingError(
        forTransportError error: Error,
        timeoutSeconds: TimeInterval
    ) -> LLMPolishingError {
        if let urlError = error as? URLError, urlError.code == .timedOut {
            return .timedOut(afterSeconds: timeoutSeconds)
        }
        return .networkError(error.localizedDescription)
    }

    func polish(
        request: LLMPolishingRequest,
        configuration: LLMPolishingConfiguration
    ) async throws -> LLMPolishingResult {
        let trimmed = request.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LLMPolishingError.emptyInput
        }

        let startTime = CFAbsoluteTimeGetCurrent()

        let urlRequest = try Self.makeURLRequest(
            request: request,
            configuration: configuration
        )

        let data: Data
        let response: URLResponse
        do {
            let session = session
            (data, response) = try await PolishRequestTimeout.enforcing(
                seconds: urlRequest.timeoutInterval, sleep: sleep
            ) {
                try await session.data(for: urlRequest)
            }
        } catch let deadline as PolishDeadlinePassed {
            // Sent and still answering: it may be billed.
            Log.backends.error(
                "Polish: no complete answer from \(urlRequest.url?.host ?? "-", privacy: .public) within its \(Int(deadline.seconds), privacy: .public) s budget; cancelled"
            )
            recordUsage(request: request, configuration: configuration, usage: nil)
            throw LLMPolishingError.timedOut(afterSeconds: deadline.seconds)
        } catch {
            let polishingError = Self.polishingError(
                forTransportError: error,
                timeoutSeconds: urlRequest.timeoutInterval
            )
            // A request abandoned after it was sent (timed out, cancelled by
            // the next dictation, connection dropped) may still be billed, and
            // Mistral never gets to say for how much: record it as unpriced
            // rather than let it vanish. One that never left costs nothing
            // either way — it only shows in the unpriced count.
            if Self.mayHaveBeenBilled(transportError: error) {
                recordUsage(request: request, configuration: configuration, usage: nil)
            }
            throw polishingError
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMPolishingError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let responseBody = String(data: data, encoding: .utf8) ?? "<unreadable>"
            throw LLMPolishingError.requestFailed(
                statusCode: httpResponse.statusCode,
                body: String(responseBody.prefix(500))
            )
        }

        let reply = configuration.reply(to: data)
        // A 2xx is billed whether or not its content is usable, so usage is
        // recorded before the content is judged.
        let usage = reply?.usage
        recordUsage(request: request, configuration: configuration, usage: usage)

        // A reply cut off at the backend's output limit is a prefix of the
        // polish: committing it would drop the rest of the dictation (#1109).
        // A request that set its own cap (the one-token warmup) asked for it.
        if request.maxTokens == nil, reply?.stoppedAtOutputLimit == true {
            throw LLMPolishingError.truncated
        }

        // A declined request may still carry partial text; never commit it.
        if reply?.refused == true {
            Log.backends.error(
                "Polish: \(urlRequest.url?.host ?? "-", privacy: .public) declined the request (stop_reason refusal)"
            )
            throw LLMPolishingError.invalidResponse
        }

        guard let content = reply?.text else {
            throw LLMPolishingError.invalidResponse
        }

        let polished = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !polished.isEmpty else {
            throw LLMPolishingError.invalidResponse
        }

        let duration = CFAbsoluteTimeGetCurrent() - startTime

        return LLMPolishingResult(
            rawText: trimmed,
            polishedText: polished,
            durationSeconds: duration,
            usage: usage
        )
    }

    static func mayHaveBeenBilled(transportError error: Error) -> Bool {
        guard let urlError = error as? URLError else {
            return error is CancellationError
        }
        switch urlError.code {
        case .timedOut, .cancelled, .networkConnectionLost:
            return true
        default:
            return false
        }
    }

    private func recordUsage(
        request: LLMPolishingRequest,
        configuration: LLMPolishingConfiguration,
        usage: LLMTokenUsage?
    ) {
        guard let feature = request.usageFeature, let usageRecorder else { return }
        usageRecorder.record(
            UsageEntry.chat(
                date: Date(),
                feature: feature,
                backend: configuration.usageBackend,
                requestedModel: configuration.model,
                usage: usage,
                promptCharacters: request.promptCharacters
            ))
    }

    /// The full URLRequest for one polish call (and the test seam pinning
    /// the timeout without networking).
    static func makeURLRequest(
        request: LLMPolishingRequest,
        configuration: LLMPolishingConfiguration
    ) throws -> URLRequest {
        try configuration.urlRequest(for: request.wire)
    }
}

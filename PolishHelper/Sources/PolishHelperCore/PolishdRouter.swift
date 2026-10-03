import Foundation

/// Routes the endpoints the app's supervisor, polish client and Settings use:
/// GET /health (readiness probe), POST /v1/chat/completions, and
/// POST /v1/tokenize, which counts a text's tokens for Settings' prompt sizes.
///
/// `/v1/tokenize` takes `{"text": "..."}` and answers `{"tokens": n}`. It only
/// reads the tokenizer, so it changes nothing a polish sends or gets back.
public struct PolishdRouter: Sendable {
    private let responder: any ChatResponding
    private let modelName: String

    public init(responder: any ChatResponding, modelName: String) {
        self.responder = responder
        self.modelName = modelName
    }

    public func handle(_ request: HTTPRequest) async -> HTTPResponse {
        switch (request.method, request.path) {
        case ("GET", "/health"):
            return .json(200, ["status": "ok"])
        case ("POST", "/v1/chat/completions"):
            return await handleChatCompletion(request)
        case ("POST", "/v1/tokenize"):
            return await handleTokenize(request)
        case (_, "/health"), (_, "/v1/chat/completions"), (_, "/v1/tokenize"):
            return errorResponse(405, "method not allowed", type: "invalid_request_error")
        default:
            return errorResponse(404, "not found: \(request.path)", type: "invalid_request_error")
        }
    }

    private func handleChatCompletion(_ request: HTTPRequest) async -> HTTPResponse {
        let completion: ChatCompletionRequest
        do {
            completion = try JSONDecoder().decode(ChatCompletionRequest.self, from: request.body)
        } catch {
            return errorResponse(400, "invalid JSON body: \(error)", type: "invalid_request_error")
        }
        if completion.stream == true {
            return errorResponse(400, "streaming is not supported", type: "invalid_request_error")
        }
        guard !completion.messages.isEmpty else {
            return errorResponse(400, "messages must not be empty", type: "invalid_request_error")
        }
        // One model is loaded. A request for another one (a stop that read
        // the selection before a model switch) must not be answered by this
        // one under the name it asked for (#1591).
        if let requested = completion.model, !requested.isEmpty, requested != modelName {
            PolishdLog.error("chat.completion refused: requested model \(requested), loaded \(modelName)")
            return errorResponse(
                400, "model \(requested) is not loaded; this helper serves \(modelName)",
                type: "invalid_request_error")
        }

        do {
            let start = ContinuousClock.now
            let reply = try await responder.respond(
                to: completion.messages,
                chatTemplateArguments: completion.chatTemplateArguments,
                sampling: completion.sampling
            )
            let elapsed = start.duration(to: .now)
            if let timings = reply.timings {
                PolishdLog.info("chat.completion ok in \(elapsed); \(timings.summary)")
            } else {
                PolishdLog.info("chat.completion ok in \(elapsed)")
            }
            let response = ChatCompletionResponse(
                id: "polishd-\(UUID().uuidString)",
                created: Int(Date().timeIntervalSince1970),
                model: modelName,
                content: reply.content,
                timings: reply.timings,
                finishReason: reply.finishReason
            )
            return .json(200, response)
        } catch let error as ChatRespondingError {
            return errorResponse(400, "\(error)", type: "invalid_request_error")
        } catch {
            PolishdLog.error("chat.completion failed: \(error)")
            return errorResponse(500, "generation failed: \(error)", type: "server_error")
        }
    }

    private struct TokenizeRequest: Decodable {
        let text: String
    }

    private struct TokenizeResponse: Encodable {
        let tokens: Int
    }

    private func handleTokenize(_ request: HTTPRequest) async -> HTTPResponse {
        let tokenize: TokenizeRequest
        do {
            tokenize = try JSONDecoder().decode(TokenizeRequest.self, from: request.body)
        } catch {
            return errorResponse(400, "invalid JSON body: \(error)", type: "invalid_request_error")
        }
        do {
            return .json(200, TokenizeResponse(tokens: try await responder.tokenCount(of: tokenize.text)))
        } catch {
            PolishdLog.error("tokenize failed: \(error)")
            return errorResponse(500, "tokenize failed: \(error)", type: "server_error")
        }
    }

    private func errorResponse(_ status: Int, _ message: String, type: String) -> HTTPResponse {
        .json(status, ChatCompletionErrorResponse(message: message, type: type))
    }
}

/// stderr logging: the supervising app captures the helper's output into the
/// diagnostics ring buffer, so failures here stay visible in exports.
public enum PolishdLog {
    public static func info(_ message: String) {
        emit("info", message)
    }

    public static func error(_ message: String) {
        emit("error", message)
    }

    private static func emit(_ level: String, _ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        fputs("\(stamp) [\(level)] \(message)\n", stderr)
        fflush(stderr)
    }
}

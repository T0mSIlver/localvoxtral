import Foundation

/// Routes the two endpoints the app's supervisor and polish client use:
/// GET /health (readiness probe) and POST /v1/chat/completions.
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
        case (_, "/health"), (_, "/v1/chat/completions"):
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

        do {
            let start = ContinuousClock.now
            let content = try await responder.respond(
                to: completion.messages,
                chatTemplateArguments: completion.chatTemplateArguments,
                sampling: completion.sampling
            )
            let elapsed = start.duration(to: .now)
            PolishdLog.info("chat.completion ok in \(elapsed)")
            let response = ChatCompletionResponse(
                id: "polishd-\(UUID().uuidString)",
                created: Int(Date().timeIntervalSince1970),
                model: completion.model ?? modelName,
                content: content
            )
            return .json(200, response)
        } catch let error as ChatRespondingError {
            return errorResponse(400, "\(error)", type: "invalid_request_error")
        } catch {
            PolishdLog.error("chat.completion failed: \(error)")
            return errorResponse(500, "generation failed: \(error)", type: "server_error")
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

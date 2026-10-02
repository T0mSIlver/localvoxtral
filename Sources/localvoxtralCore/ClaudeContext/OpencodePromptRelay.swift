import ClaudeContextWire
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// opencode's route into an agent (#719): the opencode
/// TUI half's prompt relay, which appends text to the prompt of the pane that
/// displays `opencodeSessionID` and submits it. Resolved from a fresh focus
/// declaration (`ClaudeSessionRegistry.opencodePromptRelay(sessionID:)`), so
/// it names the pane a verified peer declared. Read docs/agent/invariants.md
/// ("The app writes into an agent only through its routes")
/// before widening what it may do.
public struct OpencodePromptRelay: Sendable, Equatable {
    public var address: OpencodePromptRelayAddress
    /// opencode's own session id, unscoped. The relay refuses a call for any
    /// session but the one its pane displays when the call arrives.
    public var opencodeSessionID: String

    public init(address: OpencodePromptRelayAddress, opencodeSessionID: String) {
        self.address = address
        self.opencodeSessionID = opencodeSessionID
    }
}

/// The relay's two endpoints.
extension AgentPromptCall {
    var opencodeRelayPath: String {
        switch self {
        case .append: "/tui/append-prompt"
        case .submit: "/tui/submit-prompt"
        }
    }
}

/// The relay as a route for `AgentPromptSink`.
package struct OpencodePromptRoute: AgentPromptRoute {
    package let relay: OpencodePromptRelay
    private let client: OpencodePromptRelayClient
    /// Whether a key typed now would land in this session's prompt: the
    /// terminal the dictation started in is frontmost and its focused pane
    /// shows the session. Asked only after a call that surely did not land.
    private let keysReachThePrompt: @Sendable () async -> Bool

    package init(
        relay: OpencodePromptRelay,
        client: OpencodePromptRelayClient = .shared,
        keysReachThePrompt: @escaping @Sendable () async -> Bool
    ) {
        self.relay = relay
        self.client = client
        self.keysReachThePrompt = keysReachThePrompt
    }

    package var name: String { "opencode prompt relay" }

    /// Keys only for a call that surely did not land, and only into the same
    /// prompt (#1057). A call that may have landed, or one the relay refused
    /// because its pane shows another session now, stays in History.
    package func deliver(_ call: AgentPromptCall) async -> AgentPromptDelivery {
        switch await client.post(call, to: relay) {
        case .delivered:
            return .delivered
        case .refused(status: 409):
            return .keepInHistory
        case .refused, .notSent:
            return await keysReachThePrompt() ? .typeInstead : .keepInHistory
        case .unknown:
            return .keepInHistory
        }
    }
}

/// What became of one request to the relay.
package enum OpencodeRelayAnswer: Sendable, Equatable {
    /// HTTP 200: the relay took the call.
    case delivered
    /// The relay answered with another status: nothing landed. 409 means the
    /// pane no longer displays the session.
    case refused(status: Int)
    /// The request never reached the relay: a malformed address, a text too
    /// long for it, or a connection refused.
    case notSent
    /// The request may have reached the relay, with no answer read back: a
    /// timeout, a dropped connection. It may have landed.
    case unknown
}

/// HTTP to `127.0.0.1:<port>`, the host fixed here: the wire carries a port
/// and nothing else. No proxy, no cookies, no cache, a short timeout; a
/// relay that is slow is treated as gone, and the text falls back to keys.
package struct OpencodePromptRelayClient: Sendable {
    /// Bytes of text one append may carry. The relay caps its request body
    /// at 64 KiB; anything longer goes by keystrokes instead.
    package static let maxAppendBytes = 32 * 1024
    package static let timeout: TimeInterval = 2
    /// One for the app: a URLSession lives until invalidated, so one per
    /// dictation would pile up.
    package static let shared = OpencodePromptRelayClient()

    private let session: URLSession

    package init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = Self.timeout
        configuration.timeoutIntervalForResource = Self.timeout
        session = SameOriginHTTP.session(configuration: configuration)
    }

    package func post(_ call: AgentPromptCall, to relay: OpencodePromptRelay) async -> OpencodeRelayAnswer {
        guard relay.address.isWellFormed,
              let url = URL(string: "http://127.0.0.1:\(relay.address.port)\(call.opencodeRelayPath)")
        else { return .notSent }
        var body: [String: String] = ["session_id": relay.opencodeSessionID]
        if case .append(let text) = call {
            guard text.utf8.count <= Self.maxAppendBytes else {
                Log.backends.notice("opencode prompt relay: append too long for the relay; not sent")
                return .notSent
            }
            body["text"] = text
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(relay.address.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let kind = call == .submit ? "submit" : "append"
        Log.backends.info("opencode prompt relay: \(kind, privacy: .public) sent")
        do {
            let (_, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                Log.backends.error(
                    "opencode prompt relay: \(kind, privacy: .public) refused, HTTP \(status, privacy: .public)"
                )
                return .refused(status: status)
            }
            Log.backends.info("opencode prompt relay: \(kind, privacy: .public) delivered")
            return .delivered
        } catch {
            let answer = Self.answer(for: error)
            let landing = answer == .notSent ? "not sent" : "may have landed"
            Log.backends.error(
                "opencode prompt relay: \(kind, privacy: .public) failed (\(landing, privacy: .public)): \(error.localizedDescription, privacy: .public)"
            )
            return answer
        }
    }

    /// A connection that never opened sent nothing; any other failure may
    /// come after the relay read the request.
    static func answer(for error: any Error) -> OpencodeRelayAnswer {
        switch (error as? URLError)?.code {
        case .cannotConnectToHost?, .cannotFindHost?, .notConnectedToInternet?:
            return .notSent
        default:
            return .unknown
        }
    }
}

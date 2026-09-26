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

    package init(relay: OpencodePromptRelay, client: OpencodePromptRelayClient = .shared) {
        self.relay = relay
        self.client = client
    }

    package var name: String { "opencode prompt relay" }

    /// Every failure types instead, as #719 shipped it. An append that
    /// timed out after it was sent may still have landed.
    package func deliver(_ call: AgentPromptCall) async -> AgentPromptDelivery {
        await client.post(call, to: relay) ? .delivered : .typeInstead
    }
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
        session = URLSession(configuration: configuration)
    }

    package func post(_ call: AgentPromptCall, to relay: OpencodePromptRelay) async -> Bool {
        guard relay.address.isWellFormed,
              let url = URL(string: "http://127.0.0.1:\(relay.address.port)\(call.opencodeRelayPath)")
        else { return false }
        var body: [String: String] = ["session_id": relay.opencodeSessionID]
        if case .append(let text) = call {
            guard text.utf8.count <= Self.maxAppendBytes else {
                Log.backends.notice("opencode prompt relay: append too long for the relay; keystrokes instead")
                return false
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
                return false
            }
            Log.backends.info("opencode prompt relay: \(kind, privacy: .public) delivered")
            return true
        } catch {
            Log.backends.error(
                "opencode prompt relay: \(kind, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }
}

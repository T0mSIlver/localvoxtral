import ClaudeContextWire
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The one route by which the app writes into an agent (#719): the opencode
/// TUI half's prompt relay, which appends text to the prompt of the pane that
/// displays `opencodeSessionID` and submits it. Resolved from a fresh focus
/// declaration (`ClaudeSessionRegistry.opencodePromptRelay(sessionID:)`), so
/// it names the pane a verified peer declared. Read docs/agent/invariants.md
/// ("The app writes into an agent only through opencode's prompt relay")
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

/// The two calls the relay takes. There is no third.
package enum OpencodePromptRelayCall: Sendable, Equatable {
    case append(String)
    case submit

    var path: String {
        switch self {
        case .append: "/tui/append-prompt"
        case .submit: "/tui/submit-prompt"
        }
    }
}

package protocol OpencodePromptRelayPosting: Sendable {
    /// True only when the relay answered 200: the call reached the pane.
    func post(_ call: OpencodePromptRelayCall, to relay: OpencodePromptRelay) async -> Bool
}

/// HTTP to `127.0.0.1:<port>`, the host fixed here: the wire carries a port
/// and nothing else. No proxy, no cookies, no cache, a short timeout; a
/// relay that is slow is treated as gone, and the text falls back to keys.
package struct OpencodePromptRelayClient: OpencodePromptRelayPosting {
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

    package func post(_ call: OpencodePromptRelayCall, to relay: OpencodePromptRelay) async -> Bool {
        guard relay.address.isWellFormed,
              let url = URL(string: "http://127.0.0.1:\(relay.address.port)\(call.path)")
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

/// One dictation's writes into the relay, delivered in the order they were
/// made, one call in flight at a time. The first call that fails ends the
/// route for the rest of the dictation: that call's text and every append
/// queued behind it go to `fallback`, in order, and every later append goes
/// straight there. A submit queued behind a failure is dropped, never turned
/// into a key: the text it would have sent may have gone elsewhere.
@MainActor
package final class OpencodePromptRelaySink {
    package let relay: OpencodePromptRelay
    private let poster: any OpencodePromptRelayPosting
    private let fallback: @MainActor (String) -> Void
    private var queue: [OpencodePromptRelayCall] = []
    private var draining = false
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    /// False from the first failed call on.
    package private(set) var isHealthy = true

    package init(
        relay: OpencodePromptRelay,
        poster: any OpencodePromptRelayPosting = OpencodePromptRelayClient.shared,
        fallback: @escaping @MainActor (String) -> Void
    ) {
        self.relay = relay
        self.poster = poster
        self.fallback = fallback
    }

    package func append(_ text: String) {
        guard !text.isEmpty else { return }
        guard isHealthy else {
            fallback(text)
            return
        }
        enqueue(.append(text))
    }

    /// Submits once every append made before it has landed.
    package func submit() {
        guard isHealthy else {
            Log.backends.notice("opencode prompt relay: route failed earlier; submit dropped")
            return
        }
        enqueue(.submit)
    }

    /// Returns once nothing is queued or in flight.
    package func waitUntilIdle() async {
        guard draining else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    private func enqueue(_ call: OpencodePromptRelayCall) {
        queue.append(call)
        guard !draining else { return }
        draining = true
        Task { await drain() }
    }

    private func drain() async {
        while let call = queue.first {
            let delivered = await poster.post(call, to: relay)
            if delivered {
                queue.removeFirst()
                continue
            }
            isHealthy = false
            let pending = queue
            queue.removeAll()
            let texts = pending.compactMap { call -> String? in
                if case .append(let text) = call { return text }
                return nil
            }
            let droppedSubmits = pending.count - texts.count
            Log.backends.notice(
                "opencode prompt relay: route failed; \(texts.count, privacy: .public) appends go by keystrokes, \(droppedSubmits, privacy: .public) submits dropped"
            )
            for text in texts { fallback(text) }
        }
        draining = false
        let waiters = idleWaiters
        idleWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

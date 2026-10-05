import ClaudeContextWire
import Dispatch
import Foundation
import Synchronization

/// `/inbox` for a remote session's mod (#1412): the Inbox pane's list and its
/// "Open in localvoxtral", on the listener behind the mod channel's proofs.
///
/// A capture's words stay on the Mac (#725). The list carries only what the
/// local pane shows: id, drafted title, kind, state and capture date. A
/// capture without a drafted title goes with an empty one, since the title
/// the Mac derives for it is the start of its words. Never its text, note
/// or draft body. It lists only the captures of the project the asking
/// session is in, and only for a session a hook of the same host named, so
/// one host never reads another project's titles. An open names an id; it
/// opens only a capture of that same project.
public final class RemoteInboxRoute: Sendable {
    public static let listPath = "/v1/mod/inbox"
    public static let openPath = "/v1/mod/inbox/open"
    /// A request is two ids and a capture id.
    public static let maxRequestBytes = 1024

    package struct Request: Decodable, Equatable, Sendable {
        package var modInbox: Int
        package var sessionID: String
        package var nonce: String
        /// The capture to open; absent on a list.
        package var id: String?

        enum CodingKeys: String, CodingKey {
            case modInbox = "mod_inbox"
            case sessionID = "session_id"
            case nonce, id
        }
    }

    /// One capture as the pane shows it. The type is the privacy boundary:
    /// a field not here cannot cross the wire.
    package struct Capture: Encodable, Equatable, Sendable {
        package var id: String
        package var title: String
        package var kind: String?
        package var state: String
        package var capturedAt: Date
    }

    /// The answer's shape is `localvoxtral capture list --json`'s, cut to
    /// those fields, so the pane reads both the same way.
    private struct ListAnswer: Encodable {
        struct Captures: Encodable {
            var inboxAvailable: Bool
            var captures: [Capture]
        }

        var ok = true
        var captures: Captures
    }

    package enum Answer: Equatable, Sendable {
        /// 200 with this body.
        case list(Data)
        /// 200, nothing to say.
        case opened
        /// The session is not one a hook of this host named, or has no
        /// remote project: 409, which the mod reads as "not yet".
        case unknownSession
        /// The id is no capture of the session's project: 404.
        case unknownCapture
        case timedOut
    }

    private let registry: ClaudeSessionRegistry
    private let captures: @Sendable () async -> [QuickCaptureItem]?
    private let open: @Sendable (UUID) async -> Bool?
    private let timeout: TimeInterval

    /// - Parameters:
    ///   - captures: the Inbox, or nil when the app has none.
    ///   - open: brings the Inbox forward on the capture; false when it is
    ///     gone, nil without an Inbox.
    package init(
        registry: ClaudeSessionRegistry,
        timeout: TimeInterval = 5,
        captures: @escaping @Sendable () async -> [QuickCaptureItem]?,
        open: @escaping @Sendable (UUID) async -> Bool?
    ) {
        self.registry = registry
        self.timeout = timeout
        self.captures = captures
        self.open = open
    }

    /// A request of this version with well-formed ids, or nil. A list has no
    /// `id`; an open has a capture's UUID.
    package static func decode(_ data: Data, opening: Bool) -> Request? {
        guard let request = try? JSONDecoder().decode(Request.self, from: data),
              request.modInbox == ClaudeModChannelWire.version,
              ClaudeRemoteModWire.isSessionID(request.sessionID),
              ClaudeRemoteModWire.isNonce(request.nonce),
              opening == (request.id != nil),
              request.id.map({ UUID(uuidString: $0) != nil }) ?? true
        else { return nil }
        return request
    }

    /// The remote project of the session `sessionID` names on `hostID`, when
    /// a hook of that host named it.
    package func projectKey(hostID: String, sessionID: String) -> String? {
        let scoped = ClaudeRemoteSessionScope.scopedSessionID(hostID: hostID, sessionID: sessionID)
        let origin = ClaudeTransportOrigin.remote(channel: ClaudeRemoteSessionScope.channel(hostID: hostID))
        guard let snapshot = registry.snapshot(sessionID: scoped),
              snapshot.agent == .claude, snapshot.origin == origin
        else { return nil }
        return RemoteQuickCaptureRequests.remoteProjectKey(of: snapshot.learnedTermWorkspace)
    }

    /// The pane's view of one capture: nothing derived from its words.
    package static func capture(_ item: QuickCaptureItem) -> Capture {
        let drafted = !item.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return Capture(
            id: item.id.uuidString.lowercased(),
            title: QuickCaptureDraft.oneLine(item.title, limit: QuickCaptureDraft.maxTitleCharacters),
            kind: item.kind?.rawValue ?? (drafted ? "issue" : nil),
            state: item.state.rawValue,
            capturedAt: item.capturedAt
        )
    }

    /// How much longer an open already under way is waited for: with the
    /// default timeout it stays under the mod's 8 s `ASK_ABANDON_MS`.
    static let openGrace: TimeInterval = 2

    /// Blocks the calling connection thread, never the main one, until the
    /// app answers or `timeout` passes.
    package func answer(hostID: String, request: Request) -> Answer {
        guard let projectKey = projectKey(hostID: hostID, sessionID: request.sessionID) else {
            Log.claudeContext.info("Remote inbox: refused a session no hook of its host has named")
            return .unknownSession
        }
        enum Phase { case waiting, opening, expired }
        let result = Mutex<Answer?>(nil)
        // An open that has not started when the wait gives up must not raise
        // the Inbox after the host was told it failed; one already under way
        // is waited for instead.
        let phase = Mutex(Phase.waiting)
        let done = DispatchSemaphore(value: 0)
        let captures = self.captures, open = self.open
        Task {
            let items = await captures()
            let inProject = (items ?? []).filter { $0.projectKey == projectKey }
            let answer: Answer
            if let id = request.id {
                // Checked against the project before anything opens: an id
                // from another project is as unknown as a made-up one.
                if let item = inProject.first(where: { $0.id.uuidString.lowercased() == id.lowercased() }),
                   phase.withLock({ phase in
                       guard phase == .waiting else { return false }
                       phase = .opening
                       return true
                   }),
                   await open(item.id) == true {
                    answer = .opened
                } else {
                    answer = .unknownCapture
                }
            } else {
                answer = .list(Self.listBody(inboxAvailable: items != nil, inProject))
            }
            result.withLock { $0 = answer }
            done.signal()
        }
        var finished = done.wait(timeout: .now() + timeout) == .success
        if !finished {
            let opening = phase.withLock { phase -> Bool in
                if phase == .waiting { phase = .expired }
                return phase == .opening
            }
            if opening { finished = done.wait(timeout: .now() + Self.openGrace) == .success }
        }
        guard finished, let answer = result.withLock({ $0 }) else {
            Log.backends.error("Remote inbox: the app did not answer in \(self.timeout, privacy: .public) s")
            return .timedOut
        }
        if answer == .unknownCapture {
            Log.backends.error("Remote inbox: refused to open a capture outside the session's project")
        }
        return answer
    }

    package static func listBody(inboxAvailable: Bool, _ items: [QuickCaptureItem]) -> Data {
        let answer = ListAnswer(captures: .init(
            inboxAvailable: inboxAvailable,
            captures: items.map(capture).sorted { $0.capturedAt > $1.capturedAt }
        ))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(answer)) ?? Data("{\"ok\":false}".utf8)
    }
}

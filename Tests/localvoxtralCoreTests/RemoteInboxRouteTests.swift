import ClaudeContextWire
import Foundation
import XCTest
@testable import localvoxtralCore
import localvoxtralTestSupport

/// A remote session's `/inbox` (#1412) over a real loopback socket: what
/// crosses the wire, for which session, and which capture an open reaches.
final class RemoteInboxRouteTests: XCTestCase {
    private let nonce = String(repeating: "4", count: 32)
    private var hosts: ClaudeRemoteHostRegistry!
    private var sessions: ClaudeSessionRegistry!
    private var listener: ClaudeRemoteContextListener!
    private var port: UInt16 = 0
    private var token = ""
    private var hostID = ""
    private var otherToken = ""
    private var otherHostID = ""
    private let opened = LockedBox<[UUID]>([])
    private var items: [QuickCaptureItem] = []

    private static let epoch = Date(timeIntervalSince1970: 4_000_000)
    private static let words = "kerning words only the mac keeps"
    private static let undraftedWords = "undrafted words that stay home"

    override func setUpWithError() throws {
        try super.setUpWithError()
        hosts = try ClaudeRemoteHostRegistry(
            fileURL: URL(fileURLWithPath: "/tmp/lvx-remote-inbox-hosts.json"),
            io: MemoryRemoteHostStoreIO(),
            now: { Self.epoch }
        )
        let enrollment = try hosts.enroll(label: "buildhost")
        token = enrollment.token
        hostID = enrollment.host.id
        let other = try hosts.enroll(label: "otherhost")
        otherToken = other.token
        otherHostID = other.host.id
        sessions = ClaudeSessionRegistry(now: { Self.epoch }, isProcessAlive: { _ in true })

        let at = Self.epoch
        var drafted = QuickCaptureItem(capturedAt: at, text: Self.words)
        drafted.projectKey = "remote:quill"
        drafted.projectName = "quill"
        drafted.title = "Italic kerning"
        drafted.body = "draft body the mac keeps"
        drafted.kind = .issue
        drafted.note = "a note the mac keeps"
        var undrafted = QuickCaptureItem(capturedAt: at.addingTimeInterval(60), text: Self.undraftedWords)
        undrafted.projectKey = "remote:quill"
        var elsewhere = QuickCaptureItem(capturedAt: at, text: "another project's words")
        elsewhere.projectKey = "remote:other"
        elsewhere.title = "Another project's title"
        items = [drafted, undrafted, elsewhere]

        let items = items, opened = opened
        port = try unusedLoopbackPort()
        listener = ClaudeRemoteContextListener(
            registry: sessions,
            hosts: hosts,
            limits: ClaudeRemoteListenerLimits(port: port),
            now: { Self.epoch },
            inbox: RemoteInboxRoute(
                registry: sessions,
                captures: { items },
                open: { id in
                    opened.set(opened.value + [id])
                    return true
                }
            )
        )
        try listener.start()
    }

    override func tearDown() {
        listener?.stop()
        listener = nil
        super.tearDown()
    }

    /// A hook of the host names the session, in the `quill` project.
    private func hook(session: String, token: String? = nil) throws {
        let headers = [
            "Authorization": "Bearer \(token ?? self.token)", "Content-Type": "application/json",
            "X-Lvx-Plugin-Version": "1.41.0", "X-Lvx-Env-Project": "quill",
        ]
        let body = #"{"hook_event_name":"SessionStart","session_id":"\#(session)","cwd":"/srv/work/quill"}"#
        let response = try postToRemoteListener(
            port: port, path: "/v1/hook/SessionStart", headers: headers, body: Data(body.utf8)
        )
        XCTAssertEqual(response.status, 200)
    }

    private func ask(
        _ path: String, session: String, id: String? = nil, token: String? = nil, signed: Bool = true
    ) throws -> RemoteListenerResponse {
        let token = token ?? self.token
        let key = try XCTUnwrap(hosts.modChannelKey(hostID: token == otherToken ? otherHostID : hostID))
        let idField = id.map { #","id":"\#($0)""# } ?? ""
        let body = Data(#"{"mod_inbox":\#(ClaudeModChannelWire.version),"session_id":"\#(session)","nonce":"\#(nonce)"\#(idField)}"#.utf8)
        let proof = signed ? ClaudeRemoteModWire.requestProof(key: key, body: body) : String(repeating: "0", count: 64)
        let response = try postToRemoteListener(
            port: port, path: path,
            headers: ["Authorization": "Bearer \(token)", "Content-Type": "application/json", "X-Lvx-Mod-Proof": proof],
            body: body
        )
        if response.status != 401, response.status != 403 {
            XCTAssertEqual(
                response.headers["x-lvx-mod-proof"],
                ClaudeRemoteModWire.answerProof(key: key, nonce: nonce, body: response.body),
                "every answer the pane acts on carries the proof"
            )
        }
        return response
    }

    /// Tom's ruling on #1412: the list carries what the local pane shows and
    /// nothing of a capture's words, note or draft, and only the session's
    /// own project.
    func testTheListCarriesTitlesOfTheSessionsProjectAndNoWords() throws {
        try hook(session: "sess-1")

        let response = try ask(RemoteInboxRoute.listPath, session: "sess-1")

        XCTAssertEqual(response.status, 200)
        let text = String(decoding: response.body, as: UTF8.self)
        for kept in [Self.words, Self.undraftedWords, "draft body", "a note", "Another project", "undrafted", "kerning words"] {
            XCTAssertFalse(text.contains(kept), "\(kept) crossed the wire: \(text)")
        }
        let answer = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        let list = try XCTUnwrap(answer["captures"] as? [String: Any])
        XCTAssertEqual(list["inboxAvailable"] as? Bool, true)
        let captures = try XCTUnwrap(list["captures"] as? [[String: Any]])
        XCTAssertEqual(captures.map { $0["id"] as? String }, [items[1], items[0]].map { $0.id.uuidString.lowercased() })
        XCTAssertEqual(captures.map { $0["title"] as? String }, ["", "Italic kerning"])
        for capture in captures {
            XCTAssertTrue(Set(capture.keys).isSubset(of: ["id", "title", "kind", "state", "capturedAt"]), "\(capture.keys)")
        }
    }

    func testOnlyASessionAHookOfThatHostNamedGetsAList() throws {
        try hook(session: "sess-1")

        XCTAssertEqual(try ask(RemoteInboxRoute.listPath, session: "sess-9").status, 409)
        XCTAssertEqual(try ask(RemoteInboxRoute.listPath, session: "sess-1", token: otherToken).status, 409)
        // The token alone, as a squatter on the forward port holds it.
        XCTAssertEqual(try ask(RemoteInboxRoute.listPath, session: "sess-1", signed: false).status, 403)
    }

    func testAnOpenReachesOnlyACaptureOfTheSessionsProject() throws {
        try hook(session: "sess-1")

        let own = try ask(RemoteInboxRoute.openPath, session: "sess-1", id: items[0].id.uuidString.lowercased())
        let other = try ask(RemoteInboxRoute.openPath, session: "sess-1", id: items[2].id.uuidString.lowercased())
        let madeUp = try ask(RemoteInboxRoute.openPath, session: "sess-1", id: UUID().uuidString.lowercased())

        XCTAssertEqual(own.status, 200)
        XCTAssertEqual(other.status, 404)
        XCTAssertEqual(madeUp.status, 404)
        XCTAssertEqual(opened.value, [items[0].id])
    }
}

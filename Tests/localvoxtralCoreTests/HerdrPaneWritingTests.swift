import Foundation
import localvoxtralTestSupport
import Synchronization
import XCTest
@testable import localvoxtralCore

/// The two calls `HerdrSocketClient` writes into a pane with (#726), against
/// a fake herdr socket speaking herdr 0.9.0's wire.
final class HerdrPaneWritingTests: XCTestCase {
    private let client = HerdrSocketClient(timeout: 2)

    func testSendTextSendsPaneSendTextWithTheTextVerbatim() async throws {
        let herdr = try FakeHerdrSocket()
        defer { herdr.stop() }

        let sent = await client.sendText(socketPath: herdr.socketPath, paneID: "w1:p2", text: "fix the tests ")

        XCTAssertEqual(sent, .ok)
        XCTAssertEqual(
            herdr.requests,
            [.init(method: "pane.send_text", paneID: "w1:p2", text: "fix the tests ", keys: nil)]
        )
    }

    func testPressEnterSendsExactlyTheEnterKey() async throws {
        let herdr = try FakeHerdrSocket()
        defer { herdr.stop() }

        let pressed = await client.pressEnter(socketPath: herdr.socketPath, paneID: "w1:p2")

        XCTAssertEqual(pressed, .ok)
        XCTAssertEqual(
            herdr.requests,
            [.init(method: "pane.send_keys", paneID: "w1:p2", text: nil, keys: ["enter"])]
        )
    }

    /// The fake records a request before it replies (#808): the fake's
    /// thread is held after its answer until the test has read `requests`,
    /// so a fake that recorded after replying shows an empty list here.
    func testTheFakeRecordsTheRequestBeforeItsReply() async throws {
        let testHasRead = DispatchSemaphore(value: 0)
        let herdr = try FakeHerdrSocket(afterAnswer: { testHasRead.wait() })
        defer { herdr.stop() }

        let sent = await client.sendText(socketPath: herdr.socketPath, paneID: "w1:p2", text: "x")
        let recorded = herdr.requests
        testHasRead.signal()

        XCTAssertEqual(sent, .ok)
        XCTAssertEqual(recorded, [.init(method: "pane.send_text", paneID: "w1:p2", text: "x", keys: nil)])
    }

    /// A fake stopped while its thread is still busy keeps its listener until
    /// that thread ends (#1128). When `stop()` closed it, the next fake's
    /// `socket()` took the same descriptor, and the old thread's `accept()`
    /// then took the next test's request and hung up on it: the outcome was
    /// `unknown` and neither fake recorded anything.
    func testAStoppedFakeNeverAcceptsOnTheNextFakesSocket() async throws {
        let held = DispatchSemaphore(value: 0)
        let first = try FakeHerdrSocket(afterAnswer: { held.wait() })
        defer { first.stop() }
        let sent = await client.sendText(socketPath: first.socketPath, paneID: "w1:p2", text: "x")
        first.stop()
        let second = try FakeHerdrSocket()
        defer { second.stop() }
        held.signal()

        let ended = await first.waitForServeThreadToEnd()
        let pressed = await client.pressEnter(socketPath: second.socketPath, paneID: "w1:p2")

        XCTAssertEqual(sent, .ok)
        XCTAssertTrue(ended)
        XCTAssertEqual(pressed, .ok)
        XCTAssertEqual(second.requests, [.init(method: "pane.send_keys", paneID: "w1:p2", text: nil, keys: ["enter"])])
    }

    /// herdr's own error answer says the write did not happen.
    func testAnErrorEnvelopeIsARefusal() async throws {
        let herdr = try FakeHerdrSocket { _ in .error("pane_not_found") }
        defer { herdr.stop() }

        let sent = await client.sendText(socketPath: herdr.socketPath, paneID: "w1:p9", text: "x")
        let pressed = await client.pressEnter(socketPath: herdr.socketPath, paneID: "w1:p9")

        XCTAssertEqual(sent, .refused)
        XCTAssertEqual(pressed, .refused)
    }

    /// herdr's answer can arrive through a remote forward, so its error code
    /// and message are untrusted text (#1107). What the client logs and
    /// records is the code when it is shaped like one, and the message's
    /// length; the refusal itself is unchanged.
    func testAnErrorEnvelopeIsLoggedWithoutItsMessageOrAnUnshapedCode() async throws {
        let sentinel = "SENTINEL-sk-live-4f9a2c"
        let herdr = try FakeHerdrSocket { request in
            request.method == "pane.send_text"
                ? .error(sentinel, message: "prompt: \(sentinel)")
                : .error("pane_not_found", message: "no pane \(sentinel)")
        }
        defer { herdr.stop() }
        let details = RecordedDetails()
        let client = HerdrSocketClient(timeout: 2, latencyRecorder: { _, _, _, detail in
            details.lock.withLock { $0.append(detail) }
        })

        let sent = await client.sendText(socketPath: herdr.socketPath, paneID: "w1:p9", text: "x")
        let pane = await client.focusedPane(socketPath: herdr.socketPath)

        XCTAssertEqual(sent, .refused)
        XCTAssertNil(pane)
        XCTAssertEqual(details.lock.withLock { $0 }, [
            "unrecognized-code: 31-character message",
            "pane_not_found: 31-character message",
        ])
    }

    /// The request went out and nothing came back: it may have landed.
    func testNoReplyIsUnknown() async throws {
        let herdr = try FakeHerdrSocket { _ in .hangUp }
        defer { herdr.stop() }

        let sent = await client.sendText(socketPath: herdr.socketPath, paneID: "w1:p2", text: "x")

        XCTAssertEqual(sent, .unknown)
    }

    /// A reply for another request, or of another type, is not an `ok`, and
    /// does not say the write did not happen either.
    func testAnAnswerThatIsNotThisRequestsOkIsUnknown() async throws {
        let foreign = try FakeHerdrSocket { _ in .raw(#"{"id":"someone-else","result":{"type":"ok"}}"#) }
        defer { foreign.stop() }
        let wrongType = try FakeHerdrSocket { _ in .raw(#"{"id":"x","result":{"type":"pane_current"}}"#) }
        defer { wrongType.stop() }

        let toForeign = await client.sendText(socketPath: foreign.socketPath, paneID: "w1:p2", text: "x")
        let toWrongType = await client.pressEnter(socketPath: wrongType.socketPath, paneID: "w1:p2")

        XCTAssertEqual(toForeign, .unknown)
        XCTAssertEqual(toWrongType, .unknown)
    }

    /// Nothing reached a socket: a refusal.
    func testARelativeOrMissingSocketPathIsRefused() async {
        let relative = await client.sendText(socketPath: "herdr.sock", paneID: "w1:p2", text: "x")
        let missing = await client.pressEnter(socketPath: "/tmp/lvx-no-such-herdr.sock", paneID: "w1:p2")

        XCTAssertEqual(relative, .refused)
        XCTAssertEqual(missing, .refused)
    }
}

/// A reference, so the `@Sendable` recorder can append from the client's
/// detached task; a `Mutex` cannot be captured by value.
private final class RecordedDetails: Sendable {
    let lock = Mutex<[String]>([])
}

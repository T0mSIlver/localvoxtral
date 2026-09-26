import Foundation
import localvoxtralTestSupport
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

    /// herdr's own error answer says the write did not happen.
    func testAnErrorEnvelopeIsARefusal() async throws {
        let herdr = try FakeHerdrSocket { _ in .error("pane_not_found") }
        defer { herdr.stop() }

        let sent = await client.sendText(socketPath: herdr.socketPath, paneID: "w1:p9", text: "x")
        let pressed = await client.pressEnter(socketPath: herdr.socketPath, paneID: "w1:p9")

        XCTAssertEqual(sent, .refused)
        XCTAssertEqual(pressed, .refused)
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

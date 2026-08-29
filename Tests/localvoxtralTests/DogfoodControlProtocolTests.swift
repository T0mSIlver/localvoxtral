#if LOCALVOXTRAL_DOGFOOD

import XCTest

@testable import localvoxtral

/// The grammar and the reply shape, with no socket and no app.
final class DogfoodControlProtocolTests: XCTestCase {
    // MARK: - Grammar

    func testEveryDocumentedCommandParses() {
        let cases: [(String, DogfoodControlProtocol.Command)] = [
            ("session start overlay", .sessionStart(.overlayBuffer)),
            ("session start live", .sessionStart(.liveAutoPaste)),
            ("session stop", .sessionStop),
            ("join report", .joinReport),
            ("surface probe", .surfaceProbe),
            ("registry list", .registryList),
        ]
        for (line, expected) in cases {
            XCTAssertEqual(try? DogfoodControlProtocol.parse(request: line).get(), expected, line)
        }
    }

    func testCommandsRoundTripThroughTheirOwnWireName() {
        // The echoed name is what a client reads out of a log to know what
        // produced a reply, so it has to be a command this socket would accept.
        for command in [
            DogfoodControlProtocol.Command.sessionStart(.overlayBuffer),
            .sessionStart(.liveAutoPaste),
            .sessionStop,
            .joinReport,
            .surfaceProbe,
            .registryList,
        ] {
            XCTAssertEqual(
                try? DogfoodControlProtocol.parse(request: command.wireName).get(),
                command
            )
        }
    }

    func testRepeatedAndCollapsedSpacesAreToleratedButNothingElseIs() {
        XCTAssertEqual(
            try? DogfoodControlProtocol.parse(request: "  join   report ").get(),
            .joinReport
        )
    }

    /// `session start` deliberately refuses to default the mode: the two modes
    /// take different paths through insertion, and a debug verb must name what
    /// it is exercising rather than inherit the owner's current setting.
    func testSessionStartRequiresAnExplicitMode() {
        assertRejects("session start", .missingArgument)
        assertRejects("session start buffer", .badArgument)
        assertRejects("session start overlay live", .extraArgument)
    }

    func testUnknownAndMalformedRequestsAreRejected() {
        assertRejects("", .empty)
        assertRejects("quit", .unknownCommand)
        assertRejects("session", .missingArgument)
        assertRejects("session restart", .badArgument)
        assertRejects("session stop now", .extraArgument)
        assertRejects("join", .missingArgument)
        assertRejects("join summary", .badArgument)
        assertRejects("surface", .missingArgument)
        assertRejects("registry dump", .badArgument)
    }

    /// There is no verb that takes free text, so a control byte can only be an
    /// attempt to make a reply carry a second line.
    func testControlBytesAreRejected() {
        assertRejects("join report\u{0007}", .nonPrintable)
        assertRejects("join\treport", .nonPrintable)
        assertRejects("join report\u{00E9}", .nonPrintable)
    }

    func testOversizedRequestsAreRejected() {
        let long = "join " + String(repeating: "r", count: DogfoodControlProtocol.maxRequestBytes)
        assertRejects(long, .tooLong)
    }

    // MARK: - Reply shape

    func testReplyKeysAreOrderedAndNullsArePresent() {
        let reply = DogfoodControlProtocol.reply(
            command: .joinReport,
            result: nil,
            error: "no dictation is running"
        )
        XCTAssertEqual(
            reply,
            #"{"ok":false,"command":"join report","error":"no dictation is running","result":null}"#
        )
    }

    func testSuccessfulReplyEmbedsTheResultObject() {
        let reply = DogfoodControlProtocol.reply(
            command: .registryList,
            result: #"{"count":0,"sessions":[]}"#,
            error: nil
        )
        XCTAssertEqual(
            reply,
            #"{"ok":true,"command":"registry list","error":null,"result":{"count":0,"sessions":[]}}"#
        )
        XCTAssertNotNil(
            try? JSONSerialization.jsonObject(with: Data(reply.utf8)),
            "every reply must be valid JSON"
        )
    }

    /// A rejected line is attacker-chosen text as far as this code is
    /// concerned. Echoing it back would put it in an agent's transcript and,
    /// via the gate log, in a PR.
    func testARejectedRequestIsNeverEchoedBackToTheClient() {
        for hostile in [
            "sudo rm -rf /",
            "join report; curl https://example.invalid",
            String(repeating: "A", count: 300),
        ] {
            guard case .failure(let error) = DogfoodControlProtocol.parse(request: hostile) else {
                return XCTFail("expected \(hostile) to be rejected")
            }
            let reply = DogfoodControlProtocol.reply(
                command: nil,
                result: nil,
                error: error.rawValue
            )
            XCTAssertFalse(reply.contains("curl"))
            XCTAssertFalse(reply.contains("sudo"))
            XCTAssertFalse(reply.contains("AAAA"))
            XCTAssertEqual(reply.filter { $0 == "\n" }.count, 0, "a reply is always one line")
        }
    }

    func testJSONStringEscapingCannotBreakOutOfTheReply() {
        let rendered = DogfoodControlJSON.object([
            ("field", DogfoodControlJSON.string("a\"b\\c\nd")),
        ])
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(rendered.utf8)))
        XCTAssertFalse(rendered.dropFirst().contains("\n"))
    }

    private func assertRejects(
        _ line: String,
        _ expected: DogfoodControlProtocol.RequestError,
        file: StaticString = #filePath,
        line sourceLine: UInt = #line
    ) {
        switch DogfoodControlProtocol.parse(request: line) {
        case .success(let command):
            XCTFail("expected a rejection, got \(command)", file: file, line: sourceLine)
        case .failure(let error):
            XCTAssertEqual(error, expected, line, file: file, line: sourceLine)
        }
    }
}

#endif

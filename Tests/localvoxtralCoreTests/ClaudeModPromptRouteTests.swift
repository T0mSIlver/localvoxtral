import ClaudeContextWire
import Foundation
import Synchronization
import localvoxtralTestSupport
import XCTest
@testable import localvoxtralCore

@MainActor
final class ClaudeModPromptRouteTests: XCTestCase {
    /// A reply timer that never fires before the fake's reply cancels it.
    private static let neverTimesOut: @Sendable (Duration) async -> Void = { _ in
        try? await Task.sleep(for: .seconds(3600))
    }
    /// A reply timer that fires at once: the request goes unanswered.
    private static let timesOutAtOnce: @Sendable (Duration) async -> Void = { _ in }

    private func route(
        _ mod: FakeClaudeMod, sleep: @escaping @Sendable (Duration) async -> Void = neverTimesOut, keysReach: Bool = true
    ) async -> (ClaudeModPromptRoute?, ClaudeModChannelHub) {
        let hub = ClaudeModChannelHub(sleep: sleep)
        mod.attach(to: hub)
        let route = await ClaudeModPromptRoute.opened(hub: hub, sessionID: "s1", keysReachThePrompt: { keysReach })
        return (route, hub)
    }

    private func sink(
        _ route: ClaudeModPromptRoute, typed: @escaping @MainActor (String) -> Void,
        kept: @escaping @MainActor (String) -> Void
    ) -> AgentPromptSink {
        AgentPromptSink(route: route, kept: kept, fallback: typed)
    }

    func testDeltasFillInOrderAndTheStopsAckTypesNothing() async throws {
        let mod = FakeClaudeMod()
        let opened = await route(mod).0
        let route = try XCTUnwrap(opened)
        var typed: [String] = []
        var kept: [String] = []
        let sink = sink(route, typed: { typed.append($0) }, kept: { kept.append($0) })

        for delta in ["run ", "the ", "tests\n", "now"] { sink.append(delta) }
        sink.finish()
        await sink.waitUntilIdle()

        XCTAssertEqual(mod.box, "run the tests\nnow", "the newline is filled as text")
        XCTAssertEqual(mod.kinds, [.ack, .append, .append, .append, .append, .ack])
        XCTAssertEqual(typed, [])
        XCTAssertEqual(kept, [])
        XCTAssertTrue(sink.isHealthy)
    }

    func testWhatTheModDidNotFillIsTypedAtTheStopInOrder() async throws {
        let mod = FakeClaudeMod(refuses: "the ")
        let opened = await route(mod).0
        let route = try XCTUnwrap(opened)
        var typed: [String] = []
        let sink = sink(route, typed: { typed.append($0) }, kept: { _ in XCTFail("nothing kept") })

        for delta in ["run ", "the ", "tests"] { sink.append(delta) }
        sink.finish()
        await sink.waitUntilIdle()

        XCTAssertEqual(mod.box, "run ")
        XCTAssertEqual(typed, ["the ", "tests"])
    }

    func testWhatTheModDidNotFillIsKeptWhenKeysWouldGoElsewhere() async throws {
        let mod = FakeClaudeMod(refuses: "the ")
        let opened = await route(mod, keysReach: false).0
        let route = try XCTUnwrap(opened)
        var kept: [String] = []
        let sink = sink(route, typed: { _ in XCTFail("nothing typed") }, kept: { kept.append($0) })

        for delta in ["run ", "the ", "tests"] { sink.append(delta) }
        sink.finish()
        await sink.waitUntilIdle()

        XCTAssertEqual(kept, ["the ", "tests"])
    }

    /// The ack never comes back: any delta may be in the box, so none is
    /// typed.
    func testAnUnansweredAckKeepsEveryDeltaAndTypesNone() async throws {
        let silent = FakeClaudeMod(acksToAnswer: 0)
        let hub = ClaudeModChannelHub(sleep: Self.timesOutAtOnce)
        let attachment = try XCTUnwrap(silent.attach(to: hub))
        // As if opened while the mod still answered.
        let route = ClaudeModPromptRoute(hub: hub, sessionID: "s1", attachment: attachment, keysReachThePrompt: { true })
        var kept: [String] = []
        let sink = sink(route, typed: { _ in XCTFail("nothing typed") }, kept: { kept.append($0) })

        for delta in ["run ", "the ", "tests"] { sink.append(delta) }
        sink.finish()
        await sink.waitUntilIdle()

        XCTAssertEqual(silent.box, "run the tests")
        XCTAssertEqual(kept, ["run ", "the ", "tests"])
    }

    /// The channel closed mid-dictation: the deltas written before it may
    /// have landed, so they and the rest are kept, none typed.
    func testAChannelLostMidDictationKeepsWhatItMayHaveFilled() async throws {
        let mod = FakeClaudeMod()
        let (opened, hub) = await route(mod)
        let route = try XCTUnwrap(opened)
        var kept: [String] = []
        let sink = sink(route, typed: { _ in XCTFail("nothing typed") }, kept: { kept.append($0) })

        sink.append("run ")
        await sink.waitUntilIdle()
        hub.detach(sessionID: "s1", token: 1)
        XCTAssertFalse(hub.isAttached("s1"))
        sink.append("the tests")
        await sink.waitUntilIdle()

        XCTAssertEqual(kept, ["run ", "the tests"])
        XCTAssertFalse(sink.isHealthy)
    }

    /// The mod reloaded between the deltas and the stop and attached again
    /// under the same session: its new stream counts from zero, which says
    /// nothing about what the old one filled. Nothing is typed twice; every
    /// unconfirmed delta stays in History.
    func testAModThatReattachedMidDictationKeepsEveryUnconfirmedDelta() async throws {
        let mod = FakeClaudeMod()
        let hub = ClaudeModChannelHub(sleep: Self.neverTimesOut)
        let token = try XCTUnwrap(mod.attach(to: hub))
        let opened = await ClaudeModPromptRoute.opened(hub: hub, sessionID: "s1", keysReachThePrompt: { true })
        let route = try XCTUnwrap(opened)
        var kept: [String] = []
        let sink = sink(route, typed: { _ in XCTFail("nothing typed") }, kept: { kept.append($0) })

        sink.append("run ")
        sink.append("the ")
        await sink.waitUntilIdle()
        hub.detach(sessionID: "s1", token: token)
        let reloaded = FakeClaudeMod()
        reloaded.attach(to: hub)
        sink.append("tests")
        sink.finish()
        await sink.waitUntilIdle()

        XCTAssertEqual(mod.box, "run the ")
        XCTAssertEqual(kept, ["run ", "the ", "tests"])
        XCTAssertEqual(reloaded.kinds, [], "the new channel is never asked about the old stream")
    }

    func testAModOlderThanAppendOpensNoRoute() async {
        let (route, _) = await route(FakeClaudeMod(knowsAppend: false))
        XCTAssertNil(route)
    }

    func testAnUnansweredOpeningAckOpensNoRoute() async {
        let (route, _) = await route(FakeClaudeMod(acksToAnswer: 0), sleep: Self.timesOutAtOnce)
        XCTAssertNil(route)
    }

    /// A live spoken send: the ack confirms every delta, then the mod
    /// submits the box as it stands, and the next delta starts a new stream.
    func testASpokenSendSubmitsOnceTheAckConfirmsEveryDelta() async throws {
        let mod = FakeClaudeMod()
        let opened = await route(mod).0
        let route = try XCTUnwrap(opened)
        let sink = sink(route, typed: { _ in XCTFail("nothing typed") }, kept: { _ in XCTFail("nothing kept") })

        sink.append("run ")
        sink.append("the tests")
        sink.submit()
        sink.append("next")
        sink.finish()
        await sink.waitUntilIdle()

        XCTAssertEqual(mod.submitted, ["run the tests"])
        XCTAssertEqual(mod.box, "next")
        XCTAssertEqual(mod.kinds, [.ack, .append, .append, .ack, .send, .append, .ack])
    }

    func testASpokenSendTheModFellShortOfTypesTheRestAndSubmitsNothing() async throws {
        let mod = FakeClaudeMod(refuses: "the tests")
        let opened = await route(mod).0
        let route = try XCTUnwrap(opened)
        var typed: [String] = []
        let sink = sink(route, typed: { typed.append($0) }, kept: { _ in XCTFail("nothing kept") })

        sink.append("run ")
        sink.append("the tests")
        sink.submit()
        sink.append(" later")
        await sink.waitUntilIdle()

        XCTAssertEqual(mod.submitted, [])
        XCTAssertEqual(typed, ["the tests", " later"])
        XCTAssertFalse(mod.kinds.contains(.send))
    }
}

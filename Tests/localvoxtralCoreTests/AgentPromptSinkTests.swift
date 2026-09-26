import Foundation
import Synchronization
import XCTest
@testable import localvoxtralCore

/// A route that answers each call with the outcome `answer` picks and
/// records what it was asked.
private final class ScriptedRoute: AgentPromptRoute, @unchecked Sendable {
    private let answer: @Sendable (AgentPromptCall) -> AgentPromptDelivery
    private let received = Mutex<[AgentPromptCall]>([])

    init(answer: @escaping @Sendable (AgentPromptCall) -> AgentPromptDelivery) {
        self.answer = answer
    }

    var name: String { "scripted route" }
    var calls: [AgentPromptCall] { received.withLock { $0 } }

    func deliver(_ call: AgentPromptCall) async -> AgentPromptDelivery {
        received.withLock { $0.append(call) }
        return answer(call)
    }
}

@MainActor
final class AgentPromptSinkTests: XCTestCase {
    /// A route that cannot confirm its call and whose target is not where
    /// keys would land: that text and everything after it are typed
    /// nowhere, and the queued submit is dropped.
    func testKeepInHistoryTypesNothingForTheRestOfTheDictation() async {
        let route = ScriptedRoute { $0 == .append("second ") ? .keepInHistory : .delivered }
        var typed: [String] = []
        var kept: [String] = []
        let sink = AgentPromptSink(route: route, kept: { kept.append($0) }) { typed.append($0) }

        sink.append("first ")
        sink.append("second ")
        sink.append("third ")
        sink.submit()
        await sink.waitUntilIdle()
        sink.append("fourth") { typed.append("overlay: \($0)") }
        sink.submit()

        XCTAssertEqual(route.calls, [.append("first "), .append("second ")])
        XCTAssertEqual(kept, ["second ", "third ", "fourth"], "in order, the per-call fallback too")
        XCTAssertEqual(typed, [])
        XCTAssertFalse(sink.isHealthy)
    }

    /// `typeInstead` keeps #719's behaviour: the refused text and what
    /// follows are typed, nothing is kept.
    func testTypeInsteadTypesTheRefusedTextAndWhatFollows() async {
        let route = ScriptedRoute { _ in .typeInstead }
        var typed: [String] = []
        var kept: [String] = []
        let sink = AgentPromptSink(route: route, kept: { kept.append($0) }) { typed.append($0) }

        sink.append("hello ")
        sink.submit()
        await sink.waitUntilIdle()
        sink.append("world")

        XCTAssertEqual(route.calls, [.append("hello ")])
        XCTAssertEqual(typed, ["hello ", "world"])
        XCTAssertEqual(kept, [])
    }
}

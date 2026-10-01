import Foundation
import XCTest
@testable import localvoxtral

@MainActor
final class EarlyPolishRunTests: XCTestCase {
    private static let first =
        "one two three four five six seven eight nine ten eleven twelve thirteen fourteen "
        + "fifteen sixteen seventeen eighteen nineteen twenty twenty-one twenty-two twenty-three "
        + "twenty-four twenty-five twenty-six twenty-seven twenty-eight twenty-nine thirty."
    private static let second = first.replacingOccurrences(of: "one", with: "uno")

    private let templates = LLMPromptTemplates(
        systemContent: "system", userContent: "Working text:\n{{input_text}}\n")
    private let configuration = LLMPolishingConfiguration(
        endpointURL: URL(string: "http://127.0.0.1:8080/v1/chat/completions")!,
        apiKey: "",
        model: "polisher"
    )

    private func makeRun(
        _ polish: FakePolishingService,
        now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 0) },
        logFailure: @escaping EarlyPolishRun.LogFailure = EarlyPolishRun.logFailure
    ) -> EarlyPolishRun {
        let templates = templates
        return EarlyPolishRun(
            service: polish,
            configuration: configuration,
            templates: { templates },
            now: now,
            logFailure: logFailure
        )
    }

    /// The helper keeps generating a dropped request, so the stop waits for
    /// the piece in flight and keeps it rather than cancelling it.
    func testTheStopWaitsForThePieceInFlightAndKeepsIt() async {
        let polish = FakePolishingService { "<\($0.inputText)>" }
        await polish.holdNextRequest()
        let finishStarted = BoundedWait()
        let run = makeRun(polish, now: {
            finishStarted.resolve()
            return Date(timeIntervalSince1970: 0)
        })

        run.settledTextChanged("\(Self.first) and more")
        await polish.waitForRequests(1)
        let finishing = Task { await run.finish() }
        let started = await finishStarted.value(failAfter: 10)
        XCTAssertTrue(started)
        await polish.releaseHeldRequest()
        let handoff = await finishing.value

        XCTAssertEqual(handoff?.pieces.map(\.output), ["<\(Self.first)>"])
        XCTAssertEqual(handoff?.consumedPrefix, Self.first)
        XCTAssertEqual(handoff?.templates, templates)
    }

    /// One piece at a time: the next settled piece goes once the first answered.
    func testPiecesAreSentOneAtATime() async {
        let polish = FakePolishingService { "<\($0.inputText)>" }
        await polish.holdNextRequest()
        let run = makeRun(polish)

        run.settledTextChanged("\(Self.first) \(Self.second)")
        await polish.waitForRequests(1)
        run.settledTextChanged("\(Self.first) \(Self.second) tail")
        let whileHeld = await polish.requests.count
        XCTAssertEqual(whileHeld, 1)
        await polish.releaseHeldRequest()
        await polish.waitForRequests(2)
        let handoff = await run.finish()

        XCTAssertEqual(handoff?.pieces.map(\.input), [Self.first, Self.second])
        XCTAssertEqual(handoff?.consumedPrefix, "\(Self.first) \(Self.second)")
    }

    func testNoPieceStartsAfterTheStop() async {
        let polish = FakePolishingService()
        let run = makeRun(polish)

        run.close()
        run.settledTextChanged("\(Self.first) tail")
        let handoff = await run.finish()

        XCTAssertNil(handoff)
        let count = await polish.requests.count
        XCTAssertEqual(count, 0)
    }

    /// A polish backend's rejection can quote the request, so the dictated
    /// text: a failed piece logs only its status public (#1110).
    func testAFailedPieceLogsTheRejectionBodyOnlyInPrivate() async {
        let sentinel = "SENTINEL-sk-live-4f9a2c"
        let polish = FakePolishingService(failing: LLMPolishingError.requestFailed(
            statusCode: 400, body: #"{"error":"bad input: \#(sentinel)"}"#
        ))
        var logged: [(piece: Int, publicDetail: String, privateDetail: String)] = []
        let failureLogged = BoundedWait()
        let run = makeRun(polish, logFailure: { piece, publicDetail, privateDetail in
            logged.append((piece, publicDetail, privateDetail))
            failureLogged.resolve()
        })

        run.settledTextChanged("\(Self.first) and more")
        let didLog = await failureLogged.value(failAfter: 10)

        XCTAssertTrue(didLog)
        XCTAssertEqual(logged.map(\.piece), [0])
        XCTAssertEqual(logged.map(\.publicDetail), ["LLM request failed (HTTP 400)."])
        XCTAssertTrue(logged.allSatisfy { $0.privateDetail.contains(sentinel) })
    }
}

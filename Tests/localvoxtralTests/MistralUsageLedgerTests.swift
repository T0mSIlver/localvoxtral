import Foundation
import Synchronization
import XCTest
@testable import localvoxtral

/// The Mistral usage ledger: prices, the Settings summary, the JSON-lines file,
/// and the two request paths that write it (polish over HTTP, dictation over
/// the realtime socket). No network: the HTTP path is answered by a
/// URLProtocol stub on a reserved host, the socket path by the DEBUG seams.
final class MistralUsageLedgerTests: XCTestCase {
    // MARK: - Pricing

    func testPolishCostSplitsCachedPromptTokensAtATenthOfInput() throws {
        // 1M prompt tokens of which 100k cached, 1M completion tokens, on
        // Mistral Medium 3.5 (1.25 in / 6.4 out EUR per M).
        let cost = try XCTUnwrap(
            MistralPricing.polishCost(
                model: "mistral-medium-3-5",
                promptTokens: 1_000_000,
                cachedPromptTokens: 100_000,
                completionTokens: 1_000_000
            ))
        XCTAssertEqual(cost, 0.9 * 1.25 + 0.1 * 0.125 + 6.4, accuracy: 1e-9)
    }

    func testAliasesArePricedLikeTheirModel() {
        for alias in ["mistral-medium-latest", "mistral-medium-2604", "Mistral-Medium-3-5 "] {
            XCTAssertEqual(
                MistralPricing.price(for: alias), MistralPricing.price(for: "mistral-medium-3-5"),
                alias)
        }
    }

    func testGLMUsesItsPublishedCachedRate() throws {
        let cost = try XCTUnwrap(
            MistralPricing.polishCost(
                model: "zai-glm-5-3",
                promptTokens: 1_000_000,
                cachedPromptTokens: 1_000_000,
                completionTokens: 0
            ))
        XCTAssertEqual(cost, 0.119, accuracy: 1e-9)
    }

    func testUnknownModelHasNoPrice() {
        XCTAssertNil(MistralPricing.price(for: "some-future-model"))
        XCTAssertNil(
            MistralPricing.polishCost(
                model: "some-future-model", promptTokens: 10, cachedPromptTokens: 0,
                completionTokens: 10))
        XCTAssertNil(MistralPricing.dictationCost(model: "some-future-model", audioSeconds: 60))
    }

    func testDictationIsPricedPerMinuteOfAudio() throws {
        let cost = try XCTUnwrap(
            MistralPricing.dictationCost(
                model: MistralRealtimeWebSocketClient.defaultModel, audioSeconds: 90))
        XCTAssertEqual(cost, 1.5 * 0.0053, accuracy: 1e-12)
        // A chat model has no audio price, so it cannot price a dictation.
        XCTAssertNil(MistralPricing.dictationCost(model: "mistral-medium-3-5", audioSeconds: 90))
    }

    // MARK: - Summary

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        return calendar
    }

    /// 2026-09-18 15:00 Paris.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 18, hour: 15))!
    }

    private func daysAgo(_ days: Int, hour: Int = 10) -> Date {
        let day = calendar.date(byAdding: .day, value: -days, to: now)!
        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
    }

    func testPeriodStartsAreLocalMidnightsCountingToday() {
        let midnight = calendar.startOfDay(for: now)
        XCTAssertEqual(MistralUsagePeriod.today.start(now: now, calendar: calendar), midnight)
        XCTAssertEqual(
            MistralUsagePeriod.sevenDays.start(now: now, calendar: calendar),
            calendar.date(byAdding: .day, value: -6, to: midnight))
        XCTAssertEqual(
            MistralUsagePeriod.thirtyDays.start(now: now, calendar: calendar),
            calendar.date(byAdding: .day, value: -29, to: midnight))
        XCTAssertEqual(
            MistralUsagePeriod.ninetyDays.start(now: now, calendar: calendar),
            calendar.date(byAdding: .day, value: -89, to: midnight))
        XCTAssertNil(MistralUsagePeriod.allTime.start(now: now, calendar: calendar))
    }

    func testSummaryCountsOnlyEntriesInsideTheWindow() {
        let entries = [
            MistralUsageEntry(
                date: daysAgo(0), kind: .dictation, model: "m", audioSeconds: 120, costEUR: 0.01),
            MistralUsageEntry(
                date: daysAgo(0, hour: 0), kind: .polish, model: "m", promptTokens: 10,
                completionTokens: 5, costEUR: 0.02),
            MistralUsageEntry(
                date: daysAgo(6), kind: .polish, model: "m", promptTokens: 10,
                completionTokens: 5, costEUR: 0.04),
            MistralUsageEntry(date: daysAgo(7), kind: .polish, model: "unknown"),
            MistralUsageEntry(
                date: daysAgo(200), kind: .dictation, model: "m", audioSeconds: 60, costEUR: 1),
        ]
        let start = { (period: MistralUsagePeriod) in period.start(now: self.now, calendar: self.calendar) }

        let today = MistralUsageSummary(entries: entries, since: start(.today))
        XCTAssertEqual(today.dictationCount, 1)
        XCTAssertEqual(today.polishCount, 1)
        XCTAssertEqual(today.audioSeconds, 120)
        XCTAssertEqual(today.costEUR, 0.03, accuracy: 1e-12)
        XCTAssertEqual(today.unpricedCount, 0)

        let week = MistralUsageSummary(entries: entries, since: start(.sevenDays))
        XCTAssertEqual(week.polishCount, 2)
        XCTAssertEqual(week.costEUR, 0.07, accuracy: 1e-12)

        let month = MistralUsageSummary(entries: entries, since: start(.thirtyDays))
        XCTAssertEqual(month.polishCount, 3)
        XCTAssertEqual(month.unpricedCount, 1)
        XCTAssertEqual(month.costEUR, 0.07, accuracy: 1e-12)

        let all = MistralUsageSummary(entries: entries, since: start(.allTime))
        XCTAssertEqual(all.dictationCount, 2)
        XCTAssertEqual(all.audioSeconds, 180)
        XCTAssertEqual(all.costEUR, 1.07, accuracy: 1e-12)
    }

    func testSummaryLine() {
        XCTAssertEqual(MistralUsageSummary().line, "No Mistral requests")
        XCTAssertNil(MistralUsageSummary().unpricedNote)

        var summary = MistralUsageSummary()
        summary.costEUR = 0.4249
        summary.dictationCount = 3
        summary.audioSeconds = 38 * 60 + 10
        summary.polishCount = 112
        XCTAssertEqual(summary.line, "€0.42 · 38 min dictated · 112 polishes")

        summary.polishCount = 1
        summary.dictationCount = 0
        summary.costEUR = 0.004
        XCTAssertEqual(summary.line, "< €0.01 · 1 polish")

        summary.unpricedCount = 2
        XCTAssertEqual(summary.unpricedNote, "2 requests have no price and are not in the total")
    }

    func testDurationFormatting() {
        XCTAssertEqual(MistralUsageSummary.formattedDuration(42), "42 s")
        XCTAssertEqual(MistralUsageSummary.formattedDuration(59.6 * 60), "60 min")
        XCTAssertEqual(MistralUsageSummary.formattedDuration(120 * 60), "2 h")
        XCTAssertEqual(MistralUsageSummary.formattedDuration(125 * 60), "2 h 5 min")
    }

    // MARK: - File

    private func temporaryLedgerURL() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MistralUsageLedgerTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        // A directory that does not exist yet: the first write creates it.
        return directory.appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("mistral-usage.jsonl")
    }

    func testLedgerPersistsEntriesAcrossInstances() {
        let url = temporaryLedgerURL()
        let first = MistralUsageEntry(
            date: Date(timeIntervalSince1970: 1_800_000_000), kind: .dictation, model: "m",
            audioSeconds: 12.5, costEUR: 0.001)
        let second = MistralUsageEntry(
            date: Date(timeIntervalSince1970: 1_800_000_100), kind: .polish, model: "p",
            promptTokens: 100, cachedPromptTokens: 20, completionTokens: 30)

        let writer = MistralUsageLedger(fileURL: url)
        writer.record(first)
        writer.record(second)
        writer.flushForTesting()

        XCTAssertEqual(MistralUsageLedger(fileURL: url).entries(), [first, second])
    }

    func testLedgerSkipsAnUnreadableLine() throws {
        let entry = MistralUsageEntry(
            date: Date(timeIntervalSince1970: 1_800_000_000), kind: .polish, model: "p")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(entry)
        data.append(Data("\n{\"date\":\"torn".utf8))
        data.append(Data("\n".utf8))
        data.append(try encoder.encode(entry))

        XCTAssertEqual(MistralUsageLedger.entries(fromFileContents: data), [entry, entry])
    }

    func testLedgerNotifiesOnEveryRecord() {
        let count = LockedCounter()
        let ledger = MistralUsageLedger(fileURL: nil) { count.increment() }
        ledger.record(MistralUsageEntry(date: Date(), kind: .polish, model: "p"))
        ledger.record(MistralUsageEntry(date: Date(), kind: .polish, model: "p"))
        XCTAssertEqual(count.value, 2)
        XCTAssertEqual(ledger.entries().count, 2)
    }

    // MARK: - Polish requests

    private func polishConfiguration(
        shape: LLMPolishingRequestShape = .mistral,
        model: String = "mistral-medium-latest"
    ) -> LLMPolishingConfiguration {
        LLMPolishingConfiguration(
            endpointURL: URL(string: "https://\(UsageStubProtocol.host)")!,
            apiKey: "k",
            model: model,
            requestShape: shape
        )
    }

    private let polishRequest = LLMPolishingRequest(
        inputText: "hello", systemPrompt: "s", userPrompts: ["u"])

    private func withStub<T>(_ reply: UsageStubProtocol.Reply, _ body: () async throws -> T)
        async rethrows -> T
    {
        UsageStubProtocol.reply.withLock { $0 = reply }
        URLProtocol.registerClass(UsageStubProtocol.self)
        defer { URLProtocol.unregisterClass(UsageStubProtocol.self) }
        return try await body()
    }

    private static let successBody = """
        {"model":"mistral-medium-3-5","choices":[{"message":{"role":"assistant","content":"Hello."}}],
         "usage":{"prompt_tokens":1000,"completion_tokens":200,"total_tokens":1200,
                  "prompt_tokens_details":{"cached_tokens":400}}}
        """

    func testMistralPolishRecordsTheUsageTheResponseReports() async throws {
        let ledger = MistralUsageLedger(fileURL: nil)
        let service = LLMPolishingService(usageRecorder: ledger)

        let result = try await withStub(.http(200, Self.successBody)) {
            try await service.polish(request: polishRequest, configuration: polishConfiguration())
        }

        XCTAssertEqual(result.polishedText, "Hello.")
        let entry = try XCTUnwrap(ledger.entries().first)
        XCTAssertEqual(ledger.entries().count, 1)
        XCTAssertEqual(entry.kind, .polish)
        // The answering model, not the alias that was asked for.
        XCTAssertEqual(entry.model, "mistral-medium-3-5")
        XCTAssertEqual(entry.promptTokens, 1000)
        XCTAssertEqual(entry.cachedPromptTokens, 400)
        XCTAssertEqual(entry.completionTokens, 200)
        let expected: Double = (750 + 50 + 1280) / 1_000_000.0  // 600×1.25 + 400×0.125 + 200×6.4
        XCTAssertEqual(try XCTUnwrap(entry.costEUR), expected, accuracy: 1e-12)
    }

    func testMistralPolishWithUnusableContentIsStillRecorded() async throws {
        let ledger = MistralUsageLedger(fileURL: nil)
        let service = LLMPolishingService(usageRecorder: ledger)
        let body = #"{"choices":[{"message":{"content":"  "}}],"usage":{"prompt_tokens":10,"completion_tokens":1}}"#

        await withStub(.http(200, body)) {
            do {
                _ = try await service.polish(
                    request: polishRequest, configuration: polishConfiguration())
                XCTFail("An empty answer must still fail the polish")
            } catch {}
        }

        XCTAssertEqual(ledger.entries().map(\.promptTokens), [10])
        XCTAssertEqual(ledger.entries().first?.model, "mistral-medium-latest")
    }

    func testMistralPolishTimeoutIsRecordedUnpriced() async throws {
        let ledger = MistralUsageLedger(fileURL: nil)
        let service = LLMPolishingService(usageRecorder: ledger)

        await withStub(.failure(URLError(.timedOut))) {
            do {
                _ = try await service.polish(
                    request: polishRequest, configuration: polishConfiguration())
                XCTFail("Expected a timeout")
            } catch LLMPolishingError.timedOut {
            } catch {
                XCTFail("Expected a timeout, got \(error)")
            }
        }

        XCTAssertEqual(ledger.entries().count, 1)
        XCTAssertNil(ledger.entries().first?.costEUR)
        XCTAssertNil(ledger.entries().first?.promptTokens)
    }

    func testRejectedAndUnreachablePolishesAreNotRecorded() async {
        let ledger = MistralUsageLedger(fileURL: nil)
        let service = LLMPolishingService(usageRecorder: ledger)

        for reply in [
            UsageStubProtocol.Reply.http(401, #"{"message":"Unauthorized"}"#),
            .failure(URLError(.cannotConnectToHost)),
        ] {
            await withStub(reply) {
                _ = try? await service.polish(
                    request: polishRequest, configuration: polishConfiguration())
            }
        }

        XCTAssertTrue(ledger.entries().isEmpty)
    }

    func testSelfHostedPolishIsNeverRecorded() async throws {
        let ledger = MistralUsageLedger(fileURL: nil)
        let service = LLMPolishingService(usageRecorder: ledger)

        _ = try await withStub(.http(200, Self.successBody)) {
            try await service.polish(
                request: polishRequest,
                configuration: polishConfiguration(shape: .openAICompatible))
        }

        XCTAssertTrue(ledger.entries().isEmpty)
    }

    func testTokenUsageParsing() {
        XCTAssertNil(LLMTokenUsage(responseObject: ["choices": []]))
        XCTAssertNil(LLMTokenUsage(responseObject: ["usage": ["prompt_tokens": 1]]))
        XCTAssertEqual(
            LLMTokenUsage(responseObject: [
                "model": "", "usage": ["prompt_tokens": 3, "completion_tokens": 4],
            ]),
            LLMTokenUsage(model: nil, promptTokens: 3, completionTokens: 4))
    }
}

#if DEBUG
extension MistralUsageLedgerTests {
    // MARK: - Dictation sockets

    private func makePrimedClient(sessionCreated: Bool)
        -> (MistralRealtimeWebSocketClient, MistralUsageLedger, () -> Void)
    {
        let client = MistralRealtimeWebSocketClient()
        let ledger = MistralUsageLedger(fileURL: nil)
        client.setUsageRecorder(ledger)
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: URL(string: "ws://127.0.0.1:65535/test")!)
        client.debugPrimeConnectedStateForTesting(
            task: task,
            isUserInitiatedDisconnect: true,
            hasReceivedSessionCreated: sessionCreated,
            usageModel: MistralRealtimeWebSocketClient.defaultModel
        )
        return (client, ledger, {
            task.cancel()
            session.invalidateAndCancel()
        })
    }

    /// One second of 16 kHz mono S16 PCM.
    private var oneSecond: Data { Data(count: 32_000) }

    func testSocketRecordsTheAudioItSentOnceWhenItCloses() throws {
        let (client, ledger, cleanup) = makePrimedClient(sessionCreated: true)
        defer { cleanup() }

        client.sendAudioChunk(oneSecond)
        client.sendAudioChunk(oneSecond)
        client.disconnect()
        client.disconnect()

        XCTAssertEqual(ledger.entries().count, 1)
        let entry = try XCTUnwrap(ledger.entries().first)
        XCTAssertEqual(entry.kind, .dictation)
        XCTAssertEqual(entry.model, MistralRealtimeWebSocketClient.defaultModel)
        XCTAssertEqual(entry.audioSeconds, 2)
        XCTAssertEqual(try XCTUnwrap(entry.costEUR), 2.0 / 60 * 0.0053, accuracy: 1e-12)
    }

    func testAudioQueuedBeforeTheSessionOpenedIsNotCounted() {
        let (client, ledger, cleanup) = makePrimedClient(sessionCreated: false)
        defer { cleanup() }

        client.sendAudioChunk(oneSecond)
        client.disconnect()

        XCTAssertTrue(ledger.entries().isEmpty)
    }

    func testQueuedAudioCountsOnceTheSessionOpens() {
        let (client, ledger, cleanup) = makePrimedClient(sessionCreated: false)
        defer { cleanup() }

        client.sendAudioChunk(oneSecond)
        client.handle(json: ["type": "session.created", "session": ["model": "m"]])
        client.sendAudioChunk(oneSecond)
        client.disconnect()

        XCTAssertEqual(ledger.entries().map(\.audioSeconds), [2])
    }

    func testSocketFailureRecordsTheAudioSentBeforeIt() {
        let client = MistralRealtimeWebSocketClient()
        let ledger = MistralUsageLedger(fileURL: nil)
        client.setUsageRecorder(ledger)
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: URL(string: "ws://127.0.0.1:65535/test")!)
        defer {
            task.cancel()
            session.invalidateAndCancel()
        }
        client.debugPrimeConnectedStateForTesting(
            task: task, isUserInitiatedDisconnect: true, hasReceivedSessionCreated: true,
            usageModel: MistralRealtimeWebSocketClient.defaultModel)

        client.sendAudioChunk(oneSecond)
        client.debugHandleTerminalSocketErrorForTesting(task: task, errorMessage: "boom")
        client.disconnect()

        XCTAssertEqual(ledger.entries().map(\.audioSeconds), [1])
    }
}
#endif

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

/// Answers requests to one reserved host with a canned reply; every other
/// request passes through untouched.
private final class UsageStubProtocol: URLProtocol, @unchecked Sendable {
    enum Reply: Sendable {
        case http(Int, String)
        case failure(URLError)
    }

    static let host = "mistral-usage-stub.invalid"
    static let reply = Mutex<Reply>(.http(500, ""))

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == host
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        switch Self.reply.withLock({ $0 }) {
        case .http(let status, let body):
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

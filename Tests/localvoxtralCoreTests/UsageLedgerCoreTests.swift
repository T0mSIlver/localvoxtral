import Foundation
import XCTest
import localvoxtralTestSupport
@testable import localvoxtralCore

/// The usage ledger's record of every model call, by feature and backend
/// (#837): the line format old and new builds share, the two summaries, and
/// the quick-capture routers that write it. The other writers are tested
/// beside their own suites.
final class UsageLedgerCoreTests: XCTestCase {
    private let moment = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Line format

    func testALineFromBeforeFeaturesReadsAsTheMistralRequestItWas() throws {
        let data = Data(
            """
            {"costEUR":0.001,"date":"2027-01-15T08:00:00Z","kind":"polish","model":"zai-glm-5-3","promptTokens":900,"cachedPromptTokens":800,"completionTokens":40}
            {"audioSeconds":12.5,"costEUR":0.0005,"date":"2027-01-15T08:00:00Z","kind":"retranscription","model":"voxtral-mini-latest"}
            {"audioSeconds":12.5,"costEUR":0.001,"date":"2027-01-15T08:00:00Z","kind":"dictation","model":"voxtral-mini-transcribe-realtime-2602"}
            """.utf8)

        let entries = UsageLedger.entries(fromFileContents: data)

        XCTAssertEqual(entries.map(\.feature), [.polish, .secondPass, .dictation])
        XCTAssertEqual(entries.map(\.backend), [.mistral, .mistral, .mistral])
        XCTAssertEqual(entries.first?.promptTokens, 900)
        XCTAssertEqual(entries.first?.cachedPromptTokens, 800)
        XCTAssertEqual(entries[1].audioSeconds, 12.5)
        let summary = MistralUsageSummary(entries: entries, since: nil)
        XCTAssertEqual(summary.polishCount, 1)
        XCTAssertEqual(summary.retranscriptionCount, 1)
        XCTAssertEqual(summary.dictationCount, 1)
        XCTAssertEqual(summary.costEUR, 0.0025, accuracy: 1e-12)
    }

    func testEveryFeatureAndBackendRoundTrips() {
        let entries = UsageEntry.Feature.allCases.flatMap { feature in
            UsageEntry.Backend.allCases.map { backend in
                UsageEntry(
                    date: moment, feature: feature, backend: backend, model: "m",
                    audioSeconds: 1.5, promptTokens: 10, cachedPromptTokens: 4, completionTokens: 2,
                    costEUR: 0.01, agentCostUSD: 0.02)
            }
        }
        let ledger = UsageLedger(fileURL: temporaryFile())
        entries.forEach(ledger.record)

        XCTAssertEqual(UsageLedger(fileURL: ledger.fileURL).entries(), entries)
    }

    /// Two running copies of the app append at once (#990): every entry of
    /// both is on its own line, none written over another.
    func testTwoCopiesAppendingAtOnceKeepEveryEntry() throws {
        let fileURL = temporaryFile()
        let copies = [UsageLedger(fileURL: fileURL), UsageLedger(fileURL: fileURL)]
        let count = 400
        let moment = moment
        DispatchQueue.concurrentPerform(iterations: count) { index in
            copies[index % 2].record(UsageEntry(
                date: moment, feature: .polish, backend: .mistral, model: "m\(index)", costEUR: 0.001))
        }

        let entries = UsageLedger.entries(fromFileContents: try Data(contentsOf: fileURL))
        XCTAssertEqual(entries.count, count)
        XCTAssertEqual(Set(entries.map(\.model)).count, count)
    }

    /// Another running copy recorded a request after this one loaded: the
    /// usage views show it when they appear, not only after a relaunch
    /// (#1126).
    func testAppearingShowsEntriesAnotherCopyAppendedSinceThisOneLoaded() async throws {
        let fileURL = temporaryFile()
        let installed = UsageLedger(fileURL: fileURL)
        let tryBuild = UsageLedger(fileURL: fileURL)
        installed.record(UsageEntry(date: moment, feature: .polish, backend: .mistral, model: "mine", costEUR: 0.001))
        tryBuild.record(UsageEntry(date: moment, feature: .polish, backend: .mistral, model: "theirs", costEUR: 0.001))

        await installed.reloadIfChanged()

        XCTAssertEqual(installed.entries().map(\.model), ["mine", "theirs"])
    }

    /// A crash mid-append left a line with no end. The next entry starts a
    /// line of its own instead of joining it and going unread (#990).
    func testAnEntryAfterATornLastLineIsKept() throws {
        let fileURL = temporaryFile()
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let whole = UsageEntry(date: moment, feature: .polish, backend: .mistral, model: "whole", costEUR: 0.001)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var torn = try encoder.encode(whole) + Data("\n".utf8)
        torn += Data(#"{"costEUR":0.001,"date":"2027-01-"#.utf8)
        try torn.write(to: fileURL)

        let next = UsageEntry(date: moment, feature: .polish, backend: .mistral, model: "next", costEUR: 0.001)
        UsageLedger(fileURL: fileURL).record(next)

        let entries = UsageLedger.entries(fromFileContents: try Data(contentsOf: fileURL))
        XCTAssertEqual(entries.map(\.model), ["whole", "next"])
    }

    /// An older build reads `kind` alone. It must go on seeing the Mistral
    /// requests it always summed, chat features as polishes as before, and
    /// never mistake a free local call or an agent run for Mistral spend.
    func testALineCarriesTheKindAnOlderBuildWouldHaveWritten() throws {
        let cases: [(UsageEntry.Feature, UsageEntry.Backend, String?)] = [
            (.dictation, .mistral, "dictation"),
            (.secondPass, .mistral, "retranscription"),
            (.polish, .mistral, "polish"),
            (.termSuggestions, .mistral, "polish"),
            (.quickCaptureRouting, .mistral, "polish"),
            (.quickCapturePolish, .mistral, "polish"),
            (.polish, .bundledHelper, nil),
            (.termSuggestions, .userServer, nil),
            (.quickCaptureRouting, .jev, nil),
            (.projectTerms, .claudeCode, nil),
            (.quickCaptureDrafting, .vibe, nil),
        ]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        for (feature, backend, kind) in cases {
            let entry = UsageEntry(date: moment, feature: feature, backend: backend, model: "m")
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: encoder.encode(entry)) as? [String: Any])
            XCTAssertEqual(object["kind"] as? String, kind, "\(feature) on \(backend)")
        }
    }

    func testALineFromANewerBuildIsSkippedNotFatal() {
        let data = Data(
            """
            {"backend":"mistral","date":"2027-01-15T08:00:00Z","feature":"somethingNew","model":"m"}
            {"backend":"jev","date":"2027-01-15T08:00:00Z","feature":"quickCaptureRouting","model":"jev-latest"}
            """.utf8)

        XCTAssertEqual(
            UsageLedger.entries(fromFileContents: data).map(\.backend), [.jev])
    }

    // MARK: - Entries

    func testAChatCallIsPricedOnlyOnMistral() {
        let usage = LLMTokenUsage(model: "zai-glm-5-3", promptTokens: 1_000, cachedPromptTokens: 0, completionTokens: 100)
        let mistral = UsageEntry.chat(
            date: moment, feature: .termSuggestions, backend: .mistral, requestedModel: "zai-glm-5-3", usage: usage)
        let local = UsageEntry.chat(
            date: moment, feature: .termSuggestions, backend: .userServer, requestedModel: "zai-glm-5-3", usage: usage)

        XCTAssertEqual(mistral.costEUR ?? 0, (1_000 * 1.19 + 100 * 3.74) / 1_000_000, accuracy: 1e-12)
        XCTAssertNil(local.costEUR, "a model name is not a bill")
        XCTAssertEqual(local.promptTokens, 1_000)
        XCTAssertEqual(local.completionTokens, 100)
    }

    func testAnAgentRunSumsItsPromptTokensAndKeepsItsReportedPrice() {
        let usage = ProjectTermProposal.Usage(
            turns: 6, costUSD: 0.07, inputTokens: 6, cacheWriteTokens: 12_000, cacheReadTokens: 22_000,
            outputTokens: 1_700)

        let entry = UsageEntry.agentRun(date: moment, feature: .quickCaptureDrafting, agent: .claude, usage: usage)
        let unreported = UsageEntry.agentRun(date: moment, feature: .projectTerms, agent: .opencode, usage: nil)

        XCTAssertEqual(
            entry,
            UsageEntry(
                date: moment, feature: .quickCaptureDrafting, backend: .claudeCode, model: "sonnet",
                promptTokens: 34_006, cachedPromptTokens: 22_000, completionTokens: 1_700, agentCostUSD: 0.07))
        XCTAssertEqual(
            unreported, UsageEntry(date: moment, feature: .projectTerms, backend: .opencode, model: "default"))
    }

    // MARK: - Summaries

    func testTheMistralSummaryCountsOnlyMistralAndKeepsPolishesApart() {
        let entries = [
            UsageEntry(date: moment, feature: .polish, backend: .mistral, model: "m", costEUR: 0.001),
            UsageEntry(date: moment, feature: .termSuggestions, backend: .mistral, model: "m", costEUR: 0.08),
            UsageEntry(date: moment, feature: .quickCaptureRouting, backend: .mistral, model: "m"),
            UsageEntry(date: moment, feature: .polish, backend: .bundledHelper, model: "m", promptTokens: 900),
            UsageEntry(date: moment, feature: .quickCaptureRouting, backend: .jev, model: "jev-latest"),
            UsageEntry(date: moment, feature: .quickCaptureDrafting, backend: .claudeCode, model: "sonnet", agentCostUSD: 0.1),
        ]

        let summary = MistralUsageSummary(entries: entries, since: nil)

        XCTAssertEqual(summary.polishCount, 1)
        XCTAssertEqual(summary.otherCount, 2)
        XCTAssertEqual(summary.unpricedCount, 1)
        XCTAssertEqual(summary.costEUR, 0.081, accuracy: 1e-12)
        XCTAssertEqual(summary.line, "€0.08 + 1 unpriced · 1 polish")
    }

    func testTheFeatureSummarySumsEachFeatureAcrossItsBackends() {
        let older = moment.addingTimeInterval(-86_400)
        let entries = [
            UsageEntry(date: older, feature: .polish, backend: .mistral, model: "m", promptTokens: 5, costEUR: 1),
            UsageEntry(date: moment, feature: .polish, backend: .mistral, model: "m",
                       promptTokens: 900, completionTokens: 40, costEUR: 0.001),
            UsageEntry(date: moment, feature: .polish, backend: .bundledHelper, model: "m",
                       promptTokens: 1_000, completionTokens: 60),
            UsageEntry(date: moment, feature: .quickCaptureRouting, backend: .jev, model: "jev-latest"),
            UsageEntry(date: moment, feature: .quickCaptureRouting, backend: .mistral, model: "m",
                       promptTokens: 1_356, completionTokens: 57, costEUR: 0.0006),
            UsageEntry(date: moment, feature: .quickCaptureDrafting, backend: .claudeCode, model: "sonnet",
                       promptTokens: 71_000, completionTokens: 1_900, agentCostUSD: 0.1),
            UsageEntry(date: moment, feature: .quickCaptureDrafting, backend: .vibe, model: "default"),
            UsageEntry(date: moment, feature: .secondPass, backend: .mistral, model: "voxtral-mini-latest",
                       audioSeconds: 37, costEUR: 0.0016),
        ]

        let rows = FeatureUsage.summarize(entries, since: moment)

        XCTAssertEqual(rows.map(\.feature), [.polish, .secondPass, .quickCaptureRouting, .quickCaptureDrafting])
        let polish = rows[0]
        XCTAssertEqual(polish.calls, 2)
        XCTAssertEqual(polish.promptTokens, 1_900)
        XCTAssertEqual(polish.completionTokens, 100)
        XCTAssertEqual(polish.costEUR, 0.001, accuracy: 1e-12)
        XCTAssertEqual(polish.backends.mapValues(\.calls), [.mistral: 1, .bundledHelper: 1])
        XCTAssertEqual(polish.unpricedPaidCalls, 0, "the bundled helper is free, not unpriced")
        XCTAssertEqual(rows[1].audioSeconds, 37)
        XCTAssertEqual(rows[2].backends.mapValues(\.calls), [.jev: 1, .mistral: 1])
        XCTAssertEqual(rows[2].unpricedPaidCalls, 1, "Jev reports nothing to price")
        XCTAssertEqual(rows[3].agentCostUSD, 0.1, accuracy: 1e-12)
        XCTAssertEqual(rows[3].unpricedPaidCalls, 1, "Vibe reports nothing")
        XCTAssertEqual(FeatureUsage.summarize(entries, since: nil).first?.calls, 3)
    }

    /// The Insights row says who paid what: EUR on the Mistral key, free for
    /// local calls, USD for agent runs, and a count where nothing was priced.
    func testTheFeatureLineSaysWhoPaidWhat() {
        let english = Locale(identifier: "en_US")
        func line(_ entries: [UsageEntry]) -> String? {
            FeatureUsage.summarize(entries, since: nil).first?.line(locale: english)
        }
        func entry(
            _ feature: UsageEntry.Feature, _ backend: UsageEntry.Backend, audioSeconds: Double? = nil,
            eur: Double? = nil, usd: Double? = nil
        ) -> UsageEntry {
            UsageEntry(date: moment, feature: feature, backend: backend, model: "m",
                       audioSeconds: audioSeconds, costEUR: eur, agentCostUSD: usd)
        }

        XCTAssertEqual(
            line([entry(.dictation, .mistral, audioSeconds: 1_800, eur: 0.16),
                  entry(.dictation, .mistral, audioSeconds: 1_200, eur: 0.1)]),
            "2 · 50 min · €0.26")
        XCTAssertEqual(
            line([entry(.polish, .mistral, eur: 0.62), entry(.polish, .bundledHelper),
                  entry(.polish, .userServer)]),
            "3 · €0.62 · 2 free on this Mac")
        XCTAssertEqual(
            line([entry(.polish, .mistral, eur: 0.4), entry(.polish, .mistral)]),
            "2 · €0.40 + 1 unpriced", "a timed-out polish is not free")
        XCTAssertEqual(line([entry(.polish, .mistral)]), "1 · 1 on Mistral (unpriced)")
        XCTAssertEqual(
            line([entry(.quickCaptureRouting, .jev), entry(.quickCaptureRouting, .mistral, eur: 0.0006)]),
            "2 · < €0.01 · 1 on Jev (unpriced)")
        XCTAssertEqual(
            line([entry(.quickCaptureDrafting, .claudeCode, usd: 0.099),
                  entry(.quickCaptureDrafting, .claudeCode, usd: 14.8),
                  entry(.quickCaptureDrafting, .vibe)]),
            "3 · $14.90 of Claude usage · 1 on Vibe (unpriced)")
        XCTAssertEqual(
            line(Array(repeating: entry(.projectTerms, .claudeCode, usd: 0.001), count: 1_200)),
            "1,200 · $1.20 of Claude usage", "counts group digits")
    }

    // MARK: - Quick-capture routing

    private static let options = [
        QuickCaptureOption(id: "quill", projectKey: "/w/quill", description: "Project quill."),
        QuickCaptureOption(id: QuickCaptureRouting.catchAllID, projectKey: nil, description: "Anything else."),
    ]

    func testTheChatRouterRecordsEveryAnswerWithItsUsage() async throws {
        let ledger = UsageLedger(fileURL: nil)
        let classifier = QuickCaptureChatClassifier(
            endpoint: URL(string: "https://\(StubHTTPProtocol.host)/v1/chat/completions")!,
            apiKey: "k", model: "zai-glm-5-3", session: StubHTTPProtocol.session(),
            usageBackend: .mistral, usageRecorder: ledger, now: { [moment] in moment })

        StubHTTPProtocol.reply.withLock {
            $0 = .http(200, #"""
                {"model":"zai-glm-5-3","choices":[{"message":{"content":"{\"project\":\"quill\",\"confidence\":0.9}"}}],
                 "usage":{"prompt_tokens":1356,"completion_tokens":57,"prompt_tokens_details":{"cached_tokens":1216}}}
                """#)
        }
        _ = try await classifier.classify(capture: "c", options: Self.options)
        // Billed even though the answer is unusable.
        StubHTTPProtocol.reply.withLock { $0 = .http(200, #"{"choices":[]}"#) }
        _ = try? await classifier.classify(capture: "c", options: Self.options)
        StubHTTPProtocol.reply.withLock { $0 = .http(429, "{}") }
        _ = try? await classifier.classify(capture: "c", options: Self.options)

        let entries = ledger.entries()
        XCTAssertEqual(entries.count, 2, "a refusal is not recorded")
        XCTAssertEqual(entries.map(\.feature), [.quickCaptureRouting, .quickCaptureRouting])
        XCTAssertEqual(entries.first?.promptTokens, 1_356)
        XCTAssertEqual(entries.first?.cachedPromptTokens, 1_216)
        XCTAssertEqual(entries.first?.completionTokens, 57)
        XCTAssertNotNil(entries.first?.costEUR)
        XCTAssertNil(entries.last?.costEUR, "no usage, unpriced")
    }

    func testJevRecordsEachAnsweredCallButNotItsRetries() async throws {
        let ledger = UsageLedger(fileURL: nil)
        let classifier = JevClassifier(
            host: .typesafe, apiKey: "k", session: StubHTTPProtocol.session(), sleep: { _ in },
            usageRecorder: ledger, now: { [moment] in moment })

        StubHTTPProtocol.reply.withLock { $0 = .http(429, #"{"detail":"busy"}"#) }
        _ = try? await classifier.classify(capture: "c", options: Self.options)
        XCTAssertTrue(ledger.entries().isEmpty)

        StubHTTPProtocol.reply.withLock {
            $0 = .http(200, #"{"answers":{"project":{"type":"choice","choice":"quill","probabilities":{"quill":0.95,"inbox":0.05}}}}"#)
        }
        _ = try await classifier.classify(capture: "c", options: Self.options)

        XCTAssertEqual(
            ledger.entries(),
            [UsageEntry(date: moment, feature: .quickCaptureRouting, backend: .jev, model: "jev-latest")])
    }

    /// The Vercel gateway reports Jev's token counts (JevClassifierTests'
    /// recorded answer); the call is priced at Jev's per-token list price.
    func testAJevAnswerWithTokenCountsIsPricedPerInputToken() async throws {
        let ledger = UsageLedger(fileURL: nil)
        let classifier = JevClassifier(
            host: .vercelGateway, apiKey: "k", session: StubHTTPProtocol.session(), sleep: { _ in },
            usageRecorder: ledger, now: { [moment] in moment })
        StubHTTPProtocol.reply.withLock {
            $0 = .http(200, #"{"answers":{"project":{"type":"choice","choice":"quill","probabilities":{"quill":0.95,"inbox":0.05}}},"usage":{"inputTokens":358,"outputTokens":45}}"#)
        }
        _ = try await classifier.classify(capture: "c", options: Self.options)

        let entry = try XCTUnwrap(ledger.entries().first)
        XCTAssertEqual(entry.backend, .jev)
        XCTAssertEqual(entry.model, "typesafe-ai/jev")
        XCTAssertEqual(entry.promptTokens, 358)
        XCTAssertEqual(entry.completionTokens, 45)
        XCTAssertEqual(try XCTUnwrap(entry.costUSD), 358 * 0.042 / 1_000_000, accuracy: 1e-15)
        let row = try XCTUnwrap(FeatureUsage.summarize(ledger.entries(), since: nil).first)
        XCTAssertEqual(row.unpricedPaidCalls, 0)
        XCTAssertEqual(row.line(locale: Locale(identifier: "en_US")), "1 · < $0.01 on Jev")
        XCTAssertEqual(
            FeatureUsage.summarize(
                Array(repeating: entry, count: 1_000) + [UsageEntry(date: moment, feature: .quickCaptureRouting, backend: .jev, model: "jev-latest")],
                since: nil
            ).first?.line(locale: Locale(identifier: "en_US")),
            "1,001 · $0.02 on Jev + 1 unpriced", "an answer without counts stays unpriced"
        )
    }

    // MARK: -

    private func temporaryFile() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageLedgerCoreTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("usage.jsonl")
    }
}

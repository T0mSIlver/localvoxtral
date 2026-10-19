import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest

@testable import localvoxtralCore
import localvoxtralTestSupport

/// The replay's polish step (#970): `QuickCaptureReplayLiveTests` polishes
/// each capture through the core builder when `QC_POLISH_URL` is set, and
/// counts the captures where a listed project's name appears in the raw
/// words and in the polished ones.
enum QuickCaptureReplayPolish {
    /// The bundled standard templates, with no About you, Global terms or
    /// replacement rules: what a fresh install sends.
    static func inputs() throws -> QuickCapturePolishInputs {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("qc-replay-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        return QuickCapturePolishInputs(
            templates: AppConfigStore(configDirectoryOverride: directory).loadLLMPromptTemplates(profile: .standard)
        )
    }

    /// The polisher the flags ask for, nil without `QC_POLISH_URL`.
    @MainActor
    static func polisher(
        environment: [String: String],
        key: (String) -> String,
        send: QuickCaptureReplayPolisher.Send? = nil
    ) throws -> QuickCaptureReplayPolisher? {
        guard let url = environment["QC_POLISH_URL"].flatMap({ $0.isEmpty ? nil : URL(string: $0) }) else { return nil }
        let model = try XCTUnwrap(environment["QC_POLISH_MODEL"].flatMap { $0.isEmpty ? nil : $0 }, "--polish-model")
        let configuration = try LLMPolishingConfiguration.replay(
            url: url, apiKey: key("QC_POLISH_KEY_FILE"), model: model, extra: environment["QC_POLISH_EXTRA"])
        if let send {
            return QuickCaptureReplayPolisher(configuration: configuration, inputs: try inputs(), send: send)
        }
        return QuickCaptureReplayPolisher(configuration: configuration, inputs: try inputs())
    }

    /// Whether one of `names` appears in `text` as a word, ignoring case.
    static func namesAProject(_ text: String, names: [String]) -> Bool {
        names.contains { name in
            let pattern = "(?<![A-Za-z0-9])" + NSRegularExpression.escapedPattern(for: name) + "(?![A-Za-z0-9])"
            return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    /// Counts only: never a capture's words.
    struct Tally: Equatable {
        var captures = 0
        var polished = 0
        var failed = 0
        var nameInRaw = 0
        var nameInPolished = 0
        /// A name the polished words have and the raw ones did not.
        var gained = 0
        var lost = 0

        /// Records one capture; returns whether a name was in each text.
        @discardableResult
        mutating func add(raw: String, polished: String?, names: [String]) -> (raw: Bool, polished: Bool) {
            captures += 1
            if polished == nil { failed += 1 } else { self.polished += 1 }
            let inRaw = QuickCaptureReplayPolish.namesAProject(raw, names: names)
            let inPolished = QuickCaptureReplayPolish.namesAProject(polished ?? raw, names: names)
            if inRaw { nameInRaw += 1 }
            if inPolished { nameInPolished += 1 }
            if inPolished, !inRaw { gained += 1 }
            if inRaw, !inPolished { lost += 1 }
            return (inRaw, inPolished)
        }

        var line: String {
            "QC POLISH captures=\(captures) polished=\(polished) failed=\(failed) name-in-raw=\(nameInRaw) name-in-polished=\(nameInPolished) gained=\(gained) lost=\(lost)"
        }
    }
}

/// Polishes a capture as the app's `QuickCaptureLLMPolisher` does through
/// `LLMPolishingService`: the core builder's request, in the polishing
/// server's dialect.
@MainActor
final class QuickCaptureReplayPolisher: QuickCapturePolishing {
    typealias Send = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let configuration: LLMPolishingConfiguration
    private let inputs: QuickCapturePolishInputs
    private let send: Send
    /// The last failure, for the replay to print.
    private(set) var lastError: (any Error)?

    init(
        configuration: LLMPolishingConfiguration, inputs: QuickCapturePolishInputs,
        send: @escaping Send = { try await SameOriginHTTP.shared.data(for: $0) }
    ) {
        self.configuration = configuration
        self.inputs = inputs
        self.send = send
    }

    func polish(_ text: String, vocabulary: [String]) async -> QuickCapturePolish? {
        let request = QuickCapturePolishPrompt.request(transcript: text, vocabulary: vocabulary, inputs: inputs)
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let urlRequest = try configuration.urlRequest(for: PolishWireRequest(
                systemPrompt: request.systemPrompt,
                userPrompts: request.userPrompts,
                timeout: PolishRequestTimeout.seconds(forInputCharacters: request.inputText.count),
                purpose: .polish
            ))
            let (data, response) = try await send(urlRequest)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else { throw QuickCaptureChatRouting.Failure.http(status: status) }
            guard let polished = configuration.reply(to: data)?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !polished.isEmpty
            else { throw QuickCaptureChatRouting.Failure.malformedResponse }
            let elapsed = clock.now - start
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            return QuickCapturePolish(text: polished, durationSeconds: seconds)
        } catch {
            lastError = error
            return nil
        }
    }
}

/// The replay's polish step against an injected endpoint: no network.
@MainActor
final class QuickCaptureReplayPolishTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        var bodies: [[String: Any]] = []
        var authorization: [String?] = []
    }

    func testTheReplayPolishesInTheServersDialectAndCountsNames() async throws {
        let keyFile = FileManager.default.temporaryDirectory.appendingPathComponent("qc-key-\(UUID().uuidString)")
        try Data("sk-test\n".utf8).write(to: keyFile)
        defer { try? FileManager.default.removeItem(at: keyFile) }
        let recorder = Recorder()
        let polisher = try XCTUnwrap(QuickCaptureReplayPolish.polisher(
            environment: [
                "QC_POLISH_URL": "https://api.mistral.ai", "QC_POLISH_MODEL": "stub-model",
                "QC_POLISH_KEY_FILE": keyFile.path, "QC_POLISH_EXTRA": #"{"reasoning_effort":"none"}"#,
            ],
            key: { variable in
                variable == "QC_POLISH_KEY_FILE"
                    ? ((try? String(contentsOf: keyFile, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    : ""
            },
            send: { request in
                let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
                recorder.bodies.append(body)
                recorder.authorization.append(request.value(forHTTPHeaderField: "Authorization"))
                let reply = #"{"choices":[{"message":{"content":"Fix the localvoxtral docs."}}]}"#
                return (
                    Data(reply.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                )
            }
        ))
        let raw = "fix the local Voxroll docs"
        let vocabulary = ["localvoxtral", "reach"]

        let polished = await polisher.polish(raw, vocabulary: vocabulary)

        XCTAssertEqual(polished?.text, "Fix the localvoxtral docs.")
        let body = try XCTUnwrap(recorder.bodies.first)
        let expected = QuickCapturePolishPrompt.request(
            transcript: raw, vocabulary: vocabulary, inputs: try QuickCaptureReplayPolish.inputs())
        XCTAssertEqual(body["messages"] as? [[String: String]], expected.messages)
        XCTAssertEqual(body["model"] as? String, "stub-model")
        XCTAssertEqual(body["reasoning_effort"] as? String, "none")
        XCTAssertEqual(recorder.authorization, ["Bearer sk-test"])

        var tally = QuickCaptureReplayPolish.Tally()
        let names = ["localvoxtral", "reach"]
        XCTAssertTrue(tally.add(raw: raw, polished: polished?.text, names: names) == (false, true))
        tally.add(raw: "reach the settings", polished: nil, names: names)
        tally.add(raw: "the reached state", polished: "The reached state.", names: names)
        XCTAssertEqual(tally, .init(captures: 3, polished: 2, failed: 1, nameInRaw: 1, nameInPolished: 2, gained: 1, lost: 0))
    }

    func testAnEndpointErrorGivesNoPolish() async throws {
        let polisher = QuickCaptureReplayPolisher(
            configuration: LLMPolishingConfiguration(
                endpointURL: URL(string: "http://stub.invalid/v1/chat/completions")!, apiKey: "", model: "m"),
            inputs: try QuickCaptureReplayPolish.inputs(),
            send: { request in
                (Data(), HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
            }
        )
        let polished = await polisher.polish("fix the docs", vocabulary: [])
        XCTAssertNil(polished)
        XCTAssertEqual(polisher.lastError as? QuickCaptureChatRouting.Failure, .http(status: 500))
    }
}

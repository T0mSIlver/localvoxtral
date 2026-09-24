import Foundation
import XCTest

@testable import localvoxtral

/// Latency and quality of polishd configurations ("arms") on the polish eval
/// corpora, in one run: `./scripts/remote-build.sh polishd-bench`.
///
/// Each round runs every arm once, one helper process at a time (so only one
/// copy of the model is resident), and rotates the arm order between rounds
/// so drift in the machine's state does not favour whichever arm goes first.
/// An arm is a helper binary, its extra arguments and the request
/// temperature; the production request is otherwise unchanged. Time to first
/// token comes from the helper's `timings` object, so an arm running a helper
/// that predates it reports only the client-side total.
///
/// Print-only: no timing or score assertions (no wall-clock in tests). The
/// asserted quality gate stays `PolishHelperIntegrationTests`.
@MainActor
final class PolishdSpeculativeBenchTests: XCTestCase {
    private static let markerFileName = ".polishd-bench-enable.json"

    struct Arm: Decodable {
        let name: String
        let helperPath: String
        let arguments: [String]?
        let temperature: Double?
    }

    private struct Marker: Decodable {
        let arms: [Arm]
        let rounds: Int?
        let model: String?
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testSpeculativeDecodingArms() async throws {
        let markerURL = repoRoot.appendingPathComponent(Self.markerFileName)
        guard FileManager.default.fileExists(atPath: markerURL.path) else {
            throw XCTSkip("polishd bench runs only through ./scripts/remote-build.sh polishd-bench")
        }
        let marker = try JSONDecoder().decode(Marker.self, from: Data(contentsOf: markerURL))
        let model = marker.model ?? SettingsStore.defaultLLMPolishingModel
        let rounds = max(marker.rounds ?? 3, 1)
        try await ensurePolishModelCached(model)
        try await ensureMTPHeadCached(model)

        let (standardTemplates, standardCleanup) = try LLMPolishEvalSupport.defaultPromptTemplates()
        let (agentTemplates, agentCleanup) = try LLMPolishEvalSupport.agentPromptTemplates()
        addTeardownBlock {
            standardCleanup()
            agentCleanup()
        }

        var samples: [String: [TimedPolishingService.Sample]] = [:]
        var outputs: [String: [String: String]] = [:]
        for round in 0..<rounds {
            let offset = round % marker.arms.count
            let order = Array(marker.arms[offset...] + marker.arms[..<offset])
            for arm in order {
                let binary = arm.helperPath.hasPrefix("/")
                    ? URL(fileURLWithPath: arm.helperPath)
                    : repoRoot.appendingPathComponent(arm.helperPath)
                guard FileManager.default.isExecutableFile(atPath: binary.path) else {
                    XCTFail("arm \(arm.name): no helper at \(binary.path)")
                    return
                }
                let helper = try await launchPolishHelper(
                    binary: binary, model: model, extraArguments: arm.arguments ?? [])
                let configuration = LLMPolishEvalSupport.configuration(
                    endpointURL: URL(string: "http://127.0.0.1:\(helper.port)/v1/chat/completions")!,
                    apiKey: "",
                    model: model
                )
                // Both profiles' prefixes are checkpointed before anything is
                // timed, as the app's launch warmup does.
                for templates in [standardTemplates, agentTemplates] {
                    _ = try? await LLMPolishingService().polish(
                        request: PolishPromptWarmup.request(templates: templates),
                        configuration: configuration)
                }

                let standardService = TimedPolishingService(temperature: arm.temperature)
                let agentService = TimedPolishingService(temperature: arm.temperature)
                let standard = await LLMPolishEvalSupport.runScoreboard(
                    service: standardService, templates: standardTemplates,
                    configuration: configuration)
                let agent = await LLMPolishEvalSupport.runScoreboard(
                    service: agentService,
                    templates: agentTemplates,
                    configuration: configuration,
                    requiredCases: LLMPolishEvalSupport.agentRequiredCases,
                    knownHardCases: LLMPolishEvalSupport.agentKnownHardCases,
                    technicalCases: []
                )
                if round == 0 {
                    LLMPolishEvalSupport.printScoreboard(
                        standard, configuration: configuration,
                        header: "polishd bench arm \(arm.name): standard profile")
                    LLMPolishEvalSupport.printScoreboard(
                        agent, configuration: configuration,
                        header: "polishd bench arm \(arm.name): agent profile")
                }
                for (profile, service) in [("standard", standardService), ("agent", agentService)] {
                    samples[arm.name, default: []] += service.samples
                    for sample in service.samples {
                        outputs[arm.name, default: [:]]["\(profile): \(sample.input)"] = sample.output
                    }
                }
                await Self.reapPolishHelper(helper.process)
            }
        }

        print(Self.report(arms: marker.arms, rounds: rounds, samples: samples, outputs: outputs))
        fflush(stdout)
    }

    /// Downloads the checkpoint's MTP head (config.json's `mtp_file`) into the
    /// pinned snapshot when it is missing. The app's include patterns skip it.
    private func ensureMTPHeadCached(_ repoID: String) async throws {
        guard let revision = PolishModelCatalog.option(forRepoID: repoID)?.revision else { return }
        let snapshot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub")
            .appendingPathComponent("models--" + repoID.replacingOccurrences(of: "/", with: "--"))
            .appendingPathComponent("snapshots/\(revision)")
        let config = try JSONSerialization.jsonObject(
            with: Data(contentsOf: snapshot.appendingPathComponent("config.json"))
        ) as? [String: Any]
        guard let mtpFile = config?["mtp_file"] as? String else { return }
        let destination = snapshot.appendingPathComponent(mtpFile)
        if FileManager.default.fileExists(atPath: destination.path) { return }
        print("polishd bench: downloading \(mtpFile)")
        let source = URL(string: "https://huggingface.co/\(repoID)/resolve/\(revision)/\(mtpFile)")!
        let (temporary, response) = try await URLSession.shared.download(from: source)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw PolishModelProvisioningError(description: "download failed for \(mtpFile): \(response)")
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    static func report(
        arms: [Arm],
        rounds: Int,
        samples: [String: [TimedPolishingService.Sample]],
        outputs: [String: [String: String]]
    ) -> String {
        func percentile(_ p: Double, _ values: [Double]) -> Double? {
            guard !values.isEmpty else { return nil }
            let sorted = values.sorted()
            return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
        }
        func ms(_ value: Double?) -> String {
            value.map { String(format: "%.0f", $0) } ?? "n/a"
        }
        var lines = [
            "POLISHD-BENCH-BEGIN (\(rounds) rounds, times in ms)",
            "arm | requests | first token p50 / p90 | total p50 / p90 | client total p50 | tokens/request | drafts accepted | same output as first arm",
        ]
        let reference = arms.first.flatMap { outputs[$0.name] } ?? [:]
        for arm in arms {
            let armSamples = samples[arm.name] ?? []
            let firstTokens = armSamples.compactMap { $0.timings?.firstTokenMilliseconds }
            let totals = armSamples.compactMap { $0.timings?.totalMilliseconds }
            let client = armSamples.map(\.clientMilliseconds)
            let tokens = armSamples.compactMap { $0.timings?.completionTokens }
            let drafted = armSamples.compactMap { $0.timings?.draftTokens }.reduce(0, +)
            let accepted = armSamples.compactMap { $0.timings?.acceptedDraftTokens }.reduce(0, +)
            let armOutputs = outputs[arm.name] ?? [:]
            let same = armOutputs.filter { reference[$0.key] == $0.value }.count
            lines.append(
                [
                    arm.name,
                    "\(armSamples.count)",
                    "\(ms(percentile(0.5, firstTokens))) / \(ms(percentile(0.9, firstTokens)))",
                    "\(ms(percentile(0.5, totals))) / \(ms(percentile(0.9, totals)))",
                    ms(percentile(0.5, client)),
                    tokens.isEmpty
                        ? "n/a" : String(format: "%.1f", Double(tokens.reduce(0, +)) / Double(tokens.count)),
                    drafted > 0
                        ? String(format: "%d/%d (%.0f%%)", accepted, drafted, 100 * Double(accepted) / Double(drafted))
                        : "-",
                    "\(same)/\(armOutputs.count)",
                ].joined(separator: " | "))
        }
        lines.append("POLISHD-BENCH-END")
        return lines.joined(separator: "\n")
    }
}

/// The production request, with the arm's temperature, that keeps the
/// helper's `timings` object and the client-side wall time of every call.
final class TimedPolishingService: LLMPolishingServicing, @unchecked Sendable {
    struct Sample {
        let input: String
        let output: String
        let clientMilliseconds: Double
        let timings: Timings?
    }

    struct Timings: Decodable {
        let firstTokenMilliseconds: Double
        let totalMilliseconds: Double
        let completionTokens: Int
        let draftTokens: Int?
        let acceptedDraftTokens: Int?

        enum CodingKeys: String, CodingKey {
            case firstTokenMilliseconds = "first_token_ms"
            case totalMilliseconds = "total_ms"
            case completionTokens = "completion_tokens"
            case draftTokens = "draft_tokens"
            case acceptedDraftTokens = "accepted_draft_tokens"
        }
    }

    private struct Response: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String }
            let message: Message
        }
        let choices: [Choice]
        let timings: Timings?
    }

    private let temperature: Double?
    private let lock = NSLock()
    private var recorded: [Sample] = []

    init(temperature: Double?) {
        self.temperature = temperature
    }

    var samples: [Sample] {
        lock.withLock { recorded }
    }

    func polish(
        request: LLMPolishingRequest,
        configuration: LLMPolishingConfiguration
    ) async throws -> LLMPolishingResult {
        var body = try JSONSerialization.jsonObject(
            with: LLMPolishingService.requestBody(request: request, configuration: configuration)
        ) as? [String: Any] ?? [:]
        if let temperature {
            body["temperature"] = temperature
        }
        var urlRequest = URLRequest(url: configuration.endpointURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = 120
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let start = ContinuousClock.now
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        let elapsed = start.duration(to: .now)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw LLMPolishingError.requestFailed(
                statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1,
                body: String(decoding: data.prefix(500), as: UTF8.self))
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        let content = (decoded.choices.first?.message.content ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let (seconds, attoseconds) = elapsed.components
        let sample = Sample(
            input: request.inputText,
            output: content,
            clientMilliseconds: Double(seconds) * 1000 + Double(attoseconds) / 1e15,
            timings: decoded.timings)
        lock.withLock { recorded.append(sample) }
        return LLMPolishingResult(
            rawText: request.inputText, polishedText: content, durationSeconds: 0)
    }
}

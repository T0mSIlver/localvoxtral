import Foundation
import XCTest

@testable import localvoxtral

/// How long a quick capture's polish (#970) takes on the packaged bundled
/// helper: `./scripts/remote-build.sh eval-capture-polish-latency`, after a
/// `package` run. Sends each capture text through the production
/// capture-polish request (`QuickCapturePolishPrompt.request`, the bundled
/// standard templates) and prints the model, n, the median and p90.
///
/// The texts are the synthetic set below, or a JSON-lines file on the build
/// host (`{"text": …}` per line) named by the marker. Never commit the
/// owner's captures. Timing comes from `LLMPolishingService`; the test
/// asserts only that every request answered.
@MainActor
final class QuickCapturePolishLatencyTests: XCTestCase {
    private static let markerFileName = ".quick-capture-polish-latency-enable.json"

    private struct Marker: Decodable {
        let helperPath: String
        let rounds: Int?
        let model: String?
        /// An absolute path on the build host.
        let capturesPath: String?
    }

    private struct CaptureLine: Decodable { let text: String }

    /// Made up, in the shape of a spoken capture.
    static let syntheticCaptures = [
        "put slash reload plugins in the local vox trawl documentation",
        "also the settings window should remember its size",
        "for reach add a dark mode toggle to the preferences page",
        "the website footer links to the old privacy page fix that",
        "idea make the inbox show how long each draft took",
        "bug the overlay flickers when I switch spaces during a dictation",
        "question does the helper keep its cache between launches",
        "add a keyboard shortcut to move a capture to another project",
        "the history search should match the polished text too",
        "remind me to write the release notes for the speech helper",
    ]
    static let vocabulary = ["localvoxtral", "reach", "website"]

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testCapturePolishLatencyOnTheBundledHelper() async throws {
        let markerURL = repoRoot.appendingPathComponent(Self.markerFileName)
        guard FileManager.default.fileExists(atPath: markerURL.path) else {
            throw XCTSkip("runs only through ./scripts/remote-build.sh eval-capture-polish-latency")
        }
        let marker = try JSONDecoder().decode(Marker.self, from: Data(contentsOf: markerURL))
        let model = marker.model ?? SettingsStore.defaultLLMPolishingModel
        let rounds = max(marker.rounds ?? 3, 1)
        let texts: [String]
        if let path = marker.capturesPath {
            texts = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n")
                .map { try JSONDecoder().decode(CaptureLine.self, from: Data($0.utf8)).text }
        } else {
            texts = Self.syntheticCaptures
        }
        let binary = marker.helperPath.hasPrefix("/")
            ? URL(fileURLWithPath: marker.helperPath) : repoRoot.appendingPathComponent(marker.helperPath)
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            XCTFail("no helper at \(binary.path); run ./scripts/remote-build.sh package first")
            return
        }
        try await ensurePolishModelCached(model)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lv-capture-latency-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let inputs = QuickCapturePolishInputs(
            templates: AppConfigStore(configDirectoryOverride: directory).loadLLMPromptTemplates(profile: .standard)
        )

        let helper = try await launchPolishHelper(binary: binary, model: model)
        let configuration = LLMPolishEvalSupport.configuration(
            endpointURL: URL(string: "http://127.0.0.1:\(helper.port)/v1/chat/completions")!,
            apiKey: "",
            model: model
        )
        let service = LLMPolishingService()
        // The prefix is checkpointed first, as the app's launch warmup does.
        _ = try? await service.polish(
            request: PolishPromptWarmup.request(templates: inputs.templates.withReferenceGuide().withSpeakerProfile("")),
            configuration: configuration)

        var seconds: [Double] = []
        var failures = 0
        for _ in 0..<rounds {
            for text in texts {
                let built = QuickCapturePolishPrompt.request(transcript: text, vocabulary: Self.vocabulary, inputs: inputs)
                do {
                    let result = try await service.polish(
                        request: QuickCaptureLLMPolisher.request(built), configuration: configuration)
                    seconds.append(result.durationSeconds)
                } catch {
                    failures += 1
                    print("CAPTURE-LATENCY error: \(LLMPolishingError.publicLogDescription(of: error))")
                }
            }
        }
        await Self.reapPolishHelper(helper.process)

        seconds.sort()
        func format(_ value: Double?) -> String { value.map { String(format: "%.2f", $0) } ?? "-" }
        print(
            "CAPTURE-LATENCY model=\(model) n=\(seconds.count) failed=\(failures) rounds=\(rounds) "
                + "texts=\(marker.capturesPath == nil ? "synthetic" : "file") "
                + "median=\(format(DictationInsights.median(of: seconds)))s "
                + "p90=\(format(DictationInsights.percentile(0.9, of: seconds)))s"
        )
        fflush(stdout)
        XCTAssertEqual(failures, 0)
    }
}

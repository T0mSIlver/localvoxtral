import Foundation
import XCTest
@testable import localvoxtral

/// Diagnostic probe battery for the polish model — NOT part of any test
/// tier, asserts nothing, prints scoreboards only. Two jobs:
///
/// 1. `testProbeBattery` isolates WHY the model fails punctuation-spacing
///    eval cases: P0 checks it can emit the target sequences, P2 that it
///    can execute a named edit, P1/P3/P4 that no prompting strategy
///    (minimal system prompt, assistant-turn few-shot, production prompts
///    at temperature 0) makes it detect the error, and P5 that it cannot
///    even answer yes/no detection with the rule stated in the question.
///    2026-07-06 verdict on Qwen3.5-0.8B-8bit: perception-level failure —
///    this battery is the acceptance test for a future fine-tune or model
///    pin bump (LLMPolishPromptEvalTests.knownHardCases is the pass list).
/// 2. `testSystemPromptChangeHonoredOnWarmCache` is the repro for the
///    (closed, unfounded) stale-prompt-cache report on the mlx-lm fork,
///    kept as a canary for prompt-cache regressions.
///
/// Enabled by the same `.llm-polish-eval-enable.json` marker as
/// LLMPolishPromptEvalTests (skips without it). From the dev box:
///   printf '{"endpoint": "http://127.0.0.1:8080/v1/chat/completions"}\n' > .llm-polish-eval-enable.json
///   ./scripts/remote-build.sh exec swift test --filter LLMPolishModelProbeTests
///   rm .llm-polish-eval-enable.json
@MainActor
final class LLMPolishModelProbeTests: XCTestCase {
    private static let markerFileName = ".llm-polish-eval-enable.json"
    private static let defaultEndpoint = "http://127.0.0.1:8080/v1/chat/completions"

    private struct HardCase {
        let id: String
        let input: String
        /// Expected substring after normalization.
        let want: String
        /// The exact single edit, for the explicit-command probe.
        let command: String
    }

    private static let hardCases: [HardCase] = [
        HardCase(
            id: "fr-exclamation",
            input: "C'est vraiment génial!",
            want: "génial !",
            command: "Insert one space before the exclamation mark."
        ),
        HardCase(
            id: "fr-proper-noun-question",
            input: "As-tu déjà testé localvoxtral?",
            want: "localvoxtral ?",
            command: "Insert one space before the question mark."
        ),
        HardCase(
            id: "en-exclamation",
            input: "That demo was really impressive !",
            want: "impressive!",
            command: "Remove the space before the exclamation mark."
        ),
        HardCase(
            id: "en-colon",
            input: "Here is the plan : we ship the fix tomorrow.",
            want: "plan:",
            command: "Remove the space before the colon."
        ),
    ]

    // Controls the eval already passes — included to confirm each probe
    // strategy is not itself broken.
    private static let controlCases: [HardCase] = [
        HardCase(
            id: "control-fr-question",
            input: "Tu viens demain?",
            want: "demain ?",
            command: "Insert one space before the question mark."
        ),
        HardCase(
            id: "control-en-question",
            input: "Are you coming to the meeting tomorrow ?",
            want: "tomorrow?",
            command: "Remove the space before the question mark."
        ),
    ]

    private static let minimalSystemPrompt = """
        You fix spacing around punctuation in text. Rules:
        - French text: exactly one space before "?", "!", ":" and ";".
        - English text: no space before "?", "!", ":", ";", "," and ".".
        Change nothing else. Return only the corrected text.
        """

    private struct ProbeConfig {
        let endpoint: URL
        let model: String
    }

    private func probeConfig() throws -> ProbeConfig {
        let markerURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(Self.markerFileName)
        guard FileManager.default.fileExists(atPath: markerURL.path) else {
            throw XCTSkip("Probe disabled: marker \(Self.markerFileName) missing.")
        }
        struct Marker: Decodable {
            let endpoint: String?
            let model: String?
        }
        let marker = try JSONDecoder().decode(Marker.self, from: Data(contentsOf: markerURL))
        guard let endpoint = URL(string: marker.endpoint ?? Self.defaultEndpoint) else {
            throw XCTSkip("Invalid probe endpoint")
        }
        return ProbeConfig(
            endpoint: endpoint,
            model: marker.model ?? SettingsStore.defaultLLMPolishingModel
        )
    }

    private func chat(
        _ config: ProbeConfig,
        messages: [[String: String]],
        temperature: Double
    ) async throws -> String {
        var request = URLRequest(url: config.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": config.model,
            "messages": messages,
            "temperature": temperature,
        ] as [String: Any])

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String
        else {
            return "<invalid response: \(String(data: data, encoding: .utf8) ?? "?")>"
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalized(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: " +", with: " ", options: .regularExpression)
            .lowercased()
    }

    private func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: "\\n")
    }

    func testProbeBattery() async throws {
        let config = try probeConfig()
        let allCases = Self.hardCases + Self.controlCases
        var report: [String] = []

        // P0: tokenizer/echo sanity — can it even emit the target sequences?
        for target in ["C'est vraiment génial !", "Here is the plan: we ship the fix tomorrow."] {
            let out = try await chat(
                config,
                messages: [
                    ["role": "user", "content": "Return exactly this text, unchanged: \(target)"],
                ],
                temperature: 0.0
            )
            let ok = normalized(out).contains(normalized(target))
            report.append("P0-echo \(ok ? "PASS" : "FAIL") — want \"\(target)\" got \"\(oneLine(out))\"")
        }

        // P1: minimal targeted system prompt, no polish framing, temp 0.
        for hardCase in allCases {
            let out = try await chat(
                config,
                messages: [
                    ["role": "system", "content": Self.minimalSystemPrompt],
                    ["role": "user", "content": hardCase.input],
                ],
                temperature: 0.0
            )
            let ok = normalized(out).contains(normalized(hardCase.want))
            report.append("P1-minimal \(hardCase.id): \(ok ? "PASS" : "FAIL") — got \"\(oneLine(out))\"")
        }

        // P2: explicit single-edit command naming the exact change.
        for hardCase in allCases {
            let out = try await chat(
                config,
                messages: [
                    ["role": "user", "content": "\(hardCase.command) Return only the corrected sentence.\n\n\(hardCase.input)"],
                ],
                temperature: 0.0
            )
            let ok = normalized(out).contains(normalized(hardCase.want))
            report.append("P2-command \(hardCase.id): \(ok ? "PASS" : "FAIL") — got \"\(oneLine(out))\"")
        }

        // P3: assistant-turn few-shot (the chat template the model was
        // actually trained on, unlike instructions-in-user-text).
        for hardCase in allCases {
            let out = try await chat(
                config,
                messages: [
                    ["role": "system", "content": Self.minimalSystemPrompt],
                    ["role": "user", "content": "Ça marche!"],
                    ["role": "assistant", "content": "Ça marche !"],
                    ["role": "user", "content": "It works !"],
                    ["role": "assistant", "content": "It works!"],
                    ["role": "user", "content": "une note: fini"],
                    ["role": "assistant", "content": "une note : fini"],
                    ["role": "user", "content": "the point : done"],
                    ["role": "assistant", "content": "the point: done"],
                    ["role": "user", "content": hardCase.input],
                ],
                temperature: 0.0
            )
            let ok = normalized(out).contains(normalized(hardCase.want))
            report.append("P3-fewshot \(hardCase.id): \(ok ? "PASS" : "FAIL") — got \"\(oneLine(out))\"")
        }

        // P4: production default prompts, but temperature 0 instead of 0.3.
        let templates = AppConfigStore(
            configDirectoryOverride: FileManager.default.temporaryDirectory
                .appendingPathComponent("lv-probe-\(UUID().uuidString)", isDirectory: true)
        ).loadLLMPromptTemplates()
        for hardCase in Self.hardCases {
            var messages: [[String: String]] = [["role": "system", "content": templates.systemContent]]
            for userPrompt in templates.renderedUserPrompts(inputText: hardCase.input, replacementDictionary: "") {
                messages.append(["role": "user", "content": userPrompt])
            }
            let out = try await chat(config, messages: messages, temperature: 0.0)
            let ok = normalized(out).contains(normalized(hardCase.want))
            report.append("P4-prod-temp0 \(hardCase.id): \(ok ? "PASS" : "FAIL") — got \"\(oneLine(out))\"")
        }

        // P5: pure detection — can it even SEE the spacing error yes/no?
        let detectionProbes: [(id: String, question: String, wantAnswer: String)] = [
            (
                "fr-exclamation",
                "In French typography there must be a space before \"!\". Does this French sentence have correct spacing before its exclamation mark? Answer only yes or no.\n\nC'est vraiment génial!",
                "no"
            ),
            (
                "en-exclamation",
                "In English there must be no space before \"!\". Does this English sentence have correct spacing before its exclamation mark? Answer only yes or no.\n\nThat demo was really impressive !",
                "no"
            ),
            (
                "en-colon",
                "In English there must be no space before \":\". Does this English sentence have correct spacing before its colon? Answer only yes or no.\n\nHere is the plan : we ship the fix tomorrow.",
                "no"
            ),
            (
                "control-fr-correct",
                "In French typography there must be a space before \"?\". Does this French sentence have correct spacing before its question mark? Answer only yes or no.\n\nOù est la gare ?",
                "yes"
            ),
        ]
        for probe in detectionProbes {
            let out = try await chat(
                config,
                messages: [["role": "user", "content": probe.question]],
                temperature: 0.0
            )
            let ok = normalized(out).hasPrefix(probe.wantAnswer)
            report.append("P5-detect \(probe.id): \(ok ? "PASS" : "FAIL") — want \(probe.wantAnswer) got \"\(oneLine(out))\"")
        }

        print("== model probe battery (model: \(config.model), endpoint: \(config.endpoint)) ==")
        print(report.joined(separator: "\n"))
        print("== end probe battery ==")
    }

    /// Suggested repro from T0mSIlver/mlx-lm#1: does a changed SYSTEM prompt
    /// take effect on a warm prompt cache, or is stale prefix KV served?
    /// Expected on a correct server: R2 (uppercase system rule) differs from
    /// R1 and is uppercase; R3 (identical to R1, sent after R2 churned the
    /// cache) reproduces R1 exactly.
    func testSystemPromptChangeHonoredOnWarmCache() async throws {
        let config = try probeConfig()
        let s1 = "You correct dictated text. Return only the corrected text."
        let s2 = s1 + " Respond entirely in uppercase."
        let staticUser = "The working text follows after this message."
        let dynUser = "Working text: hello world how are you ?"

        func run(_ system: String) async throws -> String {
            try await chat(
                config,
                messages: [
                    ["role": "system", "content": system],
                    ["role": "user", "content": staticUser],
                    ["role": "user", "content": dynUser],
                ],
                temperature: 0.0
            )
        }

        let out1 = try await run(s1)
        let out2 = try await run(s2)
        let out3 = try await run(s1)

        let upper2 = out2 == out2.uppercased()
        print(
            """
            == system-prompt cache repro (model: \(config.model), endpoint: \(config.endpoint)) ==
            R1 (S1):          "\(oneLine(out1))"
            R2 (S2 upper):    "\(oneLine(out2))"  [uppercase: \(upper2)]
            R3 (S1 again):    "\(oneLine(out3))"  [== R1: \(out3 == out1)]
            verdict: system change honored on warm cache: \(out2 != out1 && upper2)
            == end repro ==
            """
        )
    }
}

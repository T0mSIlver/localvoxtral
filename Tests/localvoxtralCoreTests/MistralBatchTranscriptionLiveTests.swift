import Foundation
import XCTest
@testable import localvoxtralCore

/// Live lane for the batch second pass (#317), runnable on Linux: one clip
/// transcribed without and with `context_bias`, through the production
/// client. Skips unless all three are set:
///
/// - `MISTRAL_API_KEY`
/// - `MISTRAL_BATCH_LIVE_WAV`: a 16 kHz mono PCM16 WAV in which a proper noun
///   is spoken that the unbiased model misspells. Recordings of a person stay
///   out of the repo, so the clip comes from outside it.
/// - `MISTRAL_BATCH_LIVE_TERM`: that noun, as it should be spelled.
///
/// Costs 0.003 USD per minute of audio, twice. Never wired into CI.
final class MistralBatchTranscriptionLiveTests: XCTestCase {
    func testTheBiasListRecoversANameTheUnbiasedModelMisses() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let apiKey = env["MISTRAL_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
            !apiKey.isEmpty,
            let wavPath = env["MISTRAL_BATCH_LIVE_WAV"], !wavPath.isEmpty,
            let term = env["MISTRAL_BATCH_LIVE_TERM"], !term.isEmpty
        else {
            throw XCTSkip("Set MISTRAL_API_KEY, MISTRAL_BATCH_LIVE_WAV and MISTRAL_BATCH_LIVE_TERM.")
        }
        let wav = try Data(contentsOf: URL(fileURLWithPath: wavPath))
        let endpoint = try XCTUnwrap(MistralBatchTranscription.endpoint(
            forRealtimeEndpoint: URL(string: "wss://api.mistral.ai/v1/audio/transcriptions/realtime")!))
        let client = MistralBatchTranscriptionClient()

        let unbiased = try await client.transcribe(
            wav: wav, language: nil, contextBias: [], apiKey: apiKey, endpoint: endpoint)
        let bias = MistralBatchTranscription.contextBias(from: [term, "Claude Code", "herdr"])
        let biased = try await client.transcribe(
            wav: wav, language: nil, contextBias: bias, apiKey: apiKey, endpoint: endpoint)
        print("mistral batch live: unbiased: \(unbiased.text)")
        print("mistral batch live: biased \(bias): \(biased.text)")

        XCTAssertFalse(
            unbiased.text.localizedCaseInsensitiveContains(term),
            "The clip is no proof: the unbiased model already spells \(term)."
        )
        XCTAssertTrue(
            biased.text.localizedCaseInsensitiveContains(term),
            "context_bias did not recover \(term): \(biased.text)"
        )
    }

    /// The same noun, known only from the screen: the directory of the
    /// terminal prompt the speaker was looking at (#647).
    func testAScreenTermRecoversTheNameWithTrustOn() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let apiKey = env["MISTRAL_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
            !apiKey.isEmpty,
            let wavPath = env["MISTRAL_BATCH_LIVE_WAV"], !wavPath.isEmpty,
            let term = env["MISTRAL_BATCH_LIVE_TERM"], !term.isEmpty
        else {
            throw XCTSkip("Set MISTRAL_API_KEY, MISTRAL_BATCH_LIVE_WAV and MISTRAL_BATCH_LIVE_TERM.")
        }
        let wav = try Data(contentsOf: URL(fileURLWithPath: wavPath))
        let endpoint = try XCTUnwrap(MistralBatchTranscription.endpoint(
            forRealtimeEndpoint: URL(string: "wss://api.mistral.ai/v1/audio/transcriptions/realtime")!))
        let screen = "~/work/\(term) $ git status\nOn branch main\nnothing to commit, working tree clean"
        let context = StopSecondPass.ContextTerms(
            screen: StopSecondPass.speakableTerms(in: screen, newestFirst: true))
        let untrusted = StopSecondPass.vocabulary(
            userTerms: [], dictionarySpellings: [], learnedTerms: [], context: context, contextTrusted: false)
        XCTAssertEqual(untrusted, [], "without trust the screen sends nothing")
        let bias = StopSecondPass.vocabulary(
            userTerms: [], dictionarySpellings: [], learnedTerms: [], context: context, contextTrusted: true)

        let biased = try await MistralBatchTranscriptionClient().transcribe(
            wav: wav, language: nil, contextBias: bias, apiKey: apiKey, endpoint: endpoint)
        print("mistral batch live: screen terms \(bias): \(biased.text)")
        XCTAssertTrue(
            biased.text.localizedCaseInsensitiveContains(term),
            "the screen's terms did not recover \(term): \(biased.text)"
        )
    }
}

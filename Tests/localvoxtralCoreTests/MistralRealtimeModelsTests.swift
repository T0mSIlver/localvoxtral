import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import localvoxtralCore

/// Voxtral Realtime 3 on the wire: which model ids it answers to, the terms
/// its `session.update` carries, its end of stream and its price.
final class MistralRealtimeModelsTests: XCTestCase {
    func testVoxtral3IsRecognizedByIdAndAliasOnly() {
        XCTAssertTrue(MistralRealtimeModels.isVoxtral3("voxtral-mini-transcribe-realtime-3-0"))
        XCTAssertTrue(MistralRealtimeModels.isVoxtral3("voxtral-mini-transcribe-realtime-3"))
        XCTAssertTrue(MistralRealtimeModels.isVoxtral3(" Voxtral-Mini-Transcribe-Realtime-3-0 "))
        XCTAssertFalse(MistralRealtimeModels.isVoxtral3("voxtral-mini-transcribe-realtime-2602"))
        XCTAssertFalse(MistralRealtimeModels.isVoxtral3("voxtral-mini-realtime-latest"))
        XCTAssertFalse(MistralRealtimeModels.isVoxtral3("voxtral-mini-transcribe-realtime-3-1"))
        XCTAssertFalse(MistralRealtimeModels.isVoxtral3("voxtral-mini-transcribe-realtime-30"))
        XCTAssertFalse(MistralRealtimeModels.isVoxtral3(""))
    }

    func testOnlyVoxtral3TakesContextBias() {
        XCTAssertTrue(MistralRealtimeModels.acceptsContextBias(MistralRealtimeModels.voxtral3))
        XCTAssertTrue(MistralRealtimeModels.acceptsContextBias(MistralRealtimeModels.voxtral3Alias))
        XCTAssertFalse(MistralRealtimeModels.acceptsContextBias(MistralRealtimeWebSocketClient.defaultModel))
    }

    func testContextBiasKeepsPhrasesAndDropsDuplicatesAndBlanks() {
        let terms = MistralRealtimeModels.contextBias(from: [
            "Claude  Code", "localvoxtral", "", "  \n", "LOCALVOXTRAL", "herdr, cmux",
        ])
        XCTAssertEqual(terms, ["Claude Code", "localvoxtral", "herdr, cmux"])
    }

    func testContextBiasStopsAtTheCap() {
        let candidates = (0..<250).map { "term\($0)" }
        let terms = MistralRealtimeModels.contextBias(from: candidates)
        XCTAssertEqual(terms.count, MistralRealtimeModels.maxContextBiasTerms)
        XCTAssertEqual(terms.first, "term0")
        XCTAssertEqual(terms.last, "term99")
    }

    func testVoxtral3IsPricedUnderItsIdAndAlias() throws {
        let cost = try XCTUnwrap(
            MistralPricing.dictationCost(model: MistralRealtimeModels.voxtral3, audioSeconds: 60))
        XCTAssertEqual(cost, 0.0071, accuracy: 1e-12)
        XCTAssertEqual(
            MistralPricing.dictationCost(model: "voxtral-mini-transcribe-realtime-3", audioSeconds: 60),
            cost)
    }

    // MARK: - The client

    func testSessionTermsAreKeptOnlyForAModelThatTakesThem() {
        let configuration = RealtimeSessionConfiguration(
            endpoint: MistralRealtimeWebSocketClient.defaultEndpoint,
            apiKey: "test-key",
            model: "",
            contextBias: ["Claude  Code", "herdr"]
        )
        XCTAssertEqual(
            MistralRealtimeWebSocketClient.sessionContextBias(
                for: configuration, model: MistralRealtimeModels.voxtral3),
            ["Claude Code", "herdr"])
        XCTAssertEqual(
            MistralRealtimeWebSocketClient.sessionContextBias(
                for: configuration, model: MistralRealtimeWebSocketClient.defaultModel),
            [])
    }

    #if DEBUG
    private func makeClient(
        model: String, contextBias: [String] = []
    ) -> (MistralRealtimeWebSocketClient, URLSession, URLSessionWebSocketTask) {
        let client = MistralRealtimeWebSocketClient()
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: URL(string: "ws://127.0.0.1:65535/test")!)
        client.debugPrimeConnectedStateForTesting(
            task: task, usageModel: model, sessionContextBias: contextBias)
        client.debugClearRecordedFrames()
        return (client, session, task)
    }

    /// The terms ride the session's one `session.update`, which the
    /// handshake puts ahead of any queued audio on the wire.
    func testVoxtral3SessionUpdateCarriesTheTerms() {
        let (client, session, task) = makeClient(
            model: MistralRealtimeModels.voxtral3, contextBias: ["Claude Code", "herdr"])
        defer {
            task.cancel()
            session.invalidateAndCancel()
        }

        client.debugHandleFrameForTesting(json: ["type": "session.created"])

        XCTAssertEqual(
            client.debugRecordedFrames(),
            [
                #"{"session":{"audio_format":{"encoding":"pcm_s16le","sample_rate":16000},"context_bias":["Claude Code","herdr"]},"type":"session.update"}"#
            ]
        )
    }

    func testSessionUpdateWithoutTermsHasNoContextBiasField() {
        let (client, session, task) = makeClient(model: MistralRealtimeWebSocketClient.defaultModel)
        defer {
            task.cancel()
            session.invalidateAndCancel()
        }

        client.debugHandleFrameForTesting(json: ["type": "session.created"])

        XCTAssertEqual(
            client.debugRecordedFrames(),
            [#"{"session":{"audio_format":{"encoding":"pcm_s16le","sample_rate":16000}},"type":"session.update"}"#]
        )
    }

    /// Voxtral 3 keeps 2602's stop: flush, then end, once.
    func testVoxtral3FinalCommitSendsFlushThenEnd() {
        let (client, session, task) = makeClient(model: MistralRealtimeModels.voxtral3)
        defer {
            task.cancel()
            session.invalidateAndCancel()
        }

        client.sendCommit(final: true)
        client.sendCommit(final: true)

        XCTAssertEqual(
            client.debugRecordedFrames(),
            [#"{"type":"input_audio.flush"}"#, #"{"type":"input_audio.end"}"#])
        XCTAssertTrue(client.debugStateSnapshot().isAwaitingFinalCommitDone)
    }
    #endif
}

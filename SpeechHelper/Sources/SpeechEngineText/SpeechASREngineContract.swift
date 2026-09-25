import Foundation

/// Append-only transcript snapshot produced by one `step` / `finish` call. The
/// upstream MLX engines each have their own `Delta` type, so the MLX-bound
/// adapters in `SpeechEngine` normalize them to this one. The contract lives
/// here, in the Metal-free target, so the tier-0 lane can test it.
public struct SpeechStreamDelta: Sendable, Equatable {
    public let text: String
    public let tokenIds: [Int]

    public init(text: String, tokenIds: [Int]) {
        self.text = text
        self.tokenIds = tokenIds
    }
}

/// The slice of a streaming-ASR engine `RealtimeSpeechServer` needs: feed audio,
/// read the growing transcript, flush the trailing partial, and say when the
/// engine stopped decoding on its own. One session per utterance, confined to
/// the server's serial inference queue (MLX inference is not concurrency-safe).
public protocol SpeechASRStreamingSession: AnyObject, Sendable {
    @discardableResult
    func step(_ samples: [Float]) -> SpeechStreamDelta
    @discardableResult
    func finish() -> SpeechStreamDelta
    /// Full transcript decoded so far. The server emits append-only deltas
    /// against this snapshot, never the raw engine delta.
    var text: String { get }
    /// Tokens decoded so far, for the helper's log line only.
    var decodedTokenCount: Int { get }
    /// Why the session stopped decoding before the client's final commit, or
    /// nil while it is still decoding. Each engine classifies its own stop:
    /// Voxtral's decoder counts tokens, Nemotron's RNN-T never ends a stream
    /// so its session counts the audio it was fed.
    var utteranceStop: UtteranceStop? { get }
    /// Bias decoding toward `vocabulary` from the next step on; an empty list
    /// turns the bias off. Returns false when this engine cannot bias, so the
    /// server can say the list went unused.
    @discardableResult
    func setVocabulary(_ vocabulary: SessionVocabulary) -> Bool
    /// Tokens the vocabulary bias changed so far, for the helper's log line;
    /// nil when this engine does not bias.
    var biasedTokenCount: Int? { get }
}

/// A loaded ASR model that opens one streaming session per utterance.
public protocol SpeechASREngine: Sendable {
    /// - Parameters:
    ///   - transcriptionDelayMs: the latency knob, in milliseconds of audio the
    ///     engine may hold back before emitting text. Each engine maps it to its
    ///     own equivalent (Voxtral's transcription delay, Nemotron's chunk size).
    ///   - utteranceLimit: how long one session may run before it stops decoding
    ///     and reports `UtteranceStop.lengthLimit` (#314).
    func makeSession(
        transcriptionDelayMs: Int?,
        utteranceLimit: UtteranceLimit
    ) -> SpeechASRStreamingSession
}

/// Which streaming engine `speechd` drives for a model. The helper infers it
/// from the catalog repo id the app passes on the command line, or from a local
/// directory's `config.json` when `--model-dir` is used instead. Keep in sync
/// with the app-side `SpeechEngineKind` on `SpeechModelOption`.
public enum SpeechASREngineKind: String, Sendable, CaseIterable {
    case voxtral
    case nemotron

    /// Unknown ids stay on Voxtral: it is what every install ran before a
    /// second engine existed, and a custom repo id is far more likely to be a
    /// Voxtral conversion than anything else.
    public static func infer(fromModelID id: String?) -> SpeechASREngineKind {
        guard let id else { return .voxtral }
        return id.lowercased().contains("nemotron") ? .nemotron : .voxtral
    }

    /// `--model-dir` carries no repo id, so read the checkpoint's own
    /// `model_type` ("nemotron_asr"). A missing or unreadable config keeps the
    /// Voxtral fallback, so a custom directory behaves as it always did.
    public static func infer(fromModelDirectory directory: URL) -> SpeechASREngineKind {
        guard let data = try? Data(contentsOf: directory.appending(path: "config.json")),
              let object = try? JSONSerialization.jsonObject(with: data),
              let config = object as? [String: Any],
              let modelType = config["model_type"] as? String
        else { return .voxtral }
        return infer(fromModelID: modelType)
    }
}

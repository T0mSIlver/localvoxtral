import Foundation

/// One utterance's step timings for the helper log, so a stall the app sees ("server
/// silent") says whether speechd was slow or the model produced no text (LVX-33):
/// a slow-step line the first time one step takes over a second, and a summary when
/// the utterance ends (a commit, a clear, or the client closing, as Escape does).
///
/// Its lines start with `diagnosticPrefix` and hold only numbers and fixed words, never
/// text from the transcript, because the app logs such lines unredacted
/// (`BackendProcessSupervisor.publicDiagnostic`).
public struct UtteranceStepStats: Sendable {
    public static let diagnosticPrefix = "speechd diag: "
    /// A step slower than this means the helper fell a second behind the microphone.
    public static let slowStepMilliseconds = 1_000.0

    private let sampleRate: Int
    private var steps = 0
    /// Time inside steps and the audio they covered: their ratio is the share of the
    /// dictation the GPU was busy.
    private var busyMilliseconds = 0.0
    private var audioMilliseconds = 0
    private var slowestMilliseconds = 0.0
    private var slowestAudioMilliseconds = 0
    private var reportedSlowStep = false
    private var audioSinceTextMilliseconds = 0
    private var loudestSinceText = -120.0
    private var longestAudioWithoutTextMilliseconds = 0
    /// The loudest step (RMS, dBFS) of that longest run: speech reads about -40 to -20,
    /// a pause below -50.
    private var loudestInLongestRun = -120.0

    public init(sampleRate: Int = 16_000) {
        self.sampleRate = sampleRate
    }

    /// Records one step over `samples` that took `milliseconds` and did or did not
    /// produce text. Returns the slow-step line the first time a step is slow.
    public mutating func record(milliseconds: Double, samples: [Float], producedText: Bool) -> String? {
        let audioMilliseconds = samples.count * 1_000 / sampleRate
        steps += 1
        busyMilliseconds += milliseconds
        self.audioMilliseconds += audioMilliseconds
        if milliseconds > slowestMilliseconds {
            slowestMilliseconds = milliseconds
            slowestAudioMilliseconds = audioMilliseconds
        }
        if producedText {
            audioSinceTextMilliseconds = 0
            loudestSinceText = -120
        } else {
            audioSinceTextMilliseconds += audioMilliseconds
            loudestSinceText = max(loudestSinceText, Self.rmsDBFS(samples))
            if audioSinceTextMilliseconds > longestAudioWithoutTextMilliseconds {
                longestAudioWithoutTextMilliseconds = audioSinceTextMilliseconds
                loudestInLongestRun = loudestSinceText
            }
        }
        guard !reportedSlowStep, milliseconds > Self.slowStepMilliseconds else { return nil }
        reportedSlowStep = true
        return Self.diagnosticPrefix
            + "a step took \(Int(milliseconds)) ms for \(audioMilliseconds) ms of audio; the GPU is not keeping up"
    }

    /// The summary line for an utterance that ran at least one step, then a fresh start.
    /// `ending` is a fixed word: commit, clear or close. `pauseGate` is the session's
    /// gate, when it has one.
    public mutating func finish(
        ending: String, decodedTokens: Int, pauseGate: PauseGate.Stats? = nil
    ) -> String? {
        defer { self = UtteranceStepStats(sampleRate: sampleRate) }
        guard steps > 0 else { return nil }
        var line = Self.diagnosticPrefix
            + "utterance ended by \(ending): \(steps) steps, slowest \(Int(slowestMilliseconds)) ms "
            + "for \(slowestAudioMilliseconds) ms of audio, longest audio without text "
            + "\(longestAudioWithoutTextMilliseconds) ms (loudest \(Int(loudestInLongestRun.rounded())) dBFS), "
            + "\(decodedTokens) tokens, stepping took \(Int(busyMilliseconds)) ms "
            + "for \(audioMilliseconds) ms of audio"
        if let pauseGate {
            line += ", pause gate closed \(pauseGate.closes) times, held "
                + "\(pauseGate.heldSamples * 1_000 / sampleRate) ms, dropped "
                + "\(pauseGate.droppedSamples * 1_000 / sampleRate) ms"
        }
        return line
    }

    /// RMS level of float samples in [-1, 1], in dBFS; -120 for silence or no samples.
    static func rmsDBFS(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return -120 }
        var sumOfSquares = 0.0
        for sample in samples { sumOfSquares += Double(sample) * Double(sample) }
        let rms = (sumOfSquares / Double(samples.count)).squareRoot()
        return rms > 0 ? max(-120, 20 * log10(rms)) : -120
    }
}

import Foundation

/// Watches one Mistral realtime socket for the server going quiet while audio
/// is still going out, and says what the socket was doing at that moment.
///
/// A field session (2026-09-19) got deltas for 35 s, then nothing — no error,
/// no close, and no `transcription.done` for `input_audio.end` — and the only
/// byte counts were at a log level macOS had already purged. This keeps the
/// three facts that tell a hung server from a stalled network: whether our
/// sends still complete, whether the last ping was answered, and the
/// server's `request_id`. Times are seconds on a monotonic clock the caller
/// passes in.
struct MistralStreamHealth: Equatable {
    /// Server silence, with audio still going out, that counts as a stall.
    /// Healthy speech gets a delta at least every ~2 s.
    static let stallThreshold: TimeInterval = 5.0

    struct StallReport: Equatable {
        let silentFor: TimeInterval
        let audioSecondsSinceLastEvent: Double
        /// Loudest 100 ms of that audio (RMS, dBFS): speech reads around
        /// -40 to -20, a quiet room below -50.
        let loudestDBFSSinceLastEvent: Double?
        let sendsAwaitingCompletion: Int
        /// Seconds since the last ping went out that is still unanswered.
        let unansweredPingAge: TimeInterval?
        let requestID: String?
    }

    private(set) var requestID: String?
    private var lastServerEventAt: TimeInterval
    private var audioBytesSinceLastEvent = 0
    private var loudestDBFSSinceLastEvent: Double?
    private var sendsAwaitingCompletion = 0
    private var pingSentAt: TimeInterval?
    private var stallReportedAt: TimeInterval?
    private var endSentAt: TimeInterval?

    init(openedAt: TimeInterval) {
        lastServerEventAt = openedAt
    }

    mutating func sessionCreated(requestID: String?) {
        self.requestID = requestID
    }

    /// Any frame from the server. Returns how long the stall lasted when this
    /// frame ends one, so the log shows a slow server apart from a dead one.
    mutating func serverEvent(at now: TimeInterval) -> TimeInterval? {
        defer {
            lastServerEventAt = now
            audioBytesSinceLastEvent = 0
            loudestDBFSSinceLastEvent = nil
            stallReportedAt = nil
        }
        return stallReportedAt.map { _ in now - lastServerEventAt }
    }

    /// Called as an audio frame is handed to the socket. Returns a report the
    /// first time the server has been silent past the threshold.
    mutating func audioSent(bytes: Int, levelDBFS: Double? = nil, at now: TimeInterval)
        -> StallReport?
    {
        sendsAwaitingCompletion += 1
        audioBytesSinceLastEvent += bytes
        if let levelDBFS {
            loudestDBFSSinceLastEvent = max(loudestDBFSSinceLastEvent ?? levelDBFS, levelDBFS)
        }
        let silentFor = now - lastServerEventAt
        guard stallReportedAt == nil, silentFor >= Self.stallThreshold else { return nil }
        stallReportedAt = now
        return StallReport(
            silentFor: silentFor,
            audioSecondsSinceLastEvent: Double(audioBytesSinceLastEvent) / 32_000,
            loudestDBFSSinceLastEvent: loudestDBFSSinceLastEvent,
            sendsAwaitingCompletion: sendsAwaitingCompletion,
            unansweredPingAge: pingSentAt.map { now - $0 },
            requestID: requestID
        )
    }

    mutating func audioSendCompleted() {
        sendsAwaitingCompletion = max(0, sendsAwaitingCompletion - 1)
    }

    mutating func pingSent(at now: TimeInterval) {
        if pingSentAt == nil { pingSentAt = now }
    }

    mutating func pongReceived() {
        pingSentAt = nil
    }

    mutating func endSent(at now: TimeInterval) {
        endSentAt = now
    }

    /// Describes the audio still untranscribed when the user stops: a final
    /// transcript that ends early after loud audio here means the server
    /// dropped speech; quiet audio means the user had stopped talking.
    func finalCommitSummary(at now: TimeInterval) -> String {
        String(
            format: "%.1fs of audio since the last server event (loudest %@), last server event %.2fs ago, request_id=%@",
            Double(audioBytesSinceLastEvent) / 32_000,
            Self.describeLevel(loudestDBFSSinceLastEvent), now - lastServerEventAt,
            requestID ?? "<none>")
    }

    static func describeLevel(_ dbfs: Double?) -> String {
        dbfs.map { String(format: "%.0f dBFS", $0) } ?? "n/a"
    }

    /// RMS level of 16-bit little-endian PCM in dBFS, nil for no samples.
    static func rmsDBFS(pcm16 data: Data) -> Double? {
        let count = data.count / 2
        guard count > 0 else { return nil }
        var sumOfSquares = 0.0
        data.withUnsafeBytes { raw in
            for index in 0..<count {
                let sample = Double(Int16(littleEndian: raw.loadUnaligned(
                    fromByteOffset: index * 2, as: Int16.self)))
                sumOfSquares += sample * sample
            }
        }
        let rms = (sumOfSquares / Double(count)).squareRoot()
        return rms > 0 ? 20 * log10(rms / 32_768) : -120
    }

    /// Describes a socket closed while `transcription.done` was still owed.
    func closedAwaitingDone(at now: TimeInterval) -> String {
        let endAge = endSentAt.map { String(format: "%.2fs", now - $0) } ?? "never"
        return String(
            format: "end sent %@ ago, last server event %.2fs ago, %d sends awaiting completion, request_id=%@",
            endAge, now - lastServerEventAt, sendsAwaitingCompletion, requestID ?? "<none>")
    }
}

extension MistralStreamHealth.StallReport {
    var logDescription: String {
        let ping = unansweredPingAge.map { String(format: "unanswered for %.1fs", $0) } ?? "answered"
        return String(
            format: "no server event for %.1fs; %.1fs of audio sent since (loudest %@); %d sends awaiting completion; last ping %@; request_id=%@",
            silentFor, audioSecondsSinceLastEvent,
            MistralStreamHealth.describeLevel(loudestDBFSSinceLastEvent),
            sendsAwaitingCompletion, ping, requestID ?? "<none>")
    }
}

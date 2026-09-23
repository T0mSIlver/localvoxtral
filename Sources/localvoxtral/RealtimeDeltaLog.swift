import Foundation
import os

/// A single raw realtime-delta log emission, captured before any
/// merge/preprocess/insertion processing. Mirrors what `Log.deltas` records
/// when `SettingsStore.debugLogRealtimeDeltas` is on; delivered to
/// `DictationViewModel.Dependencies.onRealtimeDeltaLogRecord` for
/// instrumentation tests.
///
/// `payload` is the exact, unprocessed string the backend delivered (quoted in
/// the actual log via `.debugDescription` so whitespace is visible); it is nil
/// for events that carry no string payload (session boundaries, finalized).
struct DebugRealtimeDeltaLogRecord: Equatable, Sendable {
    enum Kind: String, Sendable {
        case sessionConnected = "session.connected"
        case sessionDisconnected = "session.disconnected"
        case partialDelta = "partial"
        case finalTranscript = "final"
        case status = "status"
        case error = "error"
        case transcriptionFinalized = "finalized"
    }

    let kind: Kind
    let sequence: Int
    let payload: String?
}

/// The opt-in raw-delta log (issue #13 instrumentation).
struct RealtimeDeltaLog {
    /// Per-session sequence counter. Reset to 0 when a new realtime session
    /// connects. Only advanced inside the gated logging path, so a value of 0
    /// while events are flowing proves the toggle is off.
    private(set) var sequence = 0

    /// Emit the raw payload of every received realtime event to `Log.deltas`
    /// (notice level) BEFORE any processing, when the hidden
    /// `SettingsStore.debugLogRealtimeDeltas` toggle is on. Each event within
    /// a session carries a monotonic `sequence` that resets when a new session
    /// connects, so the arrival order of deltas is unambiguous in the log.
    ///
    /// Partial/final transcript payloads are logged via `.debugDescription` so
    /// the exact characters — including any leading/trailing/inner whitespace
    /// and the punctuation placement under investigation — are visible, and
    /// marked `.public` (see `debugLogRealtimeDeltas` docs for the privacy
    /// rationale). No-op when the toggle is off: `sink` is called only on the
    /// same gated path, so "sink not called when disabled" proves the logging
    /// call path was not entered.
    mutating func record(
        _ event: RealtimeEvent,
        isEnabled: Bool,
        sink: ((DebugRealtimeDeltaLogRecord) -> Void)?
    ) {
        guard isEnabled else { return }

        // A new realtime session starts the per-session sequence over.
        if case .connected = event {
            sequence = 0
        }

        let sequence = self.sequence
        self.sequence &+= 1

        func emit(_ kind: DebugRealtimeDeltaLogRecord.Kind, payload: String?) {
            sink?(DebugRealtimeDeltaLogRecord(kind: kind, sequence: sequence, payload: payload))
        }

        switch event {
        case .connected:
            Log.deltas.notice(
                "[delta-log seq=\(sequence)] session boundary: connected")
            emit(.sessionConnected, payload: nil)
        case .disconnected:
            Log.deltas.notice(
                "[delta-log seq=\(sequence)] session boundary: disconnected")
            emit(.sessionDisconnected, payload: nil)
        case .partialTranscript(let delta):
            Log.deltas.notice(
                "[delta-log seq=\(sequence)] partial delta: \(delta.debugDescription, privacy: .public)")
            emit(.partialDelta, payload: delta)
        case .finalTranscript(let text):
            Log.deltas.notice(
                "[delta-log seq=\(sequence)] final transcript: \(text.debugDescription, privacy: .public)")
            emit(.finalTranscript, payload: text)
        case .status(let message):
            Log.deltas.notice(
                "[delta-log seq=\(sequence)] status: \(message, privacy: .public)")
            emit(.status, payload: message)
        case .error(let message):
            Log.deltas.notice(
                "[delta-log seq=\(sequence)] error: \(message, privacy: .public)")
            emit(.error, payload: message)
        case .transcriptionStopped(let message):
            Log.deltas.notice(
                "[delta-log seq=\(sequence)] transcription stopped: \(message, privacy: .public)")
            emit(.error, payload: message)
        case .transcriptionFinalized:
            Log.deltas.notice(
                "[delta-log seq=\(sequence)] transcription finalized")
            emit(.transcriptionFinalized, payload: nil)
        }
    }
}

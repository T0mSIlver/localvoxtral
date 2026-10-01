import Foundation
import XCTest
@testable import localvoxtral

/// Unplugging the mic a dictation is capturing from must stop the dictation.
/// The check used to compare the selection after the device refresh, and the
/// refresh had already moved the selection to a fallback mic, so the stop
/// never fired whenever a second mic was present.
@MainActor
final class AudioCaptureHealthMonitorUnplugTests: XCTestCase {
    private static var retainedMicrophones: [MicrophoneCaptureService] = []

    func testUnpluggingTheCapturedMicStopsDictation() {
        let state = FakeAudioState(selected: "usb-mic", available: ["built-in", "usb-mic"])
        let monitor = makeMonitor(state: state)

        state.available = ["built-in"]
        monitor.debugEvaluateAudioChangeNow()

        XCTAssertEqual(state.stopReasons, ["input unavailable"])
    }

    func testPluggingAnotherMicInDuringDictationKeepsDictating() {
        let state = FakeAudioState(selected: "usb-mic", available: ["built-in", "usb-mic"])
        let monitor = makeMonitor(state: state)

        state.available = ["built-in", "usb-mic", "headset"]
        monitor.debugEvaluateAudioChangeNow()

        XCTAssertEqual(state.stopReasons, [])
    }

    /// The health poll, the evaluation debounce and the grace and recovery
    /// deadlines all run on the session clock (#1060): a mic that captures
    /// nothing is restarted once the startup grace and the no-audio recovery
    /// time have passed on it, and a stopped monitor arms nothing more.
    func testSilentMicIsRestartedOnTheSessionClockAndNotAfterStop() async throws {
        let clock = ManualSessionClock()
        let microphone = FakeMicrophoneCaptureService()
        try microphone.start(preferredDeviceID: nil, preferredInputChannel: 0) { _ in }
        microphone.isSilent = true
        let state = FakeAudioState(selected: "usb-mic", available: ["usb-mic"])
        let monitor = AudioCaptureHealthMonitor()
        monitor.start(microphone: microphone, callbacks: state.callbacks(), clock: clock.clock)
        addTeardownBlock { @MainActor in monitor.stop() }

        await clock.waitForSleepers(1)
        for _ in 0..<40 where state.restartedInputs.isEmpty {
            guard await advanceToNextTimer(clock) else { break }
        }

        XCTAssertEqual(state.restartedInputs, ["usb-mic"])
        XCTAssertGreaterThanOrEqual(
            clock.now.timeIntervalSinceReferenceDate,
            AudioCaptureHealthMonitor.startupCaptureGraceSeconds
                + AudioCaptureHealthMonitor.startupNoAudioRecoverySeconds
        )

        monitor.stop()
        XCTAssertEqual(clock.pendingSleepers, 0)
        clock.advance(by: 60)
        await Task.yield()

        XCTAssertEqual(state.restartedInputs, ["usb-mic"])
    }

    private func makeMonitor(state: FakeAudioState) -> AudioCaptureHealthMonitor {
        let microphone = MicrophoneCaptureService()
        Self.retainedMicrophones.append(microphone)
        let monitor = AudioCaptureHealthMonitor()
        monitor.start(microphone: microphone, callbacks: state.callbacks(), clock: ManualSessionClock().clock)
        addTeardownBlock { @MainActor in monitor.stop() }
        return monitor
    }

    /// Wakes the earliest timer and waits until the monitor has re-armed
    /// both of its own: the health poll and the pending evaluation, which a
    /// silent mic keeps scheduling.
    private func advanceToNextTimer(_ clock: ManualSessionClock) async -> Bool {
        guard let next = clock.pendingDeadlines.first else {
            XCTFail("the monitor armed no timer on the session clock")
            return false
        }
        clock.advance(by: next.timeIntervalSince(clock.now))
        await clock.waitForSleepers(2)
        return true
    }
}

/// Mirrors `SessionAudioPipeline.refreshMicrophoneInputs`: when the selected
/// mic disappears, the refresh falls back to the first available one.
@MainActor
private final class FakeAudioState {
    var selected: String
    var available: [String]
    private(set) var stopReasons: [String] = []
    private(set) var restartedInputs: [String?] = []

    init(selected: String, available: [String]) {
        self.selected = selected
        self.available = available
    }

    func callbacks() -> AudioCaptureHealthMonitor.Callbacks {
        AudioCaptureHealthMonitor.Callbacks(
            refreshMicrophoneInputs: { [unowned self] in
                if !available.contains(selected), let first = available.first {
                    selected = first
                }
            },
            stopDictation: { [unowned self] reason in stopReasons.append(reason) },
            stopForUnavailableInput: { [unowned self] in stopReasons.append("input unavailable") },
            isDictating: { [unowned self] in stopReasons.isEmpty },
            selectedInputDeviceID: { [unowned self] in selected },
            availableInputDevices: { [unowned self] in
                available.map { MicrophoneInputDevice(id: $0, name: $0, channelCount: 1) }
            },
            setStatus: { _ in },
            setError: { _ in },
            restartMicrophone: { [unowned self] inputID in restartedInputs.append(inputID) }
        )
    }
}

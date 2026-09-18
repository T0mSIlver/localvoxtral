import Foundation
import XCTest
@testable import localvoxtral

/// Unplugging the mic a dictation is capturing from must stop the dictation
/// with an error. The check used to compare the selection after the device
/// refresh, and the refresh had already moved the selection to a fallback
/// mic, so the stop never fired whenever a second mic was present.
@MainActor
final class AudioCaptureHealthMonitorUnplugTests: XCTestCase {
    private static var retainedMicrophones: [MicrophoneCaptureService] = []

    func testUnpluggingTheCapturedMicStopsDictation() {
        let state = FakeAudioState(selected: "usb-mic", available: ["built-in", "usb-mic"])
        let monitor = makeMonitor(state: state)

        state.available = ["built-in"]
        monitor.debugEvaluateAudioChangeNow()

        XCTAssertEqual(state.stopReasons, ["selected input unavailable"])
        XCTAssertEqual(
            state.errors.last ?? nil,
            "Selected microphone became unavailable. Reconnect it or select another input."
        )
    }

    func testPluggingAnotherMicInDuringDictationKeepsDictating() {
        let state = FakeAudioState(selected: "usb-mic", available: ["built-in", "usb-mic"])
        let monitor = makeMonitor(state: state)

        state.available = ["built-in", "usb-mic", "headset"]
        monitor.debugEvaluateAudioChangeNow()

        XCTAssertEqual(state.stopReasons, [])
    }

    private func makeMonitor(state: FakeAudioState) -> AudioCaptureHealthMonitor {
        let microphone = MicrophoneCaptureService()
        Self.retainedMicrophones.append(microphone)
        let monitor = AudioCaptureHealthMonitor()
        monitor.start(microphone: microphone, callbacks: state.callbacks())
        addTeardownBlock { @MainActor in monitor.stop() }
        return monitor
    }
}

/// Mirrors `DictationViewModel.refreshMicrophoneInputs`: when the selected
/// mic disappears, the refresh falls back to the first available one.
@MainActor
private final class FakeAudioState {
    var selected: String
    var available: [String]
    private(set) var stopReasons: [String] = []
    private(set) var errors: [String?] = []

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
            isDictating: { [unowned self] in stopReasons.isEmpty },
            selectedInputDeviceID: { [unowned self] in selected },
            availableInputDevices: { [unowned self] in
                available.map { MicrophoneInputDevice(id: $0, name: $0, channelCount: 1) }
            },
            setStatus: { _ in },
            setError: { [unowned self] message in errors.append(message) },
            restartMicrophone: { _ in }
        )
    }
}

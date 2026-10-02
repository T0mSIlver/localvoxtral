import XCTest
@testable import localvoxtralCore

/// The health monitor recovers a silent microphone by starting it again on
/// the same input. A start that keeps a unit which captured and then went
/// silent recovers nothing: the unit must be rebuilt.
final class MicrophoneRestartPolicyTests: XCTestCase {
    func testAUnitThatCapturedAndWentSilentIsRebuilt() {
        XCTAssertFalse(
            MicrophoneRestartPolicy.keepsRunningUnit(
                isCapturing: true, onSameDevice: true,
                hasCapturedAudioInRun: true, hasRecentAudio: false))
    }

    func testAUnitStillDeliveringOrStillStartingIsKept() {
        XCTAssertTrue(
            MicrophoneRestartPolicy.keepsRunningUnit(
                isCapturing: true, onSameDevice: true,
                hasCapturedAudioInRun: true, hasRecentAudio: true),
            "a unit delivering audio needs no rebuild")
        XCTAssertTrue(
            MicrophoneRestartPolicy.keepsRunningUnit(
                isCapturing: true, onSameDevice: true,
                hasCapturedAudioInRun: false, hasRecentAudio: false),
            "a unit with no first chunk yet may be waiting on a Bluetooth renegotiation")
    }
}

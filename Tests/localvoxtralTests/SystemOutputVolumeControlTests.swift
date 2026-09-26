import XCTest
@testable import localvoxtral

/// The CoreAudio control itself; the ducking fade over it is tested in the
/// core suite against a fake (`AudioDuckingControllerTests`).
final class SystemOutputVolumeControlTests: XCTestCase {
    func testTheRealControlReadsThisMacWithoutMovingAnything() {
        // Read-only on purpose: this runs on the owner's build host and on
        // CI's Mac, and a test that wrote would move their volume. What it
        // pins is that the CoreAudio property sequence executes against real
        // hardware and answers in range — the half of the path unit fakes
        // cannot cover.
        let control = CoreAudioSystemOutputVolumeControl()

        let first = control.readDefaultOutput()
        let second = control.readDefaultOutput()

        XCTAssertEqual(
            first, second, "reading the output volume is not allowed to change it")
        guard let first else {
            // A headless runner with no output device: nil is the documented
            // answer, and it is what makes ducking stand aside there.
            return
        }
        XCTAssertFalse(first.deviceUID.isEmpty, "a reading names the device it came from")
        XCTAssertTrue(
            (0...1).contains(first.volume),
            "CoreAudio reported \(first.volume), which is not a scalar volume")
        XCTAssertEqual(
            control.volume(forDeviceUID: first.deviceUID), first.volume,
            "the by-UID read a fade uses reaches the same device the default read named")
    }
}

import XCTest

@testable import localvoxtral

/// Pins the About pane's "Build" row strings. Runs in BOTH build variants:
/// the tier-0 suite compiles without LOCALVOXTRAL_DOGFOOD and the CI dogfood
/// capture suite (`swift test --filter Dogfood`) compiles with it — the pure
/// functions must behave identically in both, which is why they take the
/// build variant as a parameter instead of consulting the flag themselves.
final class DogfoodBuildStatusTests: XCTestCase {
    func testStandardBuildLabelSaysStandardRegardlessOfArmedState() {
        XCTAssertEqual(
            DogfoodBuildStatus.label(isDogfoodBuild: false, captureArmed: false), "Standard")
        // Armed can't be true in a standard build (the setting doesn't exist
        // there), but the pure function must not invent a dogfood claim even
        // when handed the impossible combination.
        XCTAssertEqual(
            DogfoodBuildStatus.label(isDogfoodBuild: false, captureArmed: true), "Standard")
    }

    func testDogfoodBuildLabelReportsArmedState() {
        XCTAssertEqual(
            DogfoodBuildStatus.label(isDogfoodBuild: true, captureArmed: true),
            "Dogfood — capture armed")
        XCTAssertEqual(
            DogfoodBuildStatus.label(isDogfoodBuild: true, captureArmed: false),
            "Dogfood — capture disarmed")
    }

    func testStandardBuildHasNoDetailLine() {
        // Standard builds must not advertise dogfood plumbing.
        XCTAssertNil(DogfoodBuildStatus.detail(isDogfoodBuild: false, captureArmed: false))
        XCTAssertNil(DogfoodBuildStatus.detail(isDogfoodBuild: false, captureArmed: true))
    }

    func testDogfoodDetailPointsAtRecordsWhenArmedAndArmCommandWhenNot() {
        let armed = DogfoodBuildStatus.detail(isDogfoodBuild: true, captureArmed: true)
        XCTAssertEqual(
            armed, "Records: ~/Library/Application Support/localvoxtral/dogfood",
            "armed detail must name the capture directory (DogfoodCaptureStore.defaultDirectoryURL)")

        let disarmed = DogfoodBuildStatus.detail(isDogfoodBuild: true, captureArmed: false)
        XCTAssertEqual(
            disarmed,
            "Arm: defaults write com.localvoxtral.app debug.dogfood_capture_enabled -bool true (relaunch)",
            "disarmed detail must quote the exact arm command (SettingsStore.Keys.dogfoodCaptureEnabled)")
    }

    func testInBinaryFlagMatchesCompileVariant() {
        // Meaningful because this suite runs under both variants in CI: the
        // tier-0 lane must see false and the dogfood capture lane true.
        #if LOCALVOXTRAL_DOGFOOD
        XCTAssertTrue(DogfoodBuildStatus.isDogfoodBuild)
        #else
        XCTAssertFalse(DogfoodBuildStatus.isDogfoodBuild)
        #endif
    }
}

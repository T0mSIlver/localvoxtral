import Foundation
import XCTest

@testable import localvoxtral

/// What a finished launch puts on screen (#449).
final class LaunchWindowPolicyTests: XCTestCase {
    func testAFirstLaunchShowsOnboardingAndNothingElse() {
        XCTAssertEqual(
            LaunchWindowPolicy.decide(onboardingCompleted: false, opensWindowAtLaunch: true),
            .onboarding
        )
        XCTAssertEqual(
            LaunchWindowPolicy.decide(onboardingCompleted: false, opensWindowAtLaunch: false),
            .onboarding
        )
    }

    func testTheSettingOffLeavesTheLaunchWithNoWindow() {
        XCTAssertEqual(
            LaunchWindowPolicy.decide(onboardingCompleted: true, opensWindowAtLaunch: false),
            .nothing
        )
    }

    func testTheSettingOnOpensTheWindow() {
        XCTAssertEqual(
            LaunchWindowPolicy.decide(onboardingCompleted: true, opensWindowAtLaunch: true),
            .window
        )
    }
}

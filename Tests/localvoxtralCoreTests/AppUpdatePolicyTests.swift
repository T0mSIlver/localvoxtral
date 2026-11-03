import Foundation
import XCTest
import localvoxtralCore
import localvoxtralTestSupport

final class AppUpdatePolicyTests: XCTestCase {
    func testOnlyAReleaseSignedReleaseBuildOutsideCIUpdatesItself() {
        XCTAssertNil(AppUpdatePolicy.disabledReason(isReleaseBuild: true, isCICopy: false, isSignedByReleaseTeam: true))
        XCTAssertEqual(
            AppUpdatePolicy.disabledReason(isReleaseBuild: false, isCICopy: false, isSignedByReleaseTeam: true),
            .developmentBuild)
        XCTAssertEqual(
            AppUpdatePolicy.disabledReason(isReleaseBuild: true, isCICopy: true, isSignedByReleaseTeam: true),
            .ciCopy)
        XCTAssertEqual(
            AppUpdatePolicy.disabledReason(isReleaseBuild: true, isCICopy: false, isSignedByReleaseTeam: false),
            .notReleaseSigned)
    }

    func testTheRequirementNamesTheReleaseTeam() {
        XCTAssertEqual(
            AppUpdatePolicy.releaseTeamRequirement,
            #"anchor apple generic and certificate leaf[subject.OU] = "3N63N7U9R3""#)
    }
}

@MainActor
final class PendingUpdateInstallTests: XCTestCase {
    private var clock: ManualSessionClock!
    private var dictationIdle = true
    private var lastInput = Date(timeIntervalSinceReferenceDate: 0)
    private var installs = 0
    private var installed: [String] = []

    override func setUp() async throws {
        clock = ManualSessionClock()
        dictationIdle = true
        lastInput = clock.now
        installs = 0
        installed = []
    }

    private func makeInstall() -> PendingUpdateInstall {
        let clock = clock!
        return PendingUpdateInstall(
            environment: .init(
                isDictationIdle: { [unowned self] in dictationIdle },
                secondsSinceUserInput: { [unowned self] in clock.now.timeIntervalSince(lastInput) },
                sleep: { await clock.sleep($0) }
            ),
            log: { _ in }
        )
    }

    private let retry = TimeInterval(AppUpdatePolicy.installRetryInterval.components.seconds)

    func testInstallsAtOnceWhenIdleAndAway() async {
        lastInput = clock.now.addingTimeInterval(-AppUpdatePolicy.userIdleBeforeInstall)
        let pending = makeInstall()
        pending.hold(version: "0.18.0") { [unowned self] in installs += 1 }
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(installs, 1)
        XCTAssertFalse(pending.isWaiting)
    }

    func testWaitsForTheUserToBeAwayThenInstallsOnce() async {
        let pending = makeInstall()
        pending.hold(version: "0.18.0") { [unowned self] in installs += 1 }
        // 4 minutes in: still under the 5-minute bar.
        for _ in 0..<4 {
            await clock.waitForSleeper(dueIn: retry)
            clock.advance(by: retry)
        }
        XCTAssertEqual(installs, 0)
        XCTAssertTrue(pending.isWaiting)
        await clock.waitForSleeper(dueIn: retry)
        clock.advance(by: retry)
        await waitUntil { self.installs == 1 }
        XCTAssertEqual(installs, 1)
        XCTAssertFalse(pending.isWaiting)
    }

    func testNeverInstallsDuringADictation() async {
        dictationIdle = false
        lastInput = clock.now.addingTimeInterval(-3600)
        let pending = makeInstall()
        pending.hold(version: "0.18.0") { [unowned self] in installs += 1 }
        for _ in 0..<3 {
            await clock.waitForSleeper(dueIn: retry)
            clock.advance(by: retry)
        }
        // The third check found the dictation still running and slept again.
        await clock.waitForSleeper(dueIn: retry)
        XCTAssertEqual(installs, 0)
        dictationIdle = true
        clock.advance(by: retry)
        await waitUntil { self.installs == 1 }
        XCTAssertEqual(installs, 1)
    }

    func testANewerDownloadReplacesTheWaitingOne() async {
        let pending = makeInstall()
        pending.hold(version: "0.18.0") { [unowned self] in installed.append("0.18.0") }
        await clock.waitForSleeper(dueIn: retry)
        pending.hold(version: "0.19.0") { [unowned self] in installed.append("0.19.0") }
        lastInput = clock.now.addingTimeInterval(-AppUpdatePolicy.userIdleBeforeInstall)
        clock.advance(by: retry)
        await waitUntil { !self.installed.isEmpty }
        XCTAssertEqual(installed, ["0.19.0"])
    }

    /// Yields the main actor until `condition` holds; bounded by a count of
    /// yields, never by wall time.
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<1000 where !condition() { await Task.yield() }
    }
}

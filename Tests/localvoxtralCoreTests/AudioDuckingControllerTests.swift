import Foundation
import Synchronization
import XCTest

import localvoxtralTestSupport
@testable import localvoxtralCore

/// The fade runs entirely on injected time: `sleepFor` advances the clock the
/// fade reads, so every assertion here is about shape, not about how long a
/// real `Task.sleep` took.
@MainActor
final class AudioDuckingControllerTests: XCTestCase {
    private static let deviceA = "device-a"
    private static let deviceB = "device-b"
    private static let original: Float = 0.8
    /// What a duck from `original` must land on, every time.
    private static var duckTarget: Float {
        original * AudioDuckingController.duckedFractionOfOriginal
    }

    // MARK: - Fade shape

    func testDuckFadesFromTheUserVolumeDownToTheDuckTarget() async {
        let harness = makeHarness(fadeDuration: 0.4)

        harness.controller.duckForSessionStart()
        await harness.controller.debugFadeTask?.value

        let writes = harness.volume.writes
        // 0.4s at one write per 40ms step: the endpoints plus nine in between.
        XCTAssertEqual(writes.count, 11, "the fade writes every step, not just the endpoints")
        assertEqual(writes.first, Self.original, "the fade starts where the user left the volume")
        assertEqual(writes.last, Self.duckTarget, "and lands exactly on the duck target")
        XCTAssertEqual(
            writes, writes.sorted(by: >), "a duck fade only ever goes down")
        assertEqual(
            writes[5], Self.original + (Self.duckTarget - Self.original) * 0.5,
            "linear in elapsed time: halfway through the duration is halfway down"
        )
    }

    func testRestoreFadesBackAndIsNeverInstant() async {
        let harness = makeHarness(fadeDuration: 0.4)

        harness.controller.duckForSessionStart()
        await harness.controller.debugFadeTask?.value
        harness.volume.clearWrites()

        harness.controller.restoreAfterSession()
        await harness.controller.debugFadeTask?.value

        let writes = harness.volume.writes
        XCTAssertEqual(
            writes.count, 11,
            "the jump back to full volume is what the fork's contributor reported as jarring")
        assertEqual(writes.first, Self.duckTarget)
        assertEqual(writes.last, Self.original, "the user's volume comes back exactly")
        XCTAssertEqual(writes, writes.sorted(by: <), "a restore fade only ever goes up")
        XCTAssertNil(
            harness.controller.debugDuckedOutput?.volume,
            "the stored original is released once the restore fade completes")
    }

    func testZeroFadeDurationWritesTheTargetOnce() async {
        let harness = makeHarness(fadeDuration: 0)

        harness.controller.duckForSessionStart()
        await harness.controller.debugFadeTask?.value

        XCTAssertEqual(harness.volume.writes.count, 1)
        assertEqual(harness.volume.writes.last, Self.duckTarget)
    }

    // MARK: - Generation cancellation

    func testRestoreMidDuckTakesOverTheFadeInsteadOfFightingIt() async {
        // The stale loop must bail: two loops writing the volume alternately
        // is the audible failure the fork's generation counter exists for.
        let harness = makeHarness(fadeDuration: 0.4)
        harness.interruptAfterSleeps(3) { controller in controller.restoreAfterSession() }

        harness.controller.duckForSessionStart()
        let duckFade = harness.controller.debugFadeTask
        await duckFade?.value
        await harness.controller.debugFadeTask?.value

        let all = harness.volume.writes
        guard let duckWrites = harness.writeCountAtInterruption else {
            return XCTFail("the interruption never ran — the duck fade was not mid-flight")
        }
        XCTAssertLessThan(
            duckWrites, 11, "the duck fade stopped early — it never reached its target")
        assertEqual(
            all[duckWrites], all[duckWrites - 1],
            "the restore picks up from the level the duck reached, with no jump")
        assertEqual(all.last, Self.original, "and still ends on the user's volume")
    }

    func testDuckMidRestoreComputesItsTargetFromTheStoredOriginal() async {
        // The erosion bug: a duck that took a fraction of the level a restore
        // was passing through would walk the volume down every cycle.
        let harness = makeHarness(fadeDuration: 0.4)
        harness.controller.duckForSessionStart()
        await harness.controller.debugFadeTask?.value

        harness.interruptAfterSleeps(3) { controller in controller.duckForSessionStart() }
        harness.controller.restoreAfterSession()
        await harness.controller.debugFadeTask?.value
        await harness.controller.debugFadeTask?.value

        assertEqual(
            harness.volume.writes.last, Self.duckTarget,
            "the second duck targets original × fraction, not a fraction of the mid-fade level")
        assertEqual(
            harness.controller.debugDuckedOutput?.volume, Self.original,
            "and the interrupted restore never released the stored original")
    }

    func testRapidStartStopCyclesDoNotErodeTheVolume() async {
        let harness = makeHarness(fadeDuration: 0.4)

        for cycle in 1...5 {
            harness.controller.duckForSessionStart()
            await harness.controller.debugFadeTask?.value
            assertEqual(
                harness.volume.volume(of: Self.deviceA), Self.duckTarget,
                "cycle \(cycle) ducks to the same level as the first")

            harness.controller.restoreAfterSession()
            await harness.controller.debugFadeTask?.value
            assertEqual(
                harness.volume.volume(of: Self.deviceA), Self.original,
                "cycle \(cycle) restores to the volume the user set")
        }
    }

    // MARK: - Off, and unreadable devices

    func testDuckIsANoOpWhileTheSettingIsOff() async {
        let harness = makeHarness(fadeDuration: 0.4, enabled: false)

        harness.controller.duckForSessionStart()
        await harness.controller.debugFadeTask?.value

        XCTAssertTrue(harness.volume.writes.isEmpty)
        XCTAssertNil(harness.controller.debugDuckedOutput?.volume)
    }

    func testTurningTheSettingOffMidSessionStillRestores() async {
        let harness = makeHarness(fadeDuration: 0.4)
        harness.controller.duckForSessionStart()
        await harness.controller.debugFadeTask?.value

        harness.setEnabled(false)
        harness.controller.restoreAfterSession()
        await harness.controller.debugFadeTask?.value

        assertEqual(
            harness.volume.volume(of: Self.deviceA), Self.original,
            "the toggle gates ducking, never the restore of a duck already made")
    }

    func testAnOutputDeviceWithNoVolumeThisMacOwnsIsLeftAlone() async {
        // HDMI and most digital outputs: reading gives nothing, so there is no
        // level we could put back afterwards.
        let harness = makeHarness(fadeDuration: 0.4, currentVolume: nil)

        harness.controller.duckForSessionStart()
        await harness.controller.debugFadeTask?.value

        XCTAssertTrue(harness.volume.writes.isEmpty)
        XCTAssertNil(harness.controller.debugDuckedOutput?.volume)
        harness.controller.restoreAfterSession()
        XCTAssertTrue(harness.volume.writes.isEmpty, "and nothing to restore either")
    }

    // MARK: - Quit and crash

    func testTerminationRestoresInOneWriteBecauseAFadeWouldNotFinish() async {
        let harness = makeHarness(fadeDuration: 0.4)
        harness.controller.duckForSessionStart()
        await harness.controller.debugFadeTask?.value
        harness.volume.clearWrites()

        harness.controller.restoreImmediatelyForTermination()

        XCTAssertEqual(harness.volume.writes.count, 1)
        assertEqual(harness.volume.writes.last, Self.original)
        XCTAssertNil(harness.pendingRestore())
    }

    func testTerminationMidFadeStillLandsOnTheUserVolume() async {
        let harness = makeHarness(fadeDuration: 0.4)
        harness.interruptAfterSleeps(2) { controller in
            controller.restoreImmediatelyForTermination()
        }

        harness.controller.duckForSessionStart()
        await harness.controller.debugFadeTask?.value

        assertEqual(harness.volume.volume(of: Self.deviceA), Self.original)
        XCTAssertNil(harness.controller.debugDuckedOutput?.volume)
    }

    func testALaunchThatDiedDuckedPutsTheVolumeBackAtTheNextStart() {
        // The process is killed outright: nothing ran a restore, so the duck's
        // stored device and volume are all the next launch has to go on.
        let harness = makeHarness(
            fadeDuration: 0.4,
            pendingRestore: OutputVolumeReading(deviceUID: Self.deviceA, volume: 0.65))

        harness.controller.restoreInterruptedDuckFromPreviousLaunch()

        XCTAssertEqual(harness.volume.writes.count, 1)
        assertEqual(harness.volume.writes.last, 0.65)
        XCTAssertNil(
            harness.pendingRestore(),
            "cleared, so a later launch does not fight a volume the user has since changed")
    }

    func testALaunchRecoveryHoldsWhileTheDuckedDeviceIsUnplugged() {
        // Clearing here would lose the only record of what that device was
        // set to, and the next launch with it plugged in could not put it back.
        let harness = makeHarness(
            fadeDuration: 0.4,
            pendingRestore: OutputVolumeReading(deviceUID: Self.deviceB, volume: 0.65))

        harness.controller.restoreInterruptedDuckFromPreviousLaunch()

        XCTAssertTrue(harness.volume.writes.isEmpty, "nothing is written to the device that is there")
        XCTAssertEqual(
            harness.pendingRestore()?.deviceUID, Self.deviceB,
            "the restore is held for the launch that sees the device again")
    }

    func testACleanRunLeavesNothingForTheNextLaunchToRestore() async {
        let harness = makeHarness(fadeDuration: 0.4)

        harness.controller.duckForSessionStart()
        await harness.controller.debugFadeTask?.value
        assertEqual(
            harness.pendingRestore()?.volume, Self.original,
            "recorded at the duck, while the process is still alive to record it")
        XCTAssertEqual(harness.pendingRestore()?.deviceUID, Self.deviceA)

        harness.controller.restoreAfterSession()
        await harness.controller.debugFadeTask?.value

        XCTAssertNil(harness.pendingRestore())
    }

    func testRefusedVolumeWritesDoNotStallTheFade() async {
        let harness = makeHarness(fadeDuration: 0.4)
        harness.volume.refuseWrites = true

        harness.controller.duckForSessionStart()
        await harness.controller.debugFadeTask?.value

        XCTAssertEqual(
            harness.volume.attemptedWrites, 11,
            "every step is still attempted; the failures are logged, not swallowed by a bail-out")
        assertEqual(
            harness.controller.debugDuckedOutput?.volume, Self.original,
            "and the volume to go back to is still known")
    }

    // MARK: - Failure paths that must not lose the way back

    func testARefusedRestoreKeepsTheVolumeToGoBackTo() async {
        // Releasing it here is what leaves a user ducked with nothing left in
        // the app that knows better.
        let harness = makeHarness(fadeDuration: 0.4)
        harness.controller.duckForSessionStart()
        await harness.controller.debugFadeTask?.value

        harness.volume.refuseWrites = true
        harness.controller.restoreAfterSession()
        await harness.controller.debugFadeTask?.value

        assertEqual(
            harness.controller.debugDuckedOutput?.volume, Self.original,
            "a later restore can still try")
        assertEqual(
            harness.pendingRestore()?.volume, Self.original,
            "and so can the next launch, if this one dies first")

        // Proof that holding it is what makes the retry work.
        harness.volume.refuseWrites = false
        harness.controller.restoreAfterSession()
        await harness.controller.debugFadeTask?.value

        assertEqual(harness.volume.volume(of: Self.deviceA), Self.original)
        XCTAssertNil(harness.pendingRestore())
    }

    func testARefusedTerminationRestoreLeavesTheRecordForTheNextLaunch() async {
        let harness = makeHarness(fadeDuration: 0.4)
        harness.controller.duckForSessionStart()
        await harness.controller.debugFadeTask?.value
        harness.volume.refuseWrites = true

        harness.controller.restoreImmediatelyForTermination()

        assertEqual(
            harness.pendingRestore()?.volume, Self.original,
            "the process is ending; the record is all that can still put it back")
    }

    // MARK: - The device the duck was taken against

    func testSwitchingOutputMidSessionLeavesTheNewDeviceAlone() async {
        // Restoring "the default device" would push the old device's level
        // onto the new one — on headphones plugged in mid-sentence, loudly.
        let harness = makeHarness(fadeDuration: 0.4)
        harness.controller.duckForSessionStart()
        await harness.controller.debugFadeTask?.value

        harness.volume.switchDefault(to: Self.deviceB, volume: 0.3)
        harness.controller.restoreAfterSession()
        await harness.controller.debugFadeTask?.value

        assertEqual(
            harness.volume.volume(of: Self.deviceA), Self.original,
            "the device that was ducked is the device that is restored")
        assertEqual(
            harness.volume.volume(of: Self.deviceB), 0.3,
            "the device the user switched to was never ours to touch")
    }

    func testUnpluggingTheDuckedDeviceAbandonsTheRestoreInsteadOfGuessing() async {
        let harness = makeHarness(fadeDuration: 0.4)
        harness.controller.duckForSessionStart()
        await harness.controller.debugFadeTask?.value
        harness.volume.clearWrites()

        harness.volume.switchDefault(to: Self.deviceB, volume: 0.3)
        harness.volume.disconnect(Self.deviceA)
        harness.controller.restoreAfterSession()
        await harness.controller.debugFadeTask?.value

        XCTAssertTrue(
            harness.volume.writes.isEmpty,
            "the level left with the device; writing it anywhere else is the bug")
        XCTAssertNil(harness.controller.debugDuckedOutput)
        XCTAssertNil(harness.pendingRestore())
    }

    // MARK: - Harness

    private func assertEqual(
        _ lhs: Float?, _ rhs: Float?, _ message: String = "",
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let lhs, let rhs else {
            return XCTFail("expected two volumes, got \(String(describing: lhs)) and \(String(describing: rhs)). \(message)", file: file, line: line)
        }
        XCTAssertEqual(lhs, rhs, accuracy: 0.0001, message, file: file, line: line)
    }

    private func makeHarness(
        fadeDuration: TimeInterval,
        enabled: Bool = true,
        currentVolume: Float? = AudioDuckingControllerTests.original,
        pendingRestore: OutputVolumeReading? = nil
    ) -> Harness {
        Harness(
            fadeDuration: fadeDuration,
            enabled: enabled,
            currentVolume: currentVolume,
            pendingRestore: pendingRestore
        )
    }

    @MainActor
    private final class Harness {
        let volume: FakeOutputVolumeControl
        private(set) var controller: AudioDuckingController!
        private var clock: Date
        private var enabled: Bool
        private var pending: OutputVolumeReading?
        private var sleepCount = 0
        private var interruptAtSleep: Int?
        private var interruption: ((AudioDuckingController) -> Void)?
        /// How many writes had landed when the interruption fired. Read after
        /// the fact: awaiting one fade lets the other run, so a count taken
        /// once both tasks are done cannot tell them apart.
        private(set) var writeCountAtInterruption: Int?

        init(
            fadeDuration: TimeInterval,
            enabled: Bool,
            currentVolume: Float?,
            pendingRestore: OutputVolumeReading?
        ) {
            self.volume = FakeOutputVolumeControl(volume: currentVolume)
            self.clock = Date(timeIntervalSince1970: 1_000)
            self.enabled = enabled
            self.pending = pendingRestore
            self.controller = AudioDuckingController(
                volumeControl: volume,
                isEnabled: { [unowned self] in self.enabled },
                fadeDuration: { fadeDuration },
                interruptedDuck: { [unowned self] in self.pending },
                recordInterruptedDuck: { [unowned self] in self.pending = $0 },
                now: { [unowned self] in self.clock },
                sleepFor: { [unowned self] duration in self.advance(by: duration) }
            )
        }

        func setEnabled(_ value: Bool) { enabled = value }
        func pendingRestore() -> OutputVolumeReading? { pending }

        /// Runs `body` from inside the Nth sleep of a fade — the one moment a
        /// second duck or restore can land on a loop that is mid-flight.
        func interruptAfterSleeps(_ count: Int, _ body: @escaping (AudioDuckingController) -> Void) {
            sleepCount = 0
            interruptAtSleep = count
            interruption = body
        }

        private func advance(by duration: Duration) {
            clock = clock.addingTimeInterval(duration.asTimeInterval)
            sleepCount += 1
            if sleepCount == interruptAtSleep, let interruption {
                self.interruption = nil
                writeCountAtInterruption = volume.writes.count
                interruption(controller)
            }
        }
    }
}

extension Duration {
    var asTimeInterval: TimeInterval {
        let components = self.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}

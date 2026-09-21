import Foundation
import Synchronization
import XCTest

@testable import localvoxtral

/// The fade runs entirely on injected time: `sleepFor` advances the clock the
/// fade reads, so every assertion here is about shape, not about how long a
/// real `Task.sleep` took.
@MainActor
final class AudioDuckingControllerTests: XCTestCase {
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
            harness.controller.debugStoredOriginalVolume,
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
            harness.controller.debugStoredOriginalVolume, Self.original,
            "and the interrupted restore never released the stored original")
    }

    func testRapidStartStopCyclesDoNotErodeTheVolume() async {
        let harness = makeHarness(fadeDuration: 0.4)

        for cycle in 1...5 {
            harness.controller.duckForSessionStart()
            await harness.controller.debugFadeTask?.value
            assertEqual(
                harness.volume.currentVolume(), Self.duckTarget,
                "cycle \(cycle) ducks to the same level as the first")

            harness.controller.restoreAfterSession()
            await harness.controller.debugFadeTask?.value
            assertEqual(
                harness.volume.currentVolume(), Self.original,
                "cycle \(cycle) restores to the volume the user set")
        }
    }

    // MARK: - Off, and unreadable devices

    func testDuckIsANoOpWhileTheSettingIsOff() async {
        let harness = makeHarness(fadeDuration: 0.4, enabled: false)

        harness.controller.duckForSessionStart()
        await harness.controller.debugFadeTask?.value

        XCTAssertTrue(harness.volume.writes.isEmpty)
        XCTAssertNil(harness.controller.debugStoredOriginalVolume)
    }

    func testTurningTheSettingOffMidSessionStillRestores() async {
        let harness = makeHarness(fadeDuration: 0.4)
        harness.controller.duckForSessionStart()
        await harness.controller.debugFadeTask?.value

        harness.setEnabled(false)
        harness.controller.restoreAfterSession()
        await harness.controller.debugFadeTask?.value

        assertEqual(
            harness.volume.currentVolume(), Self.original,
            "the toggle gates ducking, never the restore of a duck already made")
    }

    func testAnOutputDeviceWithNoVolumeThisMacOwnsIsLeftAlone() async {
        // HDMI and most digital outputs: reading gives nothing, so there is no
        // level we could put back afterwards.
        let harness = makeHarness(fadeDuration: 0.4, currentVolume: nil)

        harness.controller.duckForSessionStart()
        await harness.controller.debugFadeTask?.value

        XCTAssertTrue(harness.volume.writes.isEmpty)
        XCTAssertNil(harness.controller.debugStoredOriginalVolume)
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
        XCTAssertNil(harness.pendingRestoreVolume())
    }

    func testTerminationMidFadeStillLandsOnTheUserVolume() async {
        let harness = makeHarness(fadeDuration: 0.4)
        harness.interruptAfterSleeps(2) { controller in
            controller.restoreImmediatelyForTermination()
        }

        harness.controller.duckForSessionStart()
        await harness.controller.debugFadeTask?.value

        assertEqual(harness.volume.currentVolume(), Self.original)
        XCTAssertNil(harness.controller.debugStoredOriginalVolume)
    }

    func testALaunchThatDiedDuckedPutsTheVolumeBackAtTheNextStart() {
        // The process is killed outright: nothing ran a restore, so the
        // duck's stored volume is all the next launch has to go on.
        let harness = makeHarness(fadeDuration: 0.4, pendingRestoreVolume: 0.65)

        harness.controller.restoreInterruptedDuckFromPreviousLaunch()

        XCTAssertEqual(harness.volume.writes.count, 1)
        assertEqual(harness.volume.writes.last, 0.65)
        XCTAssertNil(
            harness.pendingRestoreVolume(),
            "cleared, so a later launch does not fight a volume the user has since changed")
    }

    func testACleanRunLeavesNothingForTheNextLaunchToRestore() async {
        let harness = makeHarness(fadeDuration: 0.4)

        harness.controller.duckForSessionStart()
        await harness.controller.debugFadeTask?.value
        assertEqual(
            harness.pendingRestoreVolume(), Self.original,
            "recorded at the duck, while the process is still alive to record it")

        harness.controller.restoreAfterSession()
        await harness.controller.debugFadeTask?.value

        XCTAssertNil(harness.pendingRestoreVolume())
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
            harness.controller.debugStoredOriginalVolume, Self.original,
            "and the volume to go back to is still known")
    }

    // MARK: - The real control

    func testTheRealControlReadsThisMacWithoutMovingAnything() {
        // Read-only on purpose: this runs on the owner's build host and on
        // CI's Mac, and a test that wrote would move their volume. What it
        // pins is that the CoreAudio property sequence executes against real
        // hardware and answers in range — the half of the path unit fakes
        // cannot cover.
        let control = CoreAudioSystemOutputVolumeControl()

        let first = control.currentVolume()
        let second = control.currentVolume()

        XCTAssertEqual(
            first, second, "reading the output volume is not allowed to change it")
        guard let first else {
            // A headless runner with no output device: nil is the documented
            // answer, and it is what makes ducking stand aside there.
            return
        }
        XCTAssertTrue(
            (0...1).contains(first),
            "CoreAudio reported \(first), which is not a scalar volume")
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
        pendingRestoreVolume: Float? = nil
    ) -> Harness {
        Harness(
            fadeDuration: fadeDuration,
            enabled: enabled,
            currentVolume: currentVolume,
            pendingRestoreVolume: pendingRestoreVolume
        )
    }

    @MainActor
    private final class Harness {
        let volume: FakeOutputVolumeControl
        private(set) var controller: AudioDuckingController!
        private var clock: Date
        private var enabled: Bool
        private var pending: Float?
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
            pendingRestoreVolume: Float?
        ) {
            self.volume = FakeOutputVolumeControl(currentVolume: currentVolume)
            self.clock = Date(timeIntervalSince1970: 1_000)
            self.enabled = enabled
            self.pending = pendingRestoreVolume
            self.controller = AudioDuckingController(
                volumeControl: volume,
                isEnabled: { [unowned self] in self.enabled },
                fadeDuration: { fadeDuration },
                interruptedDuckVolume: { [unowned self] in self.pending },
                recordInterruptedDuckVolume: { [unowned self] in self.pending = $0 },
                now: { [unowned self] in self.clock },
                sleepFor: { [unowned self] duration in self.advance(by: duration) }
            )
        }

        func setEnabled(_ value: Bool) { enabled = value }
        func pendingRestoreVolume() -> Float? { pending }

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

/// Records what the ducking fade writes, and can refuse writes the way a
/// device that lost its volume property does.
final class FakeOutputVolumeControl: SystemOutputVolumeControlling, @unchecked Sendable {
    private struct State {
        var current: Float?
        var writes: [Float] = []
        var attemptedWrites = 0
        var refuseWrites = false
    }

    private let state: Mutex<State>

    init(currentVolume: Float?) {
        state = Mutex(State(current: currentVolume))
    }

    var writes: [Float] { state.withLock { $0.writes } }
    var attemptedWrites: Int { state.withLock { $0.attemptedWrites } }

    var refuseWrites: Bool {
        get { state.withLock { $0.refuseWrites } }
        set { state.withLock { $0.refuseWrites = newValue } }
    }

    func clearWrites() {
        state.withLock {
            $0.writes.removeAll()
            $0.attemptedWrites = 0
        }
    }

    func currentVolume() -> Float? { state.withLock { $0.current } }

    @discardableResult
    func setVolume(_ volume: Float) -> Bool {
        state.withLock {
            $0.attemptedWrites += 1
            guard !$0.refuseWrites else { return false }
            $0.current = volume
            $0.writes.append(volume)
            return true
        }
    }
}

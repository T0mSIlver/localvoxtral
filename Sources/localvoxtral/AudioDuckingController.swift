import Foundation

/// Lowers whatever else is playing while a dictation session runs, and fades it
/// back when the session ends.
///
/// Three rules carried over from the fork's PR #18, where each was found the
/// hard way:
///
/// 1. The device and volume to go back to are stored on the FIRST duck and
///    cleared only when a restore lands. A second duck that arrives while the
///    first is still in flight keeps them, so start/stop cycles cannot walk the
///    volume down a fraction at a time.
/// 2. The duck target is always `stored original × fraction`, never a fraction
///    of the level a fade happens to be passing through.
/// 3. Every duck and restore takes the next generation number. A fade loop that
///    finds its generation stale returns instead of fighting the newer one.
///
/// A fourth, from review: every write names the device the duck was taken
/// against. Switching output mid-session must not push the old device's volume
/// onto the new one.
@MainActor
final class AudioDuckingController {
    typealias DateProvider = () -> Date
    typealias SleepClosure = (Duration) async -> Void

    /// The ducked level, as a fraction of the volume the user had set. Loud
    /// enough that a call or a track is still audible, quiet enough to dictate
    /// over. Not a setting: the issue's one setting is the fade duration.
    static let duckedFractionOfOriginal: Float = 0.2

    /// One volume write per step while fading. 25 Hz is smooth to the ear and
    /// keeps a 2-second fade at 50 writes rather than hundreds.
    static let fadeStepSeconds: TimeInterval = 0.04
    static let fadeStep: Duration = .milliseconds(40)

    private let volumeControl: any SystemOutputVolumeControlling
    private let isEnabled: () -> Bool
    private let fadeDuration: () -> TimeInterval
    /// Reads/clears what a previous launch was ducked to when it died.
    private let interruptedDuck: () -> OutputVolumeReading?
    private let recordInterruptedDuck: (OutputVolumeReading?) -> Void
    private let now: DateProvider
    private let sleepFor: SleepClosure

    /// The device and volume to go back to. Non-nil exactly while a duck is
    /// outstanding.
    private var duckedOutput: OutputVolumeReading?
    private var generation = 0
    private var fadeTask: Task<Void, Never>?

    init(
        volumeControl: any SystemOutputVolumeControlling,
        isEnabled: @escaping () -> Bool,
        fadeDuration: @escaping () -> TimeInterval,
        interruptedDuck: @escaping () -> OutputVolumeReading? = { nil },
        recordInterruptedDuck: @escaping (OutputVolumeReading?) -> Void = { _ in },
        now: @escaping DateProvider = Date.init,
        sleepFor: @escaping SleepClosure = { duration in
            try? await Task.sleep(for: duration)
        }
    ) {
        self.volumeControl = volumeControl
        self.isEnabled = isEnabled
        self.fadeDuration = fadeDuration
        self.interruptedDuck = interruptedDuck
        self.recordInterruptedDuck = recordInterruptedDuck
        self.now = now
        self.sleepFor = sleepFor
    }

    // MARK: - Session edges

    /// Called once audio capture is actually running. A no-op while the setting
    /// is off, or when the output device reports no volume the Mac owns.
    func duckForSessionStart() {
        guard isEnabled() else { return }

        if duckedOutput == nil {
            guard let reading = volumeControl.readDefaultOutput() else {
                Log.ducking.info(
                    "duck skipped: default output device reports no volume this Mac controls")
                return
            }
            duckedOutput = reading
            recordInterruptedDuck(reading)
            Log.ducking.info(
                "duck requested on \(reading.deviceUID, privacy: .public); storing original volume \(reading.volume, privacy: .public)"
            )
        } else {
            Log.ducking.info("duck requested while a duck was outstanding; keeping stored original")
        }
        guard let ducked = duckedOutput else { return }

        beginFade(
            to: ducked.volume * Self.duckedFractionOfOriginal,
            on: ducked.deviceUID,
            releasingDuckOnCompletion: false
        )
    }

    /// Called on every path that ends a session — stop, escape-cancel, a lost
    /// socket, an aborted connect, a mic that failed to start. Safe to call
    /// when nothing was ducked.
    func restoreAfterSession() {
        guard let ducked = duckedOutput else { return }
        Log.ducking.info(
            "restore requested on \(ducked.deviceUID, privacy: .public) to \(ducked.volume, privacy: .public)"
        )
        beginFade(to: ducked.volume, on: ducked.deviceUID, releasingDuckOnCompletion: true)
    }

    /// The app is quitting. `willTerminate` runs one synchronous main-thread
    /// closure and then the process is gone, so this writes the original
    /// volume in one shot — a fade would not get to finish.
    func restoreImmediatelyForTermination() {
        guard let ducked = duckedOutput else { return }
        generation += 1
        fadeTask?.cancel()
        fadeTask = nil
        // This process is ending either way; what survives is the record for
        // the next launch, and that is kept until a write actually lands.
        duckedOutput = nil

        if volumeControl.setVolume(ducked.volume, forDeviceUID: ducked.deviceUID) {
            recordInterruptedDuck(nil)
            Log.ducking.info(
                "restored volume \(ducked.volume, privacy: .public) synchronously at termination")
        } else {
            Log.ducking.error(
                "termination restore to \(ducked.volume, privacy: .public) was refused; left for the next launch"
            )
        }
    }

    /// A previous launch was ducked when it died without restoring (a crash, a
    /// force quit). Puts the volume back at startup rather than leaving the
    /// user quiet with no dictation running.
    func restoreInterruptedDuckFromPreviousLaunch() {
        guard let pending = interruptedDuck() else { return }
        guard volumeControl.volume(forDeviceUID: pending.deviceUID) != nil else {
            // Kept, not cleared: the device is merely unplugged, and the
            // launch that sees it again is the one that can put it back.
            Log.ducking.notice(
                "a previous launch left \(pending.deviceUID, privacy: .public) ducked; it is not connected, holding the restore"
            )
            return
        }

        // The device answered, so a retry would be refused the same way.
        // Clearing here is what bounds this to one attempt.
        recordInterruptedDuck(nil)
        if volumeControl.setVolume(pending.volume, forDeviceUID: pending.deviceUID) {
            Log.ducking.notice(
                "restored volume \(pending.volume, privacy: .public) left ducked by a previous launch")
        } else {
            Log.ducking.error(
                "could not restore volume \(pending.volume, privacy: .public) left ducked by a previous launch"
            )
        }
    }

    // MARK: - Fading

    private func beginFade(
        to target: Float,
        on deviceUID: String,
        releasingDuckOnCompletion releaseDuck: Bool
    ) {
        generation += 1
        let generationAtStart = generation
        fadeTask?.cancel()

        guard let from = volumeControl.volume(forDeviceUID: deviceUID) else {
            // The device this duck was taken against is gone. Its volume left
            // with it, and writing the level onto whatever replaced it is the
            // failure this device binding exists to prevent.
            Log.ducking.notice(
                "output device \(deviceUID, privacy: .public) is gone; abandoning the fade to \(target, privacy: .public)"
            )
            if releaseDuck { releaseDuckedOutput() }
            return
        }

        let duration = max(0, fadeDuration())
        fadeTask = Task { @MainActor [weak self] in
            await self?.runFade(
                from: from,
                to: target,
                on: deviceUID,
                duration: duration,
                generation: generationAtStart,
                releasingDuck: releaseDuck
            )
        }
    }

    /// Linear in wall time, not in step count: each step's level comes from the
    /// elapsed fraction, so a loop whose sleeps overshoot still lands on the
    /// target at the requested duration instead of running long.
    private func runFade(
        from: Float,
        to target: Float,
        on deviceUID: String,
        duration: TimeInterval,
        generation generationAtStart: Int,
        releasingDuck releaseDuck: Bool
    ) async {
        let startedAt = now()
        var writeFailures = 0
        var finalWriteLanded = false

        while true {
            guard generation == generationAtStart else { return }
            let elapsed = now().timeIntervalSince(startedAt)
            // Within half a step of the end counts as the end: the target is
            // written exactly, and a duration that is not a whole number of
            // steps (or a sleep that overshot) does not buy an extra one.
            let isFinalStep = duration <= 0 || elapsed >= duration - Self.fadeStepSeconds / 2
            let progress = isFinalStep ? 1 : min(max(elapsed / duration, 0), 1)
            let level = from + (target - from) * Float(progress)
            let landed = volumeControl.setVolume(level, forDeviceUID: deviceUID)
            if !landed { writeFailures += 1 }
            if isFinalStep {
                finalWriteLanded = landed
                break
            }
            await sleepFor(Self.fadeStep)
        }

        guard generation == generationAtStart else { return }
        if releaseDuck {
            if finalWriteLanded {
                releaseDuckedOutput()
            } else {
                // Holding the original is the whole point: released here, the
                // user stays ducked with nothing left that knows better.
                Log.ducking.error(
                    "restore to \(target, privacy: .public) was refused; holding the volume to go back to for a later restore or the next launch"
                )
            }
        }
        if writeFailures > 0 {
            Log.ducking.error(
                "fade to \(target, privacy: .public) finished with \(writeFailures, privacy: .public) refused volume writes"
            )
        } else {
            Log.ducking.info("fade to \(target, privacy: .public) complete")
        }
    }

    private func releaseDuckedOutput() {
        duckedOutput = nil
        recordInterruptedDuck(nil)
    }

    #if DEBUG
    /// Test seam: the in-flight fade, so a suite awaits it instead of polling.
    var debugFadeTask: Task<Void, Never>? { fadeTask }
    var debugDuckedOutput: OutputVolumeReading? { duckedOutput }
    #endif
}

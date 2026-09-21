import Foundation

/// Lowers whatever else is playing while a dictation session runs, and fades it
/// back when the session ends.
///
/// Three rules carried over from the fork's PR #18, where each was found the
/// hard way:
///
/// 1. The user's volume is stored on the FIRST duck and cleared only when a
///    restore fade finishes. A second duck that arrives while the first is
///    still in flight keeps the stored base, so start/stop cycles cannot walk
///    the volume down a fraction at a time.
/// 2. The duck target is always `stored original × fraction`, never a fraction
///    of the level a fade happens to be passing through.
/// 3. Every duck and restore takes the next generation number. A fade loop that
///    finds its generation stale returns instead of fighting the newer one.
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
    /// Reads/clears the volume a previous launch was ducked to when it died.
    /// Nil disables the crash-recovery path (tests that don't exercise it).
    private let interruptedDuckVolume: () -> Float?
    private let recordInterruptedDuckVolume: (Float?) -> Void
    private let now: DateProvider
    private let sleepFor: SleepClosure

    /// The volume to go back to. Non-nil exactly while a duck is outstanding.
    private var originalVolume: Float?
    private var generation = 0
    private var fadeTask: Task<Void, Never>?

    init(
        volumeControl: any SystemOutputVolumeControlling,
        isEnabled: @escaping () -> Bool,
        fadeDuration: @escaping () -> TimeInterval,
        interruptedDuckVolume: @escaping () -> Float? = { nil },
        recordInterruptedDuckVolume: @escaping (Float?) -> Void = { _ in },
        now: @escaping DateProvider = Date.init,
        sleepFor: @escaping SleepClosure = { duration in
            try? await Task.sleep(for: duration)
        }
    ) {
        self.volumeControl = volumeControl
        self.isEnabled = isEnabled
        self.fadeDuration = fadeDuration
        self.interruptedDuckVolume = interruptedDuckVolume
        self.recordInterruptedDuckVolume = recordInterruptedDuckVolume
        self.now = now
        self.sleepFor = sleepFor
    }

    // MARK: - Session edges

    /// Called once audio capture is actually running. A no-op while the setting
    /// is off, or when the output device reports no volume the Mac owns.
    func duckForSessionStart() {
        guard isEnabled() else { return }

        if originalVolume == nil {
            guard let current = volumeControl.currentVolume() else {
                Log.ducking.info(
                    "duck skipped: default output device reports no volume this Mac controls")
                return
            }
            originalVolume = current
            recordInterruptedDuckVolume(current)
            Log.ducking.info("duck requested; storing original volume \(current, privacy: .public)")
        } else {
            Log.ducking.info("duck requested while a duck was outstanding; keeping stored original")
        }
        guard let original = originalVolume else { return }

        beginFade(
            to: original * Self.duckedFractionOfOriginal,
            clearingOriginalOnCompletion: false
        )
    }

    /// Called on every path that ends a session — stop, escape-cancel, a lost
    /// socket, an aborted connect, a mic that failed to start. Safe to call
    /// when nothing was ducked.
    func restoreAfterSession() {
        guard let original = originalVolume else { return }
        Log.ducking.info("restore requested to \(original, privacy: .public)")
        beginFade(to: original, clearingOriginalOnCompletion: true)
    }

    /// The app is quitting. `willTerminate` runs one synchronous main-thread
    /// closure and then the process is gone, so this writes the original
    /// volume in one shot — a fade would not get to finish.
    func restoreImmediatelyForTermination() {
        guard let original = originalVolume else { return }
        generation += 1
        fadeTask?.cancel()
        fadeTask = nil
        originalVolume = nil
        recordInterruptedDuckVolume(nil)
        if volumeControl.setVolume(original) {
            Log.ducking.info(
                "restored volume \(original, privacy: .public) synchronously at termination")
        } else {
            Log.ducking.error(
                "termination restore to \(original, privacy: .public) failed: volume write refused")
        }
    }

    /// A previous launch was ducked when it died without restoring (a crash, a
    /// force quit). Puts the volume back at startup rather than leaving the
    /// user quiet with no dictation running.
    func restoreInterruptedDuckFromPreviousLaunch() {
        guard let pending = interruptedDuckVolume() else { return }
        recordInterruptedDuckVolume(nil)
        if volumeControl.setVolume(pending) {
            Log.ducking.notice(
                "restored volume \(pending, privacy: .public) left ducked by a previous launch")
        } else {
            Log.ducking.error(
                "could not restore volume \(pending, privacy: .public) left ducked by a previous launch"
            )
        }
    }

    // MARK: - Fading

    private func beginFade(to target: Float, clearingOriginalOnCompletion clearOriginal: Bool) {
        generation += 1
        let generationAtStart = generation
        fadeTask?.cancel()

        guard let from = volumeControl.currentVolume() else {
            // Unreadable now though it read a moment ago (device swapped
            // mid-session). Write the endpoint once so nobody is left ducked.
            volumeControl.setVolume(target)
            if clearOriginal {
                originalVolume = nil
                recordInterruptedDuckVolume(nil)
            }
            Log.ducking.error("fade to \(target, privacy: .public) fell back to a single write")
            return
        }

        let duration = max(0, fadeDuration())
        fadeTask = Task { @MainActor [weak self] in
            await self?.runFade(
                from: from,
                to: target,
                duration: duration,
                generation: generationAtStart,
                clearingOriginal: clearOriginal
            )
        }
    }

    /// Linear in wall time, not in step count: each step's level comes from the
    /// elapsed fraction, so a loop whose sleeps overshoot still lands on the
    /// target at the requested duration instead of running long.
    private func runFade(
        from: Float,
        to target: Float,
        duration: TimeInterval,
        generation generationAtStart: Int,
        clearingOriginal: Bool
    ) async {
        let startedAt = now()
        var writeFailures = 0

        while true {
            guard generation == generationAtStart else { return }
            let elapsed = now().timeIntervalSince(startedAt)
            // Within half a step of the end counts as the end: the target is
            // written exactly, and a duration that is not a whole number of
            // steps (or a sleep that overshot) does not buy an extra one.
            let isFinalStep = duration <= 0 || elapsed >= duration - Self.fadeStepSeconds / 2
            let progress = isFinalStep ? 1 : min(max(elapsed / duration, 0), 1)
            let level = from + (target - from) * Float(progress)
            if !volumeControl.setVolume(level) { writeFailures += 1 }
            if isFinalStep { break }
            await sleepFor(Self.fadeStep)
        }

        guard generation == generationAtStart else { return }
        if clearingOriginal {
            originalVolume = nil
            recordInterruptedDuckVolume(nil)
        }
        if writeFailures > 0 {
            Log.ducking.error(
                "fade to \(target, privacy: .public) finished with \(writeFailures, privacy: .public) refused volume writes"
            )
        } else {
            Log.ducking.info("fade to \(target, privacy: .public) complete")
        }
    }

    #if DEBUG
    /// Test seam: the in-flight fade, so a suite awaits it instead of polling.
    var debugFadeTask: Task<Void, Never>? { fadeTask }
    var debugStoredOriginalVolume: Float? { originalVolume }
    #endif
}

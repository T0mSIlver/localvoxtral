#if LOCALVOXTRAL_DOGFOOD

import AppKit
import Carbon.HIToolbox
import Foundation

/// The one behavioral quality signal a capture record cannot derive from its own
/// contents: did the user immediately take the insertion back?
///
/// Everything else in a record describes what the pipeline DID. None of it says
/// whether the answer was any good — a record whose grounding, budget, and
/// prompt all look perfect is indistinguishable from one the owner erased half a
/// second later. Reaching for Backspace (or forward delete) or ⌘A within a
/// couple of seconds of a commit is the cheapest honest label available: the
/// user just told us the transcription or the polish was wrong, without being
/// asked.
///
/// It is deliberately NOT a keylogger, and the shape of the record is what
/// guarantees that: the enum has two cases, and the only other things recorded
/// are bucketed. No key content, no text, no timestamps finer than a bucket, and
/// nothing at all about keys that are neither of these two.
enum DogfoodEditSignal: String, Codable, Equatable, Sendable {
    /// Backspace / forward delete: the user is erasing what we inserted.
    case backspace
    /// ⌘A: almost always the first half of select-all-then-retype or
    /// select-all-then-delete.
    case selectAll

    /// The ONLY mapping from a key event to a signal. Pure and total: anything
    /// that is not one of the two gestures returns nil and is forgotten
    /// immediately — the monitor never retains, forwards, or counts it.
    ///
    /// ⌘A only with Command held and no other command-class modifier: ⌥⌘A /
    /// ⌃⌘A / ⇧⌘A are app shortcuts, not select-all, and counting them would
    /// inflate the signal with ordinary navigation.
    static func from(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> DogfoodEditSignal? {
        let relevant = modifiers.intersection(.deviceIndependentFlagsMask)
        switch Int(keyCode) {
        case kVK_Delete, kVK_ForwardDelete:
            // A modifier'd delete (⌥⌫ deletes a word, ⌘⌫ a line) is still the
            // user erasing what we inserted, so no modifier condition here.
            return .backspace
        case kVK_ANSI_A where relevant.contains(.command)
            && !relevant.contains(.option)
            && !relevant.contains(.control)
            && !relevant.contains(.shift):
            return .selectAll
        default:
            return nil
        }
    }
}

/// How a watch window ended. Every armed watch reaches exactly one of these and
/// patches its record with it, including the negative — without the "clean"
/// denominator an edit rate is not computable, and "no behavior block" would be
/// indistinguishable from "the watch never armed".
enum DogfoodEditSignalOutcome: String, Codable, Equatable, Sendable {
    case edited
    case clean
    /// The window was cut short — a new dictation began, or the app quit.
    /// Reported rather than folded into `clean`: the user moved on, which is
    /// not evidence either way.
    case superseded
}

/// The window ladder and the buckets. Pure, so the boundaries are testable
/// without a clock, a monitor, or a record.
enum DogfoodEditSignalPolicy {
    /// How long to watch after a commit, by transcript length.
    ///
    /// The ladder scales with how long the insertion takes to READ: a five-word
    /// command is judged before the user's hand leaves the key, while a
    /// paragraph has to be scanned first. Deliberately a small stepped ladder
    /// rather than a formula — the buckets are what the review reads, and a
    /// continuous function would only add false precision to a signal whose
    /// whole claim is "roughly immediately".
    ///
    /// | words | window |
    /// |---|---|
    /// | 1–5 | 2 s |
    /// | 6–15 | 4 s |
    /// | 16–40 | 8 s |
    /// | 41+ | 15 s |
    static func windowSeconds(wordCount: Int) -> Double {
        switch wordCount {
        case ..<6: return 2
        case ..<16: return 4
        case ..<41: return 8
        default: return 15
        }
    }

    /// Transcript length as a bucket, never the count. The count is one query
    /// away from the transcript itself, and the record already carries the text
    /// stages under the same gate — but the behavior block is meant to stay
    /// readable as an aggregate, and a bucket is what an aggregate wants.
    static func wordCountBucket(_ wordCount: Int) -> String {
        switch wordCount {
        case ..<6: return "1-5"
        case ..<16: return "6-15"
        case ..<41: return "16-40"
        default: return "41+"
        }
    }

    /// Seconds since the commit, bucketed. The top bucket is open-ended only in
    /// name: nothing past the longest window can be reported.
    static func secondsSinceCommitBucket(_ seconds: Double) -> String {
        switch seconds {
        case ..<1: return "0-1"
        case ..<2: return "1-2"
        case ..<5: return "2-5"
        default: return "5-15"
        }
    }

    /// Words, by whitespace. The count never leaves this type unbucketed.
    static func wordCount(of text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }
}

/// Installs a key observer for the duration of one watch window.
///
/// A protocol for the usual reason (`OverlayBufferSessionCoordinator`'s clock
/// seams): the watcher's arming, bucketing, and teardown rules are the part
/// worth testing, and none of them should need a real event stream or a real
/// Accessibility grant.
@MainActor
protocol DogfoodEditKeyMonitoring: AnyObject {
    /// Begins delivering recognized signals, reporting whether an observer
    /// actually went up. Called at most once per watch; `stop()` always follows
    /// a `true`, including when the window closed unobserved.
    ///
    /// A `false` is not a failure to handle — it is the answer "this dictation
    /// was never observed", and the watcher refuses to arm on it rather than
    /// reporting an unwatched window as clean.
    func start(_ handler: @escaping @MainActor (DogfoodEditSignal) -> Void) -> Bool
    func stop()
}

/// The production observer: one GLOBAL `NSEvent` keyDown monitor, installed when
/// a watch window opens and removed the moment it closes.
///
/// Design decisions worth keeping:
///
/// * **Global only, never local.** A local monitor sees keys typed into
///   localvoxtral's OWN windows (Settings, the shortcut recorder), which is not
///   the user reacting to an insertion. The insertion lands in another app, so
///   the reaction does too.
/// * **A new monitor rather than a tap on `ModifierOnlyHotKeyManager`'s.** That
///   manager already holds a keyDown monitor, but only while the modifier-only
///   hotkey mode is active, and its handler deliberately discards the event
///   (it needs "a key happened", not which). Widening its callback would fork a
///   production signature for a capture that shipped builds do not compile —
///   the same trade `DogfoodCaptureTap` documents, decided the same way.
/// * **No new permission.** Global `NSEvent` monitors need the Accessibility
///   trust the app already holds for insertion; without it, this reports
///   `false` and the dictation gets NO behavior block at all — see
///   `DogfoodEditSignalWatcher.arm`.
@MainActor
final class DogfoodEditKeyNSEventMonitor: DogfoodEditKeyMonitoring {
    private var monitor: Any?

    func start(_ handler: @escaping @MainActor (DogfoodEditSignal) -> Void) -> Bool {
        stop()

        #if DEBUG
        // Never install a real monitor under XCTest. Same rule (and the same
        // 2026-07-24 incident) as `ModifierOnlyHotKeyManager.start`: a live
        // monitor here would read the HOST's keyboard while the suite runs, and
        // an unattended CI machine is not a test fixture. The watcher's own
        // tests inject a fake monitor.
        if TerminalTargetDetector.isRunningUnderXCTest { return false }
        #endif

        guard AXIsProcessTrusted() else {
            // Loud, per the repo's rule about silent failure paths: a dogfood
            // build that quietly never observes an edit would read as "the
            // owner never edits".
            Log.diagnostics.notice(
                "Dogfood edit signal: Accessibility not trusted; no watch installed"
            )
            return false
        }

        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            // Nothing about the event survives this closure except the verdict:
            // an unrecognized key is not retained, forwarded, or counted.
            let keyCode = event.keyCode
            let rawFlags = event.modifierFlags.rawValue
            guard let signal = DogfoodEditSignal.from(
                keyCode: keyCode,
                modifiers: NSEvent.ModifierFlags(rawValue: rawFlags)
            ) else { return }
            Task { @MainActor in handler(signal) }
        }

        guard monitor != nil else {
            Log.diagnostics.notice(
                "Dogfood edit signal: keyDown monitor installation failed; no watch"
            )
            return false
        }
        return true
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }
}

/// Opens a bounded post-commit watch window, and patches that dictation's record
/// with what the window saw.
///
/// Lifecycle of one watch:
///
/// 1. `arm` — the commit just landed. Installs the monitor and starts the
///    window. Called only after `writeDogfoodCaptureIfArmed` cleared the runtime
///    opt-in, so a build that is not armed never observes anything.
/// 2. `attachRecord` — the record finished being written and now has a location
///    to patch. Assembly runs off-actor, so this can arrive after the window
///    already closed; both orders end in one patch, never two.
/// 3. The window closes — a recognized key, the elapsed window, a new
///    dictation, or the app terminating (`supersede`, wired to
///    `willTerminateNotification`, so a window still open at quit patches its
///    record instead of silently losing it). The monitor is torn down at that
///    instant, not at flush.
///
/// A quit that beats even that — a crash, a force-quit — leaves the record with
/// no behavior block. That is the same "never observed" answer an untrusted
/// process gets, and it is deliberately NOT `clean`.
///
/// Cross-session contamination is impossible by construction rather than by
/// timing: a watch patches the ONE record URL it was handed, and arming a new
/// watch supersedes the old one (which still flushes its own record, with
/// `superseded`). This is the same discipline as `DogfoodCaptureTap`'s
/// generation, arrived at the same way — a late producer must not describe a
/// session that has ended.
@MainActor
final class DogfoodEditSignalWatcher {
    typealias DateProvider = () -> Date
    typealias SleepClosure = (Duration) async -> Void

    private struct Watch {
        let generation: UInt64
        let armedAt: Date
        let windowSeconds: Double
        let wordCount: Int
        let outputMode: String

        var store: DogfoodCaptureStore?
        var recordURL: URL?
        /// Set when the window closed; nil while it is still open.
        var result: (outcome: DogfoodEditSignalOutcome, signal: DogfoodEditSignal?, elapsed: Double)?
    }

    private let monitor: any DogfoodEditKeyMonitoring
    // Injected for the same reason the overlay coordinator injects them: window
    // timing and elapsed-time bucketing must be assertable without wall-clock.
    private let now: DateProvider
    private let sleepFor: SleepClosure

    private var watch: Watch?
    /// Closed watches whose `attachRecord` has not arrived yet, keyed by
    /// generation. The record write is awaited, so the next dictation's arm
    /// can beat the attach — and the closed watch's verdict must survive
    /// until its record shows up, or the record becomes indistinguishable
    /// from "never observed". Bounded: an entry lives only while one record
    /// write is in flight, so growth past the cap means the writes are
    /// failing; the oldest generation is evicted first.
    private var parkedWatches: [UInt64: Watch] = [:]
    private static let parkedWatchCap = 8
    private var generation: UInt64 = 0
    /// The open window's timer, and the in-flight record patch. Retained so
    /// tests can await them the way they await `polishAndCommitTask`; nothing in
    /// production reads either.
    private(set) var windowTask: Task<Void, Never>?
    private(set) var flushTask: Task<Void, Never>?

    init(
        monitor: any DogfoodEditKeyMonitoring = DogfoodEditKeyNSEventMonitor(),
        now: @escaping DateProvider = Date.init,
        sleepFor: @escaping SleepClosure = { duration in
            try? await Task.sleep(for: duration)
        }
    ) {
        self.monitor = monitor
        self.now = now
        self.sleepFor = sleepFor
    }

    /// A watcher that goes away with a window still open must not leave a live
    /// keyboard observer behind it. `isolated deinit` (SE-0371) so the teardown
    /// runs on the actor the monitor requires; `ModifierOnlyHotKeyManager`
    /// predates it and drives teardown from its owner instead.
    isolated deinit {
        monitor.stop()
    }

    /// True while a window is open. Tests assert the monitor is not left
    /// installed; production never branches on it.
    var isWatching: Bool {
        guard let watch else { return false }
        return watch.result == nil
    }

    /// Identifies ONE watch. The caller holds it across the record write and
    /// hands it back to `attachRecord`, which is what makes a stale attach
    /// rejectable: the token names the dictation the URL belongs to, and a
    /// watcher that has moved on refuses it.
    ///
    /// Not an `Int` and not `Equatable` by accident — it exists to be compared
    /// against the watcher's own state and nothing else.
    struct WatchToken: Equatable, Sendable {
        fileprivate let generation: UInt64
    }

    /// Opens the window for the dictation that just committed, returning the
    /// token to hand back with the record. Nil when nothing is being watched —
    /// an empty commit, or an observer that could not be installed (no
    /// Accessibility trust). A nil token means the dictation gets NO behavior
    /// block, which is the honest answer: "never observed" must not be
    /// recordable as "the user kept the text".
    ///
    /// `committedText` is measured, never stored: only its word-count bucket
    /// reaches the record.
    @discardableResult
    func arm(committedText: String, outputMode: String) -> WatchToken? {
        supersede()
        parkClosedWatchAwaitingAttach()

        let wordCount = DogfoodEditSignalPolicy.wordCount(of: committedText)
        guard wordCount > 0 else { return nil }

        generation &+= 1
        let generation = generation
        let windowSeconds = DogfoodEditSignalPolicy.windowSeconds(wordCount: wordCount)

        // Install BEFORE the watch exists, so an observer that never went up
        // leaves no watch behind to flush a misleading `clean`.
        let installed = monitor.start { [weak self] signal in
            self?.handle(signal: signal, generation: generation)
        }
        guard installed else {
            watch = nil
            return nil
        }

        watch = Watch(
            generation: generation,
            armedAt: now(),
            windowSeconds: windowSeconds,
            wordCount: wordCount,
            outputMode: outputMode
        )

        // `sleepFor` is captured by value so the sleep holds NO reference to
        // the watcher: a strong `self` promoted before the await would retain
        // it for the whole window and `isolated deinit` could never run
        // mid-window. Promotion happens only after the sleep resumes.
        windowTask = Task { [weak self, sleepFor] in
            await sleepFor(.seconds(windowSeconds))
            guard !Task.isCancelled else { return }
            self?.closeWindow(outcome: .clean, signal: nil, generation: generation)
        }

        return WatchToken(generation: generation)
    }

    /// Moves a closed watch that is still waiting for its record out of the
    /// active slot, so the next `arm` cannot erase its pending verdict. Runs
    /// after `supersede()`, which guarantees any remaining watch is closed —
    /// a closed AND attached watch has already flushed and left the slot nil.
    private func parkClosedWatchAwaitingAttach() {
        guard let watch else { return }
        parkedWatches[watch.generation] = watch
        self.watch = nil
        if parkedWatches.count > Self.parkedWatchCap,
           let oldest = parkedWatches.keys.min() {
            parkedWatches.removeValue(forKey: oldest)
        }
    }

    /// Hands the open (or already-closed) watch the record it belongs to.
    ///
    /// `token` is the one `arm` returned for THIS dictation. Comparing it
    /// against the watch's own generation is the whole contamination guard: the
    /// record write is `await`ed, so a second dictation can arm in between, and
    /// without the token this call would hand session A's record to session B's
    /// open window — which would then patch A's record with B's behavior.
    func attachRecord(url: URL, store: DogfoodCaptureStore, token: WatchToken) {
        if var watch, watch.generation == token.generation {
            watch.recordURL = url
            watch.store = store
            self.watch = watch
            flushIfReady()
            return
        }
        // A parked watch: its window closed (superseded by the next dictation,
        // or a gesture landed) before the record write returned. The token
        // still names it exactly; any other generation attaches to nothing.
        if var parked = parkedWatches.removeValue(forKey: token.generation) {
            parked.recordURL = url
            parked.store = store
            flush(parked)
        }
    }

    /// Closes an open window because a new dictation began. Safe to call with
    /// nothing armed.
    func supersede() {
        guard let watch, watch.result == nil else { return }
        closeWindow(outcome: .superseded, signal: nil, generation: watch.generation)
    }

    /// Closes an open window because the app is terminating, writing the patch
    /// INLINE rather than from a `Task`.
    ///
    /// `willTerminateNotification` observers run synchronously and the process
    /// is gone shortly after; a Task enqueued there is not guaranteed to run at
    /// all (the backend shutdown next to it is best-effort for the same
    /// reason). One small JSON rewrite on the main actor is cheap enough to pay
    /// at quit, and the alternative is losing the window's answer entirely.
    func flushForTermination() {
        guard let watch, watch.result == nil else { return }
        closeWindow(
            outcome: .superseded, signal: nil, generation: watch.generation, inline: true
        )
    }

    private func handle(signal: DogfoodEditSignal, generation: UInt64) {
        closeWindow(outcome: .edited, signal: signal, generation: generation)
    }

    private func closeWindow(
        outcome: DogfoodEditSignalOutcome,
        signal: DogfoodEditSignal?,
        generation: UInt64,
        inline: Bool = false
    ) {
        guard var watch, watch.generation == generation, watch.result == nil else { return }

        // The monitor comes down at the instant the window closes, not when the
        // patch lands: the observer must not outlive the question it answers.
        monitor.stop()
        windowTask?.cancel()
        windowTask = nil

        let elapsed = max(0, now().timeIntervalSince(watch.armedAt))
        watch.result = (outcome, signal, elapsed)
        self.watch = watch
        flushIfReady(inline: inline)
    }

    /// Patches the record once both halves are known: the window's verdict and
    /// where the record landed. Whichever arrives second triggers the write.
    private func flushIfReady(inline: Bool = false) {
        guard let watch,
              watch.result != nil,
              watch.recordURL != nil,
              watch.store != nil
        else { return }
        self.watch = nil
        flush(watch, inline: inline)
    }

    /// The write itself, for a watch that has both halves — the active one, or
    /// a parked one whose late attach just delivered its record.
    private func flush(_ watch: Watch, inline: Bool = false) {
        guard let result = watch.result,
              let url = watch.recordURL,
              let store = watch.store
        else { return }

        let behavior = DogfoodCaptureRecord.Behavior(
            outcome: result.outcome,
            signal: result.signal,
            secondsSinceCommitBucket: result.outcome == .edited
                ? DogfoodEditSignalPolicy.secondsSinceCommitBucket(result.elapsed) : nil,
            wordCountBucket: DogfoodEditSignalPolicy.wordCountBucket(watch.wordCount),
            watchWindowSeconds: watch.windowSeconds,
            outputMode: watch.outputMode
        )

        guard !inline else {
            DogfoodCaptureWriter.attachSynchronously(behavior, toRecordAt: url, store: store)
            return
        }
        flushTask = Task {
            await DogfoodCaptureWriter.attach(behavior, toRecordAt: url, store: store)
        }
    }
}

#endif

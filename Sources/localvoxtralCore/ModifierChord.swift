import Foundation

/// One physical modifier key, told apart from its twin on the other side
/// (#831). The raw values are what Settings stores.
package enum SidedModifier: String, CaseIterable, Codable, Sendable, Comparable {
    case leftShift = "left_shift"
    case rightShift = "right_shift"
    case leftControl = "left_control"
    case rightControl = "right_control"
    case leftOption = "left_option"
    case rightOption = "right_option"
    case leftCommand = "left_command"
    case rightCommand = "right_command"

    /// The device-dependent bit macOS sets in an event's modifier flags while
    /// this key is down (IOKit's `NX_DEVICE*KEYMASK`). The device-independent
    /// `.shift` flag can't say which Shift is down; these bits can.
    package var deviceFlag: UInt {
        switch self {
        case .leftControl: 0x0000_0001
        case .leftShift: 0x0000_0002
        case .rightShift: 0x0000_0004
        case .leftCommand: 0x0000_0008
        case .rightCommand: 0x0000_0010
        case .leftOption: 0x0000_0020
        case .rightOption: 0x0000_0040
        case .rightControl: 0x0000_2000
        }
    }

    /// The keys an event's modifier flags say are down.
    package static func held(inDeviceFlags flags: UInt) -> Set<SidedModifier> {
        Set(allCases.filter { flags & $0.deviceFlag != 0 })
    }

    package var displayName: String {
        switch self {
        case .leftShift: "Left ⇧"
        case .rightShift: "Right ⇧"
        case .leftControl: "Left ⌃"
        case .rightControl: "Right ⌃"
        case .leftOption: "Left ⌥"
        case .rightOption: "Right ⌥"
        case .leftCommand: "Left ⌘"
        case .rightCommand: "Right ⌘"
        }
    }

    package static func < (lhs: SidedModifier, rhs: SidedModifier) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// A shortcut made of modifier keys only, pressed together, such as left
/// Shift + right Shift (#831). It needs two keys at least: one modifier on
/// its own is the dictation key's gesture, and a chord of one would fire
/// every time someone typed a capital.
package struct ModifierChord: Hashable, Sendable {
    package let keys: Set<SidedModifier>

    package init?(keys: Set<SidedModifier>) {
        guard keys.count >= 2 else { return nil }
        self.keys = keys
    }

    package static let bothShifts = ModifierChord(keys: [.leftShift, .rightShift])!

    /// `left_shift+right_shift`: the form Settings stores.
    package var storageValue: String {
        keys.sorted().map(\.rawValue).joined(separator: "+")
    }

    package init?(storageValue: String) {
        let parts = storageValue.split(separator: "+").map(String.init)
        let keys = parts.compactMap(SidedModifier.init(rawValue:))
        guard keys.count == parts.count else { return nil }
        self.init(keys: Set(keys))
    }

    package var displayName: String {
        keys.sorted().map(\.displayName).joined(separator: " + ")
    }
}

/// Decides when a `ModifierChord` fires, from the modifier keys held at each
/// modifier change and the key presses in between (#831).
///
/// The chord fires when its keys are all released, and only if:
/// - every key of the chord went down within `window` of the first,
/// - no other key, modifier or not, was pressed from the first key down to
///   the last key up.
///
/// So holding one Shift while typing never fires it: a letter cancels the
/// attempt, and a Shift held longer than `window` before the other goes
/// down is too slow to count. Firing on release rather than on the last key
/// down is what lets a key typed with both Shifts still held cancel it.
///
/// Times are the events' own timestamps, so the detector never reads a clock.
package struct ModifierChordDetector: Sendable {
    /// How far apart the chord's keys may go down, in seconds. People who
    /// mean to press two keys at once land them within 60 ms of each other;
    /// chord keyboards decode presses within that as simultaneous and
    /// tolerate up to 100 ms (US 4,680,572). The detector logs every gap it
    /// measures, so the value can be checked against real presses.
    package static let defaultWindow: TimeInterval = 0.100

    package enum Outcome: Equatable, Sendable {
        case none
        /// All keys of the chord are down; the gap between the first and the
        /// last down, in seconds. It fires on release unless something
        /// cancels it before.
        case armed(gap: TimeInterval)
        /// Every key was down, but the last one came too late.
        case tooSlow(gap: TimeInterval)
        case fire
    }

    private enum Phase: Sendable {
        case idle
        /// Some keys of the chord are down, the first at `since`.
        case pressing(since: TimeInterval)
        /// Every key is down within the window; fires once all are up.
        case armed
        /// This attempt can't fire; waits for every modifier to go up.
        case cancelled
    }

    package let chord: ModifierChord
    package let window: TimeInterval
    private var phase = Phase.idle

    package init(chord: ModifierChord, window: TimeInterval = Self.defaultWindow) {
        self.chord = chord
        self.window = window
    }

    /// A modifier went down or up.
    /// - Parameters:
    ///   - held: the sided modifiers down after the change.
    ///   - otherModifierHeld: a modifier with no side is down, Fn or Caps Lock.
    ///   - time: the event's timestamp, in seconds.
    package mutating func modifiersChanged(
        held: Set<SidedModifier>,
        otherModifierHeld: Bool = false,
        at time: TimeInterval
    ) -> Outcome {
        let nothingHeld = held.isEmpty && !otherModifierHeld
        let foreign = otherModifierHeld || !held.isSubset(of: chord.keys)

        switch phase {
        case .idle:
            if nothingHeld { return .none }
            if foreign {
                phase = .cancelled
                return .none
            }
            phase = .pressing(since: time)
            return completeIfAllDown(held: held, since: time, at: time)
        case .pressing(let since):
            if nothingHeld {
                phase = .idle
                return .none
            }
            if foreign {
                phase = .cancelled
                return .none
            }
            return completeIfAllDown(held: held, since: since, at: time)
        case .armed:
            if nothingHeld {
                phase = .idle
                return .fire
            }
            if foreign { phase = .cancelled }
            return .none
        case .cancelled:
            if nothingHeld { phase = .idle }
            return .none
        }
    }

    /// A non-modifier key went down: any attempt in progress is cancelled.
    package mutating func keyPressed() {
        cancel()
    }

    /// The attempt in progress can't fire; the next starts once every key is up.
    package mutating func cancel() {
        if case .idle = phase { return }
        phase = .cancelled
    }

    /// Every key of the chord went down in time and nothing cancelled it yet.
    package var isArmed: Bool {
        if case .armed = phase { return true }
        return false
    }

    /// Forget the attempt in progress, as if every key were up.
    package mutating func reset() {
        phase = .idle
    }

    private mutating func completeIfAllDown(
        held: Set<SidedModifier>, since: TimeInterval, at time: TimeInterval
    ) -> Outcome {
        guard held == chord.keys else { return .none }
        let gap = time - since
        guard gap <= window else {
            phase = .cancelled
            return .tooSlow(gap: gap)
        }
        phase = .armed
        return .armed(gap: gap)
    }
}

/// The dictation key as a chord (#863): a tap toggles, a hold is push to
/// talk, like the single modifier key.
///
/// `ModifierChordDetector` decides whether the keys count as the chord. Once
/// they do, the caller waits `holdDelay` and calls `holdDelayElapsed`: with
/// every key still down and nothing pressed since, that starts the hold. So
/// a slow tap and a hold differ by the hold delay alone, measured from the
/// moment the last key of the chord went down. A tap fires on release, as
/// the action chords do; a hold ends as soon as one key of the chord goes up
/// or anything else is pressed.
package struct ModifierChordGesture: Sendable {
    package enum Outcome: Equatable, Sendable {
        case none
        /// Every key is down in time. Call `holdDelayElapsed(attempt:)` after
        /// the hold delay; `attempt` tells a stale call from the current one.
        case armed(gap: TimeInterval, attempt: UInt64)
        case tooSlow(gap: TimeInterval)
        case tap
        case holdStart
        case holdEnd
    }

    private var detector: ModifierChordDetector
    private var held = Set<SidedModifier>()
    private var attempt: UInt64 = 0
    private var holding = false

    package var chord: ModifierChord { detector.chord }
    /// A hold started and hasn't ended.
    package var isHolding: Bool { holding }

    package init(chord: ModifierChord, window: TimeInterval = ModifierChordDetector.defaultWindow) {
        detector = ModifierChordDetector(chord: chord, window: window)
    }

    package mutating func modifiersChanged(
        held: Set<SidedModifier>, otherModifierHeld: Bool = false, at time: TimeInterval
    ) -> Outcome {
        self.held = otherModifierHeld ? [] : held
        if holding, held != chord.keys || otherModifierHeld {
            endHold()
            _ = detector.modifiersChanged(held: held, otherModifierHeld: otherModifierHeld, at: time)
            return .holdEnd
        }
        switch detector.modifiersChanged(held: held, otherModifierHeld: otherModifierHeld, at: time) {
        case .none:
            return .none
        case .armed(let gap):
            attempt &+= 1
            return .armed(gap: gap, attempt: attempt)
        case .tooSlow(let gap):
            return .tooSlow(gap: gap)
        case .fire:
            return .tap
        }
    }

    /// A non-modifier key went down: it cancels a tap, and ends a hold.
    package mutating func keyPressed() -> Outcome {
        if holding {
            endHold()
            return .holdEnd
        }
        detector.keyPressed()
        return .none
    }

    /// The hold delay passed since `.armed(attempt:)`.
    package mutating func holdDelayElapsed(attempt: UInt64) -> Outcome {
        guard attempt == self.attempt, !holding, detector.isArmed, held == chord.keys else { return .none }
        holding = true
        return .holdStart
    }

    /// Forget the gesture in progress, a hold included, without an outcome.
    package mutating func reset() {
        detector.reset()
        held = []
        holding = false
        attempt &+= 1
    }

    /// The rest of this press is neither a tap nor a hold.
    private mutating func endHold() {
        holding = false
        detector.cancel()
    }
}

/// Records a modifier-only chord in a shortcut field (#831): press the keys
/// together and let go. It answers once every key is up, when two keys or
/// more were down at once and no other key was pressed. One modifier on its
/// own answers nothing, so the field keeps listening for a modifier+key
/// shortcut. Keys that went down further apart than the detector's window
/// answer `tooSlow`: that chord would be stored and never fire.
package struct ModifierChordRecorder: Sendable {
    package enum Outcome: Equatable, Sendable {
        case none
        case chord(ModifierChord)
        case tooSlow
    }

    private let window: TimeInterval
    private var mostHeld = Set<SidedModifier>()
    private var anyHeld = false
    private var spoiled = false
    private var firstDown: TimeInterval?
    private var lastNewKey: TimeInterval?

    package init(window: TimeInterval = ModifierChordDetector.defaultWindow) {
        self.window = window
    }

    package mutating func modifiersChanged(
        held: Set<SidedModifier>, otherModifierHeld: Bool = false, at time: TimeInterval
    ) -> Outcome {
        if otherModifierHeld { spoiled = true }
        if !held.isSubset(of: mostHeld) {
            if firstDown == nil { firstDown = time }
            lastNewKey = time
            mostHeld.formUnion(held)
        }
        anyHeld = !held.isEmpty || otherModifierHeld
        guard !anyHeld else { return .none }
        defer { reset() }
        guard !spoiled, let chord = ModifierChord(keys: mostHeld) else { return .none }
        if let firstDown, let lastNewKey, lastNewKey - firstDown > window { return .tooSlow }
        return .chord(chord)
    }

    /// A key that isn't a modifier went down. With modifiers held, that is a
    /// modifier+key shortcut, not a chord.
    package mutating func keyPressed() {
        if anyHeld { spoiled = true }
    }

    package mutating func reset() {
        mostHeld = []
        anyHeld = false
        spoiled = false
        firstDown = nil
        lastNewKey = nil
    }
}

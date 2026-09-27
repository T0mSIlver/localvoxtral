import Foundation
import XCTest
@testable import localvoxtralCore

/// The left-and-right-Shift chord (#831): both Shifts down within the window
/// with nothing in between fire on release; a Shift held while typing never
/// does.
final class ModifierChordDetectorTests: XCTestCase {
    private let left: Set<SidedModifier> = [.leftShift]
    private let right: Set<SidedModifier> = [.rightShift]
    private let both: Set<SidedModifier> = [.leftShift, .rightShift]

    private func detector() -> ModifierChordDetector {
        ModifierChordDetector(chord: .bothShifts, window: 0.100)
    }

    func testBothShiftsWithinTheWindowFireOnceAllAreUp() {
        var chord = detector()
        XCTAssertEqual(chord.modifiersChanged(held: left, at: 10.000), .none)
        XCTAssertEqual(chord.modifiersChanged(held: both, at: 10.0625), .armed(gap: 0.0625))
        XCTAssertEqual(chord.modifiersChanged(held: right, at: 10.120), .none, "one still down")
        XCTAssertEqual(chord.modifiersChanged(held: [], at: 10.130), .fire)
        XCTAssertEqual(chord.modifiersChanged(held: [], at: 10.140), .none, "fires once")
    }

    func testEitherShiftMayGoFirstAndBothMayLandInOneEvent() {
        var chord = detector()
        _ = chord.modifiersChanged(held: right, at: 1.0)
        _ = chord.modifiersChanged(held: both, at: 1.0625)
        XCTAssertEqual(chord.modifiersChanged(held: [], at: 1.2), .fire)
        XCTAssertEqual(chord.modifiersChanged(held: both, at: 2.0), .armed(gap: 0))
        XCTAssertEqual(chord.modifiersChanged(held: [], at: 2.1), .fire)
    }

    func testAShiftHeldWhileTypingNeverFires() {
        var chord = detector()
        _ = chord.modifiersChanged(held: left, at: 0.0)
        chord.keyPressed() // H
        chord.keyPressed() // I
        XCTAssertEqual(chord.modifiersChanged(held: both, at: 0.05), .none, "a letter came first")
        XCTAssertEqual(chord.modifiersChanged(held: left, at: 0.1), .none)
        XCTAssertEqual(chord.modifiersChanged(held: [], at: 0.2), .none)
    }

    func testAKeyTypedWithBothShiftsDownCancels() {
        var chord = detector()
        _ = chord.modifiersChanged(held: left, at: 0.0)
        _ = chord.modifiersChanged(held: both, at: 0.03)
        chord.keyPressed()
        XCTAssertEqual(chord.modifiersChanged(held: [], at: 0.2), .none)
    }

    func testTheSecondShiftAfterTheWindowIsTooSlow() {
        var chord = detector()
        _ = chord.modifiersChanged(held: left, at: 5.0)
        XCTAssertEqual(chord.modifiersChanged(held: both, at: 5.25), .tooSlow(gap: 0.25))
        XCTAssertEqual(chord.modifiersChanged(held: [], at: 5.5), .none)
    }

    func testAnotherModifierCancelsAndTheNextCleanChordStillFires() {
        var chord = detector()
        _ = chord.modifiersChanged(held: left, at: 0.0)
        _ = chord.modifiersChanged(held: [.leftShift, .leftCommand], at: 0.02)
        _ = chord.modifiersChanged(held: [.leftShift, .leftCommand, .rightShift], at: 0.04)
        XCTAssertEqual(chord.modifiersChanged(held: [], at: 0.1), .none)

        _ = chord.modifiersChanged(held: both, otherModifierHeld: true, at: 1.0)
        XCTAssertEqual(chord.modifiersChanged(held: [], at: 1.1), .none, "Fn was down")

        _ = chord.modifiersChanged(held: left, at: 2.0)
        _ = chord.modifiersChanged(held: both, at: 2.05)
        XCTAssertEqual(chord.modifiersChanged(held: [], at: 2.1), .fire)
    }

    func testOneShiftReleasedBeforeTheOtherGoesDownStartsOver() {
        var chord = detector()
        _ = chord.modifiersChanged(held: left, at: 0.0)
        _ = chord.modifiersChanged(held: [], at: 0.05)
        _ = chord.modifiersChanged(held: right, at: 3.0)
        XCTAssertEqual(chord.modifiersChanged(held: both, at: 3.0625), .armed(gap: 0.0625))
    }

    func testDeviceFlagsTellTheShiftsApart() {
        // Gaps are binary fractions so they subtract exactly.
        // NSEvent flags for both Shifts down: .shift plus the two device bits.
        XCTAssertEqual(SidedModifier.held(inDeviceFlags: 0x0002_0106), both)
        XCTAssertEqual(SidedModifier.held(inDeviceFlags: 0x0002_0102), left)
        XCTAssertEqual(SidedModifier.held(inDeviceFlags: 0x0010_2010), [.rightControl, .rightCommand])
    }

    func testAChordStoresAndReadsBackAndNeedsTwoKeys() {
        XCTAssertEqual(ModifierChord.bothShifts.storageValue, "left_shift+right_shift")
        XCTAssertEqual(ModifierChord(storageValue: "right_shift+left_shift"), .bothShifts)
        XCTAssertEqual(ModifierChord.bothShifts.displayName, "Left ⇧ + Right ⇧")
        XCTAssertNil(ModifierChord(storageValue: "left_shift"))
        XCTAssertNil(ModifierChord(storageValue: "left_shift+caps"))
        XCTAssertNil(ModifierChord(keys: [.rightOption]))
    }
}

final class ModifierChordRecorderTests: XCTestCase {
    func testPressingBothShiftsAndLettingGoRecordsTheChord() {
        var recorder = ModifierChordRecorder()
        XCTAssertEqual(recorder.modifiersChanged(held: [.leftShift], at: 1.0), .none)
        XCTAssertEqual(recorder.modifiersChanged(held: [.leftShift, .rightShift], at: 1.0625), .none)
        XCTAssertEqual(recorder.modifiersChanged(held: [.rightShift], at: 1.25), .none)
        XCTAssertEqual(recorder.modifiersChanged(held: [], at: 1.5), .chord(.bothShifts))
    }

    func testOneModifierOrAModifierWithAKeyRecordsNoChord() {
        var recorder = ModifierChordRecorder()
        _ = recorder.modifiersChanged(held: [.rightOption], at: 0)
        XCTAssertEqual(recorder.modifiersChanged(held: [], at: 0.5), .none)

        _ = recorder.modifiersChanged(held: [.leftShift, .leftCommand], at: 1)
        recorder.keyPressed()
        XCTAssertEqual(recorder.modifiersChanged(held: [], at: 1.5), .none, "that was ⇧⌘ plus a key")

        recorder.keyPressed() // a bare key, refused by the field
        _ = recorder.modifiersChanged(held: [.leftShift, .rightShift], at: 2)
        XCTAssertEqual(
            recorder.modifiersChanged(held: [], at: 2.5), .chord(.bothShifts),
            "an earlier bare key doesn't spoil it")
    }

    /// A chord recorded this slowly would be stored and never fire.
    func testKeysPressedFurtherApartThanTheWindowAreTooSlow() {
        var recorder = ModifierChordRecorder(window: 0.100)
        _ = recorder.modifiersChanged(held: [.leftShift], at: 3.0)
        _ = recorder.modifiersChanged(held: [.leftShift, .rightShift], at: 3.25)
        XCTAssertEqual(recorder.modifiersChanged(held: [], at: 3.5), .tooSlow)
    }
}

/// The dictation key as a chord (#863): a tap toggles, a hold past the hold
/// delay is push to talk. The test plays the timer: it calls
/// `holdDelayElapsed` where the app's hold delay would run out.
final class ModifierChordGestureTests: XCTestCase {
    private let left: Set<SidedModifier> = [.leftShift]
    private let right: Set<SidedModifier> = [.rightShift]
    private let both: Set<SidedModifier> = [.leftShift, .rightShift]

    private func gesture() -> ModifierChordGesture {
        ModifierChordGesture(chord: .bothShifts, window: 0.100)
    }

    func testReleasedBeforeTheHoldDelayIsATap() {
        var key = gesture()
        _ = key.modifiersChanged(held: left, at: 1.0)
        XCTAssertEqual(key.modifiersChanged(held: both, at: 1.03125), .armed(gap: 0.03125, attempt: 1))
        XCTAssertEqual(key.modifiersChanged(held: right, at: 1.25), .none)
        XCTAssertEqual(key.modifiersChanged(held: [], at: 1.3), .tap)
        XCTAssertEqual(key.holdDelayElapsed(attempt: 1), .none, "the delay ran out after the release")
    }

    func testStillDownWhenTheHoldDelayEndsIsAHoldThatEndsWithTheFirstKeyUp() {
        var key = gesture()
        _ = key.modifiersChanged(held: right, at: 1.0)
        XCTAssertEqual(key.modifiersChanged(held: both, at: 1.0625), .armed(gap: 0.0625, attempt: 1))
        XCTAssertEqual(key.holdDelayElapsed(attempt: 1), .holdStart)
        XCTAssertTrue(key.isHolding)
        XCTAssertEqual(key.modifiersChanged(held: left, at: 3.0), .holdEnd)
        XCTAssertFalse(key.isHolding)
        XCTAssertEqual(key.modifiersChanged(held: [], at: 3.03125), .none, "no tap after a hold")

        XCTAssertEqual(key.modifiersChanged(held: both, at: 5.0), .armed(gap: 0, attempt: 2))
        XCTAssertEqual(key.modifiersChanged(held: [], at: 5.125), .tap, "the next press starts afresh")
    }

    func testAShiftHeldWhileTypingIsNeitherATapNorAHold() {
        var key = gesture()
        _ = key.modifiersChanged(held: left, at: 0.0)
        XCTAssertEqual(key.keyPressed(), .none) // H
        XCTAssertEqual(key.modifiersChanged(held: both, at: 0.05), .none, "a letter came first")
        XCTAssertEqual(key.modifiersChanged(held: [], at: 0.2), .none)

        // The second Shift long after the first: too slow, so no timer either.
        _ = key.modifiersChanged(held: left, at: 1.0)
        XCTAssertEqual(key.modifiersChanged(held: both, at: 1.5), .tooSlow(gap: 0.5))
        XCTAssertEqual(key.modifiersChanged(held: [], at: 2.0), .none)
    }

    func testAKeyTypedBeforeTheHoldDelayCancelsBothAndOneTypedDuringAHoldEndsIt() {
        var key = gesture()
        _ = key.modifiersChanged(held: both, at: 0.0)
        XCTAssertEqual(key.keyPressed(), .none)
        XCTAssertEqual(key.holdDelayElapsed(attempt: 1), .none)
        XCTAssertEqual(key.modifiersChanged(held: [], at: 0.5), .none)

        _ = key.modifiersChanged(held: both, at: 1.0)
        XCTAssertEqual(key.holdDelayElapsed(attempt: 2), .holdStart)
        XCTAssertEqual(key.keyPressed(), .holdEnd)
        XCTAssertEqual(key.modifiersChanged(held: [], at: 2.0), .none)
    }

    func testAnotherModifierDuringAHoldEndsIt() {
        var key = gesture()
        _ = key.modifiersChanged(held: both, at: 0.0)
        XCTAssertEqual(key.holdDelayElapsed(attempt: 1), .holdStart)
        XCTAssertEqual(key.modifiersChanged(held: both.union([.leftCommand]), at: 1.0), .holdEnd)
        XCTAssertEqual(key.modifiersChanged(held: [], at: 1.5), .none)
    }

    /// A timer from an earlier press, or one that ends while a key of the
    /// chord is up, starts nothing.
    func testAStaleOrInterruptedHoldDelayStartsNoHold() {
        var key = gesture()
        _ = key.modifiersChanged(held: both, at: 0.0)
        _ = key.modifiersChanged(held: [], at: 0.125)
        _ = key.modifiersChanged(held: both, at: 1.0)
        XCTAssertEqual(key.holdDelayElapsed(attempt: 1), .none, "the first press's timer")

        XCTAssertEqual(key.modifiersChanged(held: left, at: 1.1), .none)
        XCTAssertEqual(key.holdDelayElapsed(attempt: 2), .none, "right Shift is up")
        XCTAssertEqual(key.modifiersChanged(held: [], at: 1.2), .tap)

        _ = key.modifiersChanged(held: both, at: 2.0)
        key.reset()
        XCTAssertEqual(key.holdDelayElapsed(attempt: 3), .none, "reset forgets the press")
    }
}

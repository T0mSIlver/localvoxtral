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
        XCTAssertNil(recorder.modifiersChanged(held: [.leftShift]))
        XCTAssertNil(recorder.modifiersChanged(held: [.leftShift, .rightShift]))
        XCTAssertNil(recorder.modifiersChanged(held: [.rightShift]))
        XCTAssertEqual(recorder.modifiersChanged(held: []), .bothShifts)
    }

    func testOneModifierOrAModifierWithAKeyRecordsNoChord() {
        var recorder = ModifierChordRecorder()
        _ = recorder.modifiersChanged(held: [.rightOption])
        XCTAssertNil(recorder.modifiersChanged(held: []))

        _ = recorder.modifiersChanged(held: [.leftShift, .leftCommand])
        recorder.keyPressed()
        XCTAssertNil(recorder.modifiersChanged(held: []), "that was ⇧⌘ plus a key")

        recorder.keyPressed() // a bare key, refused by the field
        _ = recorder.modifiersChanged(held: [.leftShift, .rightShift])
        XCTAssertEqual(recorder.modifiersChanged(held: []), .bothShifts, "an earlier bare key doesn't spoil it")
    }
}

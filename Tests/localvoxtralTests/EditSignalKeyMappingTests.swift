import AppKit
import Carbon.HIToolbox
import XCTest
@testable import localvoxtral

/// The NSEvent half of the edit signal. The watcher and its ladder run in the
/// core suite, `EditSignalTests`.
final class EditSignalKeyMappingTests: XCTestCase {
    /// The whole recognized alphabet. Everything else must be forgotten — this
    /// is the property that keeps the watch from being a keylogger.
    func testOnlyTwoGesturesAreRecognized() {
        XCTAssertEqual(
            EditSignal.from(keyCode: UInt16(kVK_Delete), modifiers: []), .backspace
        )
        XCTAssertEqual(
            EditSignal.from(keyCode: UInt16(kVK_ForwardDelete), modifiers: []), .backspace
        )
        // A word/line delete is still the user erasing the insertion.
        XCTAssertEqual(
            EditSignal.from(keyCode: UInt16(kVK_Delete), modifiers: [.option]), .backspace
        )
        XCTAssertEqual(
            EditSignal.from(keyCode: UInt16(kVK_ANSI_A), modifiers: [.command]), .selectAll
        )

        // Plain "a" is typing, not selecting.
        XCTAssertNil(EditSignal.from(keyCode: UInt16(kVK_ANSI_A), modifiers: []))
        // ⌥⌘A / ⌃⌘A / ⇧⌘A are app shortcuts, not select-all.
        XCTAssertNil(
            EditSignal.from(keyCode: UInt16(kVK_ANSI_A), modifiers: [.command, .option])
        )
        XCTAssertNil(
            EditSignal.from(keyCode: UInt16(kVK_ANSI_A), modifiers: [.command, .control])
        )
        XCTAssertNil(
            EditSignal.from(keyCode: UInt16(kVK_ANSI_A), modifiers: [.command, .shift])
        )
        // Every other key, modified or not.
        XCTAssertNil(EditSignal.from(keyCode: UInt16(kVK_ANSI_B), modifiers: [.command]))
        XCTAssertNil(EditSignal.from(keyCode: UInt16(kVK_Return), modifiers: []))
        XCTAssertNil(EditSignal.from(keyCode: UInt16(kVK_Escape), modifiers: []))
    }
}

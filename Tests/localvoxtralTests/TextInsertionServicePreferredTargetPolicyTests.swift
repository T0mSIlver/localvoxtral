import XCTest
@testable import localvoxtral

final class TextInsertionServicePreferredTargetPolicyTests: XCTestCase {
    private let selfPID: pid_t = 777

    func testAccessibilityTargetPID_prefersExplicitPreferredPIDOverSystemFocus() {
        let resolved = PreferredTextInsertionTargetPolicy.accessibilityTargetPID(
            systemFocusedPID: 111,
            preferredPID: 222,
            selfPID: selfPID
        )

        XCTAssertEqual(resolved, 222)
    }

    func testAccessibilityTargetPID_withoutPreferredUsesSystemFocus() {
        let resolved = PreferredTextInsertionTargetPolicy.accessibilityTargetPID(
            systemFocusedPID: 111,
            preferredPID: nil,
            selfPID: selfPID
        )

        XCTAssertEqual(resolved, 111)
    }

    func testAccessibilityTargetPID_ignoresSelfFocusWithoutPreferred() {
        let resolved = PreferredTextInsertionTargetPolicy.accessibilityTargetPID(
            systemFocusedPID: selfPID,
            preferredPID: nil,
            selfPID: selfPID
        )

        XCTAssertNil(resolved)
    }

    func testPasteActivationAction_withPreferredAndDifferentFrontmost_requiresActivation() {
        let action = PreferredTextInsertionTargetPolicy.pasteActivationAction(
            frontmostPID: 333,
            preferredPID: 222,
            selfPID: selfPID
        )

        XCTAssertEqual(action, .activate(222))
    }

    func testPasteActivationAction_withPreferredAlreadyFrontmost_usesCurrentFrontmost() {
        let action = PreferredTextInsertionTargetPolicy.pasteActivationAction(
            frontmostPID: 222,
            preferredPID: 222,
            selfPID: selfPID
        )

        XCTAssertEqual(action, .useCurrentFrontmost)
    }

    func testPasteActivationAction_withoutPreferredAndFrontmostSelf_denies() {
        let action = PreferredTextInsertionTargetPolicy.pasteActivationAction(
            frontmostPID: selfPID,
            preferredPID: nil,
            selfPID: selfPID
        )

        XCTAssertEqual(action, .deny)
    }

    func testPasteActivationAction_withoutPreferredAndOtherFrontmost_usesCurrentFrontmost() {
        let action = PreferredTextInsertionTargetPolicy.pasteActivationAction(
            frontmostPID: 444,
            preferredPID: nil,
            selfPID: selfPID
        )

        XCTAssertEqual(action, .useCurrentFrontmost)
    }
}

import Foundation
import XCTest
@testable import localvoxtral

@MainActor
final class AccessibilityTrustManagerTests: XCTestCase {

    func testPromptIfNeeded_promptsOnlyOnce() {
        var promptCount = 0
        let manager = AccessibilityTrustManager(
            trustChecker: { false },
            permissionPrompter: { promptCount += 1 },
            pollingTimeoutSeconds: 0
        )

        manager.promptIfNeeded()
        manager.promptIfNeeded()

        XCTAssertEqual(promptCount, 1)
    }

    func testPromptIfNeeded_whenAlreadyTrusted_doesNotPrompt() {
        var promptCount = 0
        let manager = AccessibilityTrustManager(
            trustChecker: { true },
            permissionPrompter: { promptCount += 1 },
            pollingTimeoutSeconds: 0
        )

        manager.promptIfNeeded()

        XCTAssertEqual(promptCount, 0)
        XCTAssertTrue(manager.isTrusted)
    }

    func testRequestPermission_promptsEveryCall() {
        var promptCount = 0
        let manager = AccessibilityTrustManager(
            trustChecker: { false },
            permissionPrompter: { promptCount += 1 },
            pollingTimeoutSeconds: 0
        )

        manager.requestPermission()
        manager.requestPermission()

        XCTAssertEqual(promptCount, 2)
    }

    func testRefresh_whenTrustBecomesGranted_clearsErrorAndNotifies() {
        var trusted = false
        var trustChangedCount = 0
        let manager = AccessibilityTrustManager(
            trustChecker: { trusted },
            permissionPrompter: {},
            pollingTimeoutSeconds: 0
        )
        manager.onTrustChanged = {
            trustChangedCount += 1
        }
        manager.lastError = AccessibilityTrustManager.errorMessage

        manager.refresh()
        XCTAssertFalse(manager.isTrusted)
        XCTAssertEqual(manager.lastError, AccessibilityTrustManager.errorMessage)

        trusted = true
        manager.refresh()

        XCTAssertTrue(manager.isTrusted)
        XCTAssertNil(manager.lastError)
        XCTAssertEqual(trustChangedCount, 1)
    }

    func testRequestPermission_pollingRefreshesUntilTrusted() async {
        var trusted = false
        var currentDate = Date(timeIntervalSince1970: 1_000)
        var sleepCalls = 0

        let manager = AccessibilityTrustManager(
            trustChecker: { trusted },
            permissionPrompter: {},
            sleepFor: { _ in
                sleepCalls += 1
                trusted = true
                currentDate.addTimeInterval(0.05)
            },
            now: { currentDate },
            pollingInterval: .milliseconds(1),
            pollingTimeoutSeconds: 1
        )

        manager.requestPermission()
        await Task.yield()
        await Task.yield()

        XCTAssertTrue(manager.isTrusted)
        XCTAssertGreaterThanOrEqual(sleepCalls, 1)
    }

    // MARK: - XCTest-pinned defaults (live TCC sampling must never reach tests)

    func testDefaultTrustCheckerIsPinnedTrustedUnderXCTest() {
        // Before the pin this sampled the HOST's live AXIsProcessTrusted() —
        // the whole unit suite went red when a runner auto-update swapped the
        // bundled node binary and invalidated its Accessibility grant
        // (2026-07-24). Deterministic on every host by construction now.
        XCTAssertTrue(AccessibilityTrustManager.defaultTrustChecker())
    }

    func testDefaultInitializedManagerIsTrustedUnderXCTest() {
        // A manager built with the production defaults (no injected checker,
        // the path DictationViewModel takes) must resolve trusted under
        // XCTest so session-start warnings stay deterministic; tests that
        // exercise the untrusted paths pin debugSetTrustOverride(false).
        let manager = AccessibilityTrustManager(pollingTimeoutSeconds: 0)

        manager.refresh()

        XCTAssertTrue(manager.isTrusted)
        XCTAssertNil(manager.lastError)
    }
}

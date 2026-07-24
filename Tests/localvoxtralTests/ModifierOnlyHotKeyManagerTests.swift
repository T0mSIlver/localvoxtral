import AppKit
import Carbon.HIToolbox
import XCTest
@testable import localvoxtral

// NOTE: NSEvent delivery requires a real macOS event session and TCC permissions.
// These tests cover the deterministic seams of ModifierOnlyHotKeyManager
// without requiring actual monitor delivery:
//  - ModifierKey enum surface (rawValues, displayNames, CaseIterable)
//  - Configuration/modifier switching
//  - Stop clears instance gesture state
//  - Rapid sequential start/stop cycles don't leave residual state
//  - Gesture state transitions with simulated flag/key events and injected hold scheduling

@MainActor
final class ModifierOnlyHotKeyManagerTests: XCTestCase {
    // MARK: - ModifierKey Enum

    func testModifierKeyRawValues() {
        XCTAssertEqual(ModifierOnlyHotKeyManager.ModifierKey.fn.rawValue, "fn")
        XCTAssertEqual(ModifierOnlyHotKeyManager.ModifierKey.rightCommand.rawValue, "right_command")
        XCTAssertEqual(ModifierOnlyHotKeyManager.ModifierKey.rightOption.rawValue, "right_option")
    }

    func testModifierKeyDisplayNames() {
        XCTAssertEqual(ModifierOnlyHotKeyManager.ModifierKey.fn.displayName, "Fn / Globe")
        XCTAssertEqual(ModifierOnlyHotKeyManager.ModifierKey.rightCommand.displayName, "Right Command")
        XCTAssertEqual(ModifierOnlyHotKeyManager.ModifierKey.rightOption.displayName, "Right Option")
    }

    func testModifierKeyIdentifiable() {
        for key in ModifierOnlyHotKeyManager.ModifierKey.allCases {
            XCTAssertEqual(key.id, key.rawValue, "id must match rawValue for \(key)")
        }
    }

    func testModifierKeyCaseIterableContainsAllThreeCases() {
        let all = ModifierOnlyHotKeyManager.ModifierKey.allCases
        XCTAssertEqual(all.count, 3)
        XCTAssertTrue(all.contains(.fn))
        XCTAssertTrue(all.contains(.rightCommand))
        XCTAssertTrue(all.contains(.rightOption))
    }

    func testModifierKeyCodableRoundtrip() throws {
        for key in ModifierOnlyHotKeyManager.ModifierKey.allCases {
            let data = try JSONEncoder().encode(key)
            let decoded = try JSONDecoder().decode(ModifierOnlyHotKeyManager.ModifierKey.self, from: data)
            XCTAssertEqual(decoded, key, "Codable roundtrip failed for \(key)")
        }
    }

    // MARK: - Stop Clears All Shared State

    func testStopClearsSharedState() {
        let manager = ModifierOnlyHotKeyManager()
        manager.debugStartGestureForTesting(modifier: .fn)

        manager.stop()

        let snapshot = manager.debugGestureSnapshotForTesting()
        XCTAssertNil(snapshot.targetModifier)
        XCTAssertFalse(snapshot.isModifierDown)
        XCTAssertFalse(snapshot.wasInterruptedByKey)
        XCTAssertFalse(snapshot.isInHoldState)
    }

    func testStopIsIdempotent() {
        let manager = ModifierOnlyHotKeyManager()
        // Multiple stop() calls should not crash
        manager.stop()
        manager.stop()
        manager.stop()
    }

    // MARK: - Modifier Key Switching

    func testModifierKeySwitchingCallsStopBeforeStart() {
        // Calling start() twice with different modifier keys should work without crash.
        let manager = ModifierOnlyHotKeyManager()
        ModifierOnlyHotKeyManager.resetDebugState()
        ModifierOnlyHotKeyManager.forcedStartOutcome = .created
        defer { ModifierOnlyHotKeyManager.resetDebugState() }

        // Each successive start() calls stop() first — no crash expected.
        for modifier in ModifierOnlyHotKeyManager.ModifierKey.allCases {
            manager.start(modifier: modifier)
            XCTAssertEqual(ModifierOnlyHotKeyManager.lastStartOutcome, .created)
        }

        // Clean up
        manager.stop()
    }

    func testRapidStartStopCyclesProduceNoResidualState() {
        let manager = ModifierOnlyHotKeyManager()
        ModifierOnlyHotKeyManager.resetDebugState()
        ModifierOnlyHotKeyManager.forcedStartOutcome = .created
        defer { ModifierOnlyHotKeyManager.resetDebugState() }
        var tapCount = 0
        var holdStartCount = 0
        manager.onTap = { tapCount += 1 }
        manager.onHoldStart = { holdStartCount += 1 }

        for _ in 1...10 {
            manager.start(modifier: .fn)
            manager.stop()
        }

        // After all cycles are stopped, no callbacks should have fired.
        XCTAssertEqual(tapCount, 0, "No tap callbacks should fire in headless test environment")
        XCTAssertEqual(holdStartCount, 0, "No hold callbacks should fire in headless test environment")
        XCTAssertNil(manager.debugGestureSnapshotForTesting().targetModifier)
    }

    func testStopAfterStartWithDifferentModifiersLeavesNoResidualState() {
        let manager1 = ModifierOnlyHotKeyManager()
        let manager2 = ModifierOnlyHotKeyManager()
        ModifierOnlyHotKeyManager.resetDebugState()
        ModifierOnlyHotKeyManager.forcedStartOutcome = .created
        defer { ModifierOnlyHotKeyManager.resetDebugState() }

        manager1.start(modifier: .fn)
        manager2.start(modifier: .rightCommand)

        // Stopping both should be safe and clear their independent state.
        manager1.stop()
        manager2.stop()
    }

    // MARK: - Callback Wiring

    func testCallbacksCanBeAssignedAndReassigned() {
        let manager = ModifierOnlyHotKeyManager()

        var firstTapCount = 0
        manager.onTap = { firstTapCount += 1 }

        var secondTapCount = 0
        manager.onTap = { secondTapCount += 1 }

        // Replacing callbacks is safe — no crash
        XCTAssertEqual(firstTapCount, 0)
        XCTAssertEqual(secondTapCount, 0)
    }

    func testCallbacksCanBeNilledOut() {
        let manager = ModifierOnlyHotKeyManager()
        manager.onTap = { }
        manager.onHoldStart = { }
        manager.onHoldRelease = { }

        manager.onTap = nil
        manager.onHoldStart = nil
        manager.onHoldRelease = nil

        // No crash when callbacks are nil
        manager.stop()
    }

    func testHoldThresholdDefaultValue() {
        let manager = ModifierOnlyHotKeyManager()
        XCTAssertEqual(manager.holdThresholdSeconds, 0.35, accuracy: 0.001)
    }

    func testHoldThresholdCanBeCustomized() {
        let manager = ModifierOnlyHotKeyManager()
        manager.holdThresholdSeconds = 0.5
        XCTAssertEqual(manager.holdThresholdSeconds, 0.5, accuracy: 0.001)
    }

    // MARK: - Gesture State

    func testTapFiresWhenModifierReleasesBeforeHoldThreshold() async {
        let scheduler = HoldSchedulerProbe()
        let manager = ModifierOnlyHotKeyManager(holdScheduler: scheduler.scheduler)
        var tapCount = 0
        var holdStartCount = 0
        var holdReleaseCount = 0
        manager.onTap = { tapCount += 1 }
        manager.onHoldStart = { holdStartCount += 1 }
        manager.onHoldRelease = { holdReleaseCount += 1 }
        manager.debugStartGestureForTesting(modifier: .fn)

        manager.debugHandleFlagsChangedForTesting(
            keyCode: UInt16(kVK_Function),
            flags: .function
        )
        XCTAssertEqual(scheduler.scheduledDelays, [0.35])

        manager.debugHandleFlagsChangedForTesting(
            keyCode: UInt16(kVK_Function),
            flags: []
        )

        XCTAssertEqual(tapCount, 1)
        XCTAssertEqual(holdStartCount, 0)
        XCTAssertEqual(holdReleaseCount, 0)

        scheduler.fireAll()
        XCTAssertEqual(holdStartCount, 0, "stale hold timer must not fire after tap release")
    }

    func testHoldFiresStartThenReleaseWhenThresholdElapsed() async {
        let scheduler = HoldSchedulerProbe()
        let manager = ModifierOnlyHotKeyManager(holdScheduler: scheduler.scheduler)
        var tapCount = 0
        var holdStartCount = 0
        var holdReleaseCount = 0
        manager.onTap = { tapCount += 1 }
        manager.onHoldStart = { holdStartCount += 1 }
        manager.onHoldRelease = { holdReleaseCount += 1 }
        manager.debugStartGestureForTesting(modifier: .rightCommand)

        manager.debugHandleFlagsChangedForTesting(
            keyCode: UInt16(kVK_RightCommand),
            flags: .command
        )
        scheduler.fireAll()

        XCTAssertEqual(holdStartCount, 1)
        XCTAssertEqual(tapCount, 0)

        manager.debugHandleFlagsChangedForTesting(
            keyCode: UInt16(kVK_RightCommand),
            flags: []
        )

        XCTAssertEqual(holdReleaseCount, 1)
        XCTAssertEqual(tapCount, 0)
    }

    func testKeyInterruptionCancelsTapAndPendingHold() async {
        let scheduler = HoldSchedulerProbe()
        let manager = ModifierOnlyHotKeyManager(holdScheduler: scheduler.scheduler)
        var tapCount = 0
        var holdStartCount = 0
        var holdReleaseCount = 0
        manager.onTap = { tapCount += 1 }
        manager.onHoldStart = { holdStartCount += 1 }
        manager.onHoldRelease = { holdReleaseCount += 1 }
        manager.debugStartGestureForTesting(modifier: .rightOption)

        manager.debugHandleFlagsChangedForTesting(
            keyCode: UInt16(kVK_RightOption),
            flags: .option
        )
        manager.debugHandleKeyDownForTesting()
        scheduler.fireAll()

        manager.debugHandleFlagsChangedForTesting(
            keyCode: UInt16(kVK_RightOption),
            flags: []
        )

        XCTAssertEqual(tapCount, 0)
        XCTAssertEqual(holdStartCount, 0)
        XCTAssertEqual(holdReleaseCount, 0)
        XCTAssertFalse(manager.debugGestureSnapshotForTesting().wasInterruptedByKey)
    }

    func testRepeatedPressInvalidatesEarlierHoldTimerByGeneration() async {
        let scheduler = HoldSchedulerProbe()
        let manager = ModifierOnlyHotKeyManager(holdScheduler: scheduler.scheduler)
        var holdStartCount = 0
        manager.onHoldStart = { holdStartCount += 1 }
        manager.debugStartGestureForTesting(modifier: .fn)

        manager.debugHandleFlagsChangedForTesting(
            keyCode: UInt16(kVK_Function),
            flags: .function
        )
        manager.debugHandleFlagsChangedForTesting(
            keyCode: UInt16(kVK_Function),
            flags: []
        )
        manager.debugHandleFlagsChangedForTesting(
            keyCode: UInt16(kVK_Function),
            flags: .function
        )

        XCTAssertEqual(scheduler.scheduledDelays.count, 2)

        scheduler.fire(at: 0)
        XCTAssertEqual(holdStartCount, 0, "first scheduled hold should be stale")

        scheduler.fire(at: 0)
        XCTAssertEqual(holdStartCount, 1)
    }

    func testDoubleTapFiresTwoTapsAndNoHold() {
        let scheduler = HoldSchedulerProbe()
        let manager = ModifierOnlyHotKeyManager(holdScheduler: scheduler.scheduler)
        var tapCount = 0
        var holdStartCount = 0
        manager.onTap = { tapCount += 1 }
        manager.onHoldStart = { holdStartCount += 1 }
        manager.debugStartGestureForTesting(modifier: .fn)

        for _ in 0..<2 {
            manager.debugHandleFlagsChangedForTesting(
                keyCode: UInt16(kVK_Function),
                flags: .function
            )
            manager.debugHandleFlagsChangedForTesting(
                keyCode: UInt16(kVK_Function),
                flags: []
            )
        }

        XCTAssertEqual(tapCount, 2)
        scheduler.fireAll()
        XCTAssertEqual(holdStartCount, 0)
    }

    func testReleaseAtThresholdAfterTimerFiresUsesHoldReleaseNotTap() {
        let scheduler = HoldSchedulerProbe()
        let manager = ModifierOnlyHotKeyManager(holdScheduler: scheduler.scheduler)
        var tapCount = 0
        var holdStartCount = 0
        var holdReleaseCount = 0
        manager.onTap = { tapCount += 1 }
        manager.onHoldStart = { holdStartCount += 1 }
        manager.onHoldRelease = { holdReleaseCount += 1 }
        manager.debugStartGestureForTesting(modifier: .fn)

        manager.debugHandleFlagsChangedForTesting(
            keyCode: UInt16(kVK_Function),
            flags: .function
        )
        scheduler.fireAll()
        manager.debugHandleFlagsChangedForTesting(
            keyCode: UInt16(kVK_Function),
            flags: []
        )

        XCTAssertEqual(tapCount, 0)
        XCTAssertEqual(holdStartCount, 1)
        XCTAssertEqual(holdReleaseCount, 1)
    }

    func testFlagsTimelineInterruptionCancelsPendingHoldWithoutKeyDownDelivery() {
        let scheduler = HoldSchedulerProbe()
        let manager = ModifierOnlyHotKeyManager(holdScheduler: scheduler.scheduler)
        var tapCount = 0
        var holdStartCount = 0
        manager.onTap = { tapCount += 1 }
        manager.onHoldStart = { holdStartCount += 1 }
        manager.debugStartGestureForTesting(modifier: .rightCommand)

        manager.debugHandleFlagsChangedForTesting(
            keyCode: UInt16(kVK_RightCommand),
            flags: .command
        )
        manager.debugHandleFlagsChangedForTesting(
            keyCode: UInt16(kVK_Shift),
            flags: [.command, .shift]
        )
        scheduler.fireAll()
        manager.debugHandleFlagsChangedForTesting(
            keyCode: UInt16(kVK_RightCommand),
            flags: []
        )

        XCTAssertEqual(tapCount, 0)
        XCTAssertEqual(holdStartCount, 0)
    }

    func testKeyInterruptionDuringHoldReleasesImmediatelyAndDoesNotLatch() {
        let scheduler = HoldSchedulerProbe()
        let manager = ModifierOnlyHotKeyManager(holdScheduler: scheduler.scheduler)
        var holdStartCount = 0
        var holdReleaseCount = 0
        manager.onHoldStart = { holdStartCount += 1 }
        manager.onHoldRelease = { holdReleaseCount += 1 }
        manager.debugStartGestureForTesting(modifier: .rightOption)

        manager.debugHandleFlagsChangedForTesting(
            keyCode: UInt16(kVK_RightOption),
            flags: .option
        )
        scheduler.fireAll()
        manager.debugHandleKeyDownForTesting()
        manager.debugHandleFlagsChangedForTesting(
            keyCode: UInt16(kVK_RightOption),
            flags: []
        )

        XCTAssertEqual(holdStartCount, 1)
        XCTAssertEqual(holdReleaseCount, 1)
        XCTAssertFalse(manager.debugGestureSnapshotForTesting().isInHoldState)
    }

    func testSeparateManagerInstancesDoNotClobberEachOther() async {
        let scheduler1 = HoldSchedulerProbe()
        let scheduler2 = HoldSchedulerProbe()
        let manager1 = ModifierOnlyHotKeyManager(holdScheduler: scheduler1.scheduler)
        let manager2 = ModifierOnlyHotKeyManager(holdScheduler: scheduler2.scheduler)
        var manager1TapCount = 0
        var manager2TapCount = 0
        manager1.onTap = { manager1TapCount += 1 }
        manager2.onTap = { manager2TapCount += 1 }

        manager1.debugStartGestureForTesting(modifier: .fn)
        manager2.debugStartGestureForTesting(modifier: .rightCommand)

        manager1.debugHandleFlagsChangedForTesting(
            keyCode: UInt16(kVK_Function),
            flags: .function
        )
        manager1.debugHandleFlagsChangedForTesting(
            keyCode: UInt16(kVK_Function),
            flags: []
        )

        XCTAssertEqual(manager1TapCount, 1)
        XCTAssertEqual(manager2TapCount, 0)

        manager2.debugHandleFlagsChangedForTesting(
            keyCode: UInt16(kVK_RightCommand),
            flags: .command
        )
        manager2.debugHandleFlagsChangedForTesting(
            keyCode: UInt16(kVK_RightCommand),
            flags: []
        )

        XCTAssertEqual(manager1TapCount, 1)
        XCTAssertEqual(manager2TapCount, 1)
    }

    // MARK: - XCTest-pinned start (live TCC sampling must never reach tests)

    func testUnforcedStartUnderXCTestPinsToCreatedWithoutRealMonitors() {
        // No forcedStartOutcome: this exercises start()'s default path, which
        // before the pin sampled the HOST's live Accessibility grant — red
        // whenever a runner auto-update invalidated the grant (2026-07-24),
        // and installing REAL NSEvent monitors when the host happened to be
        // trusted. Both are wrong in a unit suite; the pinned path must
        // report success and touch no monitor APIs.
        let manager = ModifierOnlyHotKeyManager()
        ModifierOnlyHotKeyManager.resetDebugState()
        defer { ModifierOnlyHotKeyManager.resetDebugState() }

        let outcome = manager.start(modifier: .rightCommand)

        XCTAssertEqual(outcome, .created)
        XCTAssertEqual(
            manager.debugInstalledMonitorCount, 0,
            "the XCTest-pinned start() must never install live NSEvent monitors"
        )
        // The pinned registration is a real one from the caller's view:
        // gesture state is configured and stop() tears it down cleanly.
        XCTAssertEqual(manager.debugGestureSnapshotForTesting().targetModifier, .rightCommand)
        manager.stop()
        XCTAssertNil(manager.debugGestureSnapshotForTesting().targetModifier)
    }
}

@MainActor
private final class HoldSchedulerProbe {
    private var delays: [Double] = []
    private var callbacks: [@MainActor @Sendable () -> Void] = []

    var scheduler: ModifierOnlyHotKeyManager.HoldScheduler {
        { [weak self] delay, fire in
            self?.delays.append(delay)
            self?.callbacks.append(fire)
        }
    }

    var scheduledDelays: [Double] {
        delays
    }

    func fire(at index: Int) {
        let callback = callbacks.remove(at: index)
        callback()
    }

    func fireAll() {
        let callbacks = callbacks
        self.callbacks.removeAll()
        callbacks.forEach { $0() }
    }
}

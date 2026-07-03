import Carbon.HIToolbox
import CoreGraphics
import Synchronization
import XCTest
@testable import localvoxtral

// NOTE: CGEventTap creation requires a real macOS event session and TCC permissions.
// These tests cover the deterministic seams of ModifierOnlyHotKeyManager
// without requiring an actual event tap:
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
        // In a headless test env, CGEventTap creation can fail because TCC permissions
        // are missing; start() still records a deterministic outcome and remains safe.
        let manager = ModifierOnlyHotKeyManager()

        // Each successive start() calls stop() first — no crash expected.
        for modifier in ModifierOnlyHotKeyManager.ModifierKey.allCases {
            manager.start(modifier: modifier)
            XCTAssertTrue(
                [.creationFailedNil, .noRunLoopSource, .created].contains(
                    ModifierOnlyHotKeyManager.lastStartOutcome
                ),
                "unexpected start outcome: \(ModifierOnlyHotKeyManager.lastStartOutcome)"
            )
        }

        // Clean up
        manager.stop()
    }

    func testRapidStartStopCyclesProduceNoResidualState() {
        let manager = ModifierOnlyHotKeyManager()
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

        manager1.start(modifier: .fn)
        manager2.start(modifier: .rightCommand)

        // Stopping both should be safe even if one or both starts created a real tap.
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

        manager.debugHandleFlagsChangedForTesting(keyCode: 0, flags: .maskSecondaryFn)
        XCTAssertEqual(scheduler.scheduledDelays, [0.35])

        manager.debugHandleFlagsChangedForTesting(keyCode: 0, flags: CGEventFlags())
        await Task.yield()

        XCTAssertEqual(tapCount, 1)
        XCTAssertEqual(holdStartCount, 0)
        XCTAssertEqual(holdReleaseCount, 0)

        scheduler.fireAll()
        await Task.yield()
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
            keyCode: Int64(kVK_RightCommand),
            flags: .maskCommand
        )
        scheduler.fireAll()
        await Task.yield()

        XCTAssertEqual(holdStartCount, 1)
        XCTAssertEqual(tapCount, 0)

        manager.debugHandleFlagsChangedForTesting(
            keyCode: Int64(kVK_RightCommand),
            flags: CGEventFlags()
        )
        await Task.yield()

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
            keyCode: Int64(kVK_RightOption),
            flags: .maskAlternate
        )
        manager.debugHandleKeyDownForTesting()
        scheduler.fireAll()
        await Task.yield()

        manager.debugHandleFlagsChangedForTesting(
            keyCode: Int64(kVK_RightOption),
            flags: CGEventFlags()
        )
        await Task.yield()

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

        manager.debugHandleFlagsChangedForTesting(keyCode: 0, flags: .maskSecondaryFn)
        manager.debugHandleFlagsChangedForTesting(keyCode: 0, flags: CGEventFlags())
        manager.debugHandleFlagsChangedForTesting(keyCode: 0, flags: .maskSecondaryFn)

        XCTAssertEqual(scheduler.scheduledDelays.count, 2)

        scheduler.fire(at: 0)
        await Task.yield()
        XCTAssertEqual(holdStartCount, 0, "first scheduled hold should be stale")

        scheduler.fire(at: 0)
        await Task.yield()
        XCTAssertEqual(holdStartCount, 1)
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

        manager1.debugHandleFlagsChangedForTesting(keyCode: 0, flags: .maskSecondaryFn)
        manager1.debugHandleFlagsChangedForTesting(keyCode: 0, flags: CGEventFlags())
        await Task.yield()

        XCTAssertEqual(manager1TapCount, 1)
        XCTAssertEqual(manager2TapCount, 0)

        manager2.debugHandleFlagsChangedForTesting(
            keyCode: Int64(kVK_RightCommand),
            flags: .maskCommand
        )
        manager2.debugHandleFlagsChangedForTesting(
            keyCode: Int64(kVK_RightCommand),
            flags: CGEventFlags()
        )
        await Task.yield()

        XCTAssertEqual(manager1TapCount, 1)
        XCTAssertEqual(manager2TapCount, 1)
    }
}

private final class HoldSchedulerProbe: @unchecked Sendable {
    private struct State {
        var delays: [Double] = []
        var callbacks: [@Sendable () -> Void] = []
    }

    private let state = Mutex(State())

    var scheduler: ModifierOnlyHotKeyManager.HoldScheduler {
        { [weak self] delay, fire in
            self?.state.withLock {
                $0.delays.append(delay)
                $0.callbacks.append(fire)
            }
        }
    }

    var scheduledDelays: [Double] {
        state.withLock { $0.delays }
    }

    func fire(at index: Int) {
        let callback = state.withLock { $0.callbacks.remove(at: index) }
        callback()
    }

    func fireAll() {
        let callbacks = state.withLock { state -> [@Sendable () -> Void] in
            let callbacks = state.callbacks
            state.callbacks.removeAll()
            return callbacks
        }
        callbacks.forEach { $0() }
    }
}

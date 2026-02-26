import Foundation
import XCTest
@testable import localvoxtral

#if DEBUG
final class WebSocketClientLifecycleTests: XCTestCase {
    private final class EventCollector: @unchecked Sendable {
        private var events: [RealtimeEvent] = []
        private let lock = NSLock()

        func append(_ event: RealtimeEvent) {
            lock.lock()
            events.append(event)
            lock.unlock()
        }

        func snapshot() -> [RealtimeEvent] {
            lock.lock()
            defer { lock.unlock() }
            return events
        }
    }

    private func makeWebSocketTask() -> (URLSession, URLSessionWebSocketTask) {
        let session = URLSession(configuration: .ephemeral)
        let url = URL(string: "ws://127.0.0.1:65535/test")!
        let task = session.webSocketTask(with: url)
        return (session, task)
    }

    func testRealtimeTerminalErrorCleansSubclassStateAndEmitsErrorThenDisconnected() {
        let client = RealtimeAPIWebSocketClient()
        let collector = EventCollector()
        client.setEventHandler { collector.append($0) }

        let (session, task) = makeWebSocketTask()
        defer {
            task.cancel()
            session.invalidateAndCancel()
        }

        client.debugPrimeConnectedStateForTesting(task: task)
        let before = client.debugStateSnapshot()
        XCTAssertTrue(before.isConnected)
        XCTAssertTrue(before.hasPingTimer)
        XCTAssertTrue(before.hasSessionReadyTimer)
        XCTAssertEqual(before.pendingMessageCount, 1)
        XCTAssertTrue(before.hasUncommittedAudio)
        XCTAssertTrue(before.isGenerationInProgress)

        client.debugHandleTerminalSocketErrorForTesting(task: task, errorMessage: "socket failed")

        let after = client.debugStateSnapshot()
        XCTAssertFalse(after.isConnected)
        XCTAssertFalse(after.hasPingTimer)
        XCTAssertFalse(after.hasSessionReadyTimer)
        XCTAssertEqual(after.pendingMessageCount, 0)
        XCTAssertFalse(after.hasUncommittedAudio)
        XCTAssertFalse(after.isGenerationInProgress)

        let events = collector.snapshot()
        XCTAssertEqual(events.count, 2)
        guard case .error(let message) = events[0] else {
            XCTFail("Expected first event to be .error")
            return
        }
        XCTAssertEqual(message, "socket failed")
        guard case .disconnected = events[1] else {
            XCTFail("Expected second event to be .disconnected")
            return
        }
    }

    func testRealtimeTerminalErrorSuppressesErrorForUserInitiatedDisconnect() {
        let client = RealtimeAPIWebSocketClient()
        let collector = EventCollector()
        client.setEventHandler { collector.append($0) }

        let (session, task) = makeWebSocketTask()
        defer {
            task.cancel()
            session.invalidateAndCancel()
        }

        client.debugPrimeConnectedStateForTesting(task: task, isUserInitiatedDisconnect: true)
        client.debugHandleTerminalSocketErrorForTesting(task: task, errorMessage: "socket failed")

        let after = client.debugStateSnapshot()
        XCTAssertFalse(after.isConnected)
        XCTAssertFalse(after.hasPingTimer)
        XCTAssertFalse(after.hasSessionReadyTimer)
        XCTAssertEqual(after.pendingMessageCount, 0)

        let events = collector.snapshot()
        XCTAssertEqual(events.count, 1)
        guard case .disconnected = events[0] else {
            XCTFail("Expected only .disconnected for user-initiated disconnect")
            return
        }
    }

    func testMlxTerminalErrorCleansSubclassStateAndEmitsErrorThenDisconnected() {
        let client = MlxAudioRealtimeWebSocketClient()
        let collector = EventCollector()
        client.setEventHandler { collector.append($0) }

        let (session, task) = makeWebSocketTask()
        defer {
            task.cancel()
            session.invalidateAndCancel()
        }

        client.debugPrimeConnectedStateForTesting(task: task)
        let before = client.debugStateSnapshot()
        XCTAssertTrue(before.isConnected)
        XCTAssertEqual(before.pendingTextMessageCount, 1)
        XCTAssertEqual(before.pendingBinaryMessageCount, 1)
        XCTAssertTrue(before.hasSentInitialConfiguration)
        XCTAssertTrue(before.hasDelayedDisconnectWorkItem)

        client.debugHandleTerminalSocketErrorForTesting(task: task, errorMessage: "socket failed")

        let after = client.debugStateSnapshot()
        XCTAssertFalse(after.isConnected)
        XCTAssertEqual(after.pendingTextMessageCount, 0)
        XCTAssertEqual(after.pendingBinaryMessageCount, 0)
        XCTAssertFalse(after.hasSentInitialConfiguration)
        XCTAssertFalse(after.hasDelayedDisconnectWorkItem)

        let events = collector.snapshot()
        XCTAssertEqual(events.count, 2)
        guard case .error(let message) = events[0] else {
            XCTFail("Expected first event to be .error")
            return
        }
        XCTAssertEqual(message, "socket failed")
        guard case .disconnected = events[1] else {
            XCTFail("Expected second event to be .disconnected")
            return
        }
    }

    func testMlxTerminalErrorSuppressesErrorForUserInitiatedDisconnect() {
        let client = MlxAudioRealtimeWebSocketClient()
        let collector = EventCollector()
        client.setEventHandler { collector.append($0) }

        let (session, task) = makeWebSocketTask()
        defer {
            task.cancel()
            session.invalidateAndCancel()
        }

        client.debugPrimeConnectedStateForTesting(task: task, isUserInitiatedDisconnect: true)
        client.debugHandleTerminalSocketErrorForTesting(task: task, errorMessage: "socket failed")

        let after = client.debugStateSnapshot()
        XCTAssertFalse(after.isConnected)
        XCTAssertEqual(after.pendingTextMessageCount, 0)
        XCTAssertEqual(after.pendingBinaryMessageCount, 0)
        XCTAssertFalse(after.hasDelayedDisconnectWorkItem)

        let events = collector.snapshot()
        XCTAssertEqual(events.count, 1)
        guard case .disconnected = events[0] else {
            XCTFail("Expected only .disconnected for user-initiated disconnect")
            return
        }
    }

    // MARK: - Stale Task Identity

    func testRealtimeTerminalErrorWithStaleTaskIsNoOp() {
        let client = RealtimeAPIWebSocketClient()
        let collector = EventCollector()
        client.setEventHandler { collector.append($0) }

        let (session1, task1) = makeWebSocketTask()
        let (session2, task2) = makeWebSocketTask()
        defer {
            task1.cancel(); session1.invalidateAndCancel()
            task2.cancel(); session2.invalidateAndCancel()
        }

        // Prime with task1, then send error for task2 (stale/wrong identity)
        client.debugPrimeConnectedStateForTesting(task: task1)
        client.debugHandleTerminalSocketErrorForTesting(task: task2, errorMessage: "stale error")

        let after = client.debugStateSnapshot()
        XCTAssertTrue(after.isConnected, "State should be unchanged for stale task")
        XCTAssertTrue(after.hasPingTimer)
        XCTAssertTrue(after.hasSessionReadyTimer)

        let events = collector.snapshot()
        XCTAssertEqual(events.count, 0, "No events should be emitted for stale task")
    }

    func testMlxTerminalErrorWithStaleTaskIsNoOp() {
        let client = MlxAudioRealtimeWebSocketClient()
        let collector = EventCollector()
        client.setEventHandler { collector.append($0) }

        let (session1, task1) = makeWebSocketTask()
        let (session2, task2) = makeWebSocketTask()
        defer {
            task1.cancel(); session1.invalidateAndCancel()
            task2.cancel(); session2.invalidateAndCancel()
        }

        client.debugPrimeConnectedStateForTesting(task: task1)
        client.debugHandleTerminalSocketErrorForTesting(task: task2, errorMessage: "stale error")

        let after = client.debugStateSnapshot()
        XCTAssertTrue(after.isConnected, "State should be unchanged for stale task")
        XCTAssertTrue(after.hasSentInitialConfiguration)

        let events = collector.snapshot()
        XCTAssertEqual(events.count, 0, "No events should be emitted for stale task")
    }

    // MARK: - Double Disconnect

    func testRealtimeDoubleTerminalErrorIsNoOp() {
        let client = RealtimeAPIWebSocketClient()
        let collector = EventCollector()
        client.setEventHandler { collector.append($0) }

        let (session, task) = makeWebSocketTask()
        defer {
            task.cancel()
            session.invalidateAndCancel()
        }

        client.debugPrimeConnectedStateForTesting(task: task)
        client.debugHandleTerminalSocketErrorForTesting(task: task, errorMessage: "first error")
        client.debugHandleTerminalSocketErrorForTesting(task: task, errorMessage: "second error")

        let events = collector.snapshot()
        XCTAssertEqual(events.count, 2, "Only first error+disconnected pair should be emitted")
        guard case .error(let message) = events[0] else {
            XCTFail("Expected .error"); return
        }
        XCTAssertEqual(message, "first error")
        guard case .disconnected = events[1] else {
            XCTFail("Expected .disconnected"); return
        }
    }

    func testMlxDoubleTerminalErrorIsNoOp() {
        let client = MlxAudioRealtimeWebSocketClient()
        let collector = EventCollector()
        client.setEventHandler { collector.append($0) }

        let (session, task) = makeWebSocketTask()
        defer {
            task.cancel()
            session.invalidateAndCancel()
        }

        client.debugPrimeConnectedStateForTesting(task: task)
        client.debugHandleTerminalSocketErrorForTesting(task: task, errorMessage: "first error")
        client.debugHandleTerminalSocketErrorForTesting(task: task, errorMessage: "second error")

        let events = collector.snapshot()
        XCTAssertEqual(events.count, 2, "Only first error+disconnected pair should be emitted")
        guard case .error(let message) = events[0] else {
            XCTFail("Expected .error"); return
        }
        XCTAssertEqual(message, "first error")
        guard case .disconnected = events[1] else {
            XCTFail("Expected .disconnected"); return
        }
    }
}
#endif

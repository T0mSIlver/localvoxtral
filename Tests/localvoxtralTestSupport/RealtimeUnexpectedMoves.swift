import XCTest
import localvoxtralCore

#if DEBUG
extension BaseRealtimeWebSocketClient {
    /// Fails the running test on every handshake or final-commit move the
    /// client's `canMove` tables refuse.
    package func failTestOnUnexpectedMoves(file: StaticString = #filePath, line: UInt = #line) {
        debugObserveUnexpectedMoves { move in
            XCTFail("unexpected realtime client move: \(move)", file: file, line: line)
        }
    }
}
#endif

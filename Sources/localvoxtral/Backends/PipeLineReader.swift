import Foundation

/// Reads newline-delimited child-process output without FileHandle APIs that
/// can raise an uncatchable Objective-C exception when a descriptor closes.
final class PipeLineReader: @unchecked Sendable {
    private let fileHandle: FileHandle
    private let descriptor: Int32
    private let onLine: @Sendable (String) -> Void
    private let state = PipeLineReaderState()
    private var thread: Thread?

    init(fileHandle: FileHandle, onLine: @Sendable @escaping (String) -> Void) {
        self.fileHandle = fileHandle
        self.descriptor = fileHandle.fileDescriptor
        self.onLine = onLine
    }

    func start() {
        let descriptor = descriptor
        let fileHandle = fileHandle
        let onLine = onLine
        let state = state
        let thread = Thread {
            withExtendedLifetime(fileHandle) {}
            var buffer = Data()
            while true {
                let chunk = POSIXPipeRead.nextChunk(fromDescriptor: descriptor)
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer[..<newlineIndex]
                    buffer.removeSubrange(...newlineIndex)
                    if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                        onLine(line)
                    }
                }
            }
            if !buffer.isEmpty,
               let line = String(data: buffer, encoding: .utf8),
               !line.isEmpty
            {
                onLine(line)
            }
            state.markFinished()
        }
        self.thread = thread
        thread.start()
    }

    func waitUntilFinished() {
        state.waitUntilFinished()
    }
}

private final class PipeLineReaderState: @unchecked Sendable {
    private let condition = NSCondition()
    private var isFinished = false

    func markFinished() {
        condition.lock()
        isFinished = true
        condition.signal()
        condition.unlock()
    }

    func waitUntilFinished() {
        condition.lock()
        while !isFinished { condition.wait() }
        condition.unlock()
    }
}

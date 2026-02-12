import Foundation

final class AudioChunkBuffer: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        buffer.append(chunk)
        lock.unlock()
    }

    func takeAll() -> Data {
        lock.lock()
        defer { lock.unlock() }

        let output = buffer
        buffer.removeAll(keepingCapacity: true)
        return output
    }

    func clear() {
        lock.lock()
        buffer.removeAll(keepingCapacity: true)
        lock.unlock()
    }
}

import Foundation
import Synchronization

final class AudioChunkBuffer: Sendable {
    private let buffer = Mutex(Data())

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        buffer.withLock { $0.append(chunk) }
    }

    func takeAll() -> Data {
        buffer.withLock {
            let output = $0
            $0.removeAll(keepingCapacity: true)
            return output
        }
    }

    func clear() {
        buffer.withLock { $0.removeAll(keepingCapacity: true) }
    }
}

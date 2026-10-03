import Foundation
import Synchronization

/// A RIFF/WAVE file around `pcm`, every header field settable so a test can
/// build the formats `DogfoodAudioFileSource` refuses.
package enum DogfoodWAV {
    package static func make(
        pcm: Data,
        formatCode: UInt16 = 1,
        channels: UInt16 = 1,
        sampleRate: UInt32 = 16_000,
        bitsPerSample: UInt16 = 16,
        includeFormat: Bool = true,
        extraChunkBeforeData: (id: String, body: Data)? = nil
    ) -> Data {
        func le16(_ value: UInt16) -> Data { Data([UInt8(value & 0xFF), UInt8(value >> 8)]) }
        func le32(_ value: UInt32) -> Data {
            Data((0..<4).map { UInt8((value >> (8 * UInt32($0))) & 0xFF) })
        }
        func chunk(_ id: String, _ body: Data) -> Data {
            var data = Data(id.utf8) + le32(UInt32(body.count)) + body
            if !body.count.isMultiple(of: 2) { data.append(0) }
            return data
        }

        var body = Data("WAVE".utf8)
        if includeFormat {
            let blockAlign = channels * bitsPerSample / 8
            body += chunk(
                "fmt ",
                le16(formatCode) + le16(channels) + le32(sampleRate)
                    + le32(sampleRate * UInt32(blockAlign)) + le16(blockAlign)
                    + le16(bitsPerSample))
        }
        if let extraChunkBeforeData {
            body += chunk(extraChunkBeforeData.id, extraChunkBeforeData.body)
        }
        body += chunk("data", pcm)
        return Data("RIFF".utf8) + le32(UInt32(body.count)) + body
    }
}

/// A sleep that parks the producer until the test releases it, and IGNORES
/// cancellation while parked: the worst sleep a stop has to hold against. Once
/// released, a parked sleep returns normally and any later sleep throws, so a
/// producer that outlived its stop delivers one more chunk and then ends,
/// which fails the count assertion instead of hanging the suite.
package final class DogfoodSleepGate: Sendable {
    private struct State {
        var entries = 0
        var released = false
        var sleepers: [CheckedContinuation<Void, Never>] = []
        var entryWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    }

    private let state = Mutex(State())

    package init() {}

    package func sleep() async throws {
        if state.withLock({ $0.released }) { throw CancellationError() }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let (resumeNow, reached) = state.withLock {
                state -> (Bool, [CheckedContinuation<Void, Never>]) in
                state.entries += 1
                let reached = state.entryWaiters.filter { $0.count <= state.entries }
                state.entryWaiters.removeAll { $0.count <= state.entries }
                if state.released { return (true, reached.map(\.continuation)) }
                state.sleepers.append(continuation)
                return (false, reached.map(\.continuation))
            }
            reached.forEach { $0.resume() }
            if resumeNow { continuation.resume() }
        }
    }

    /// Returns once `count` sleeps have been entered, which is also once
    /// `count` chunks have been delivered by producers that are now parked.
    package func waitForEntries(_ count: Int) async {
        await withCheckedContinuation { continuation in
            let resumeNow = state.withLock { state -> Bool in
                guard state.entries < count else { return true }
                state.entryWaiters.append((count, continuation))
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    package func release() {
        let sleepers = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.released = true
            defer { state.sleepers = [] }
            return state.sleepers
        }
        sleepers.forEach { $0.resume() }
    }
}

package final class DogfoodChunkCollector: Sendable {
    private struct State {
        var chunks: [Data] = []
        var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    }

    private let state = Mutex(State())

    package init() {}

    package var chunks: [Data] { state.withLock { $0.chunks } }

    package func append(_ chunk: Data) {
        let ready = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.chunks.append(chunk)
            let reached = state.waiters.filter { $0.count <= state.chunks.count }
            state.waiters.removeAll { $0.count <= state.chunks.count }
            return reached.map(\.continuation)
        }
        ready.forEach { $0.resume() }
    }

    package func waitForChunks(_ count: Int) async {
        await withCheckedContinuation { continuation in
            let resumeNow = state.withLock { state -> Bool in
                guard state.chunks.count < count else { return true }
                state.waiters.append((count, continuation))
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }
}

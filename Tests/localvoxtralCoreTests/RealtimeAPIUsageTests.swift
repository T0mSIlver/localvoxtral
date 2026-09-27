import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import localvoxtralCore

#if DEBUG
/// The speechd and External URL socket's line in the usage ledger (#853).
final class RealtimeAPIUsageTests: XCTestCase {
    private static let date = Date(timeIntervalSince1970: 1_790_000_000)

    /// One second of 16 kHz mono S16 PCM.
    private let oneSecond = Data(count: 32_000)

    private func makePrimedClient(
        backend: UsageEntry.Backend?, model: String = "voxtral-mini-4b", sessionCreated: Bool = true
    ) -> (RealtimeAPIWebSocketClient, UsageLedger, () -> Void) {
        let client = RealtimeAPIWebSocketClient(usageDate: { Self.date })
        let ledger = UsageLedger(fileURL: nil)
        client.setUsageRecorder(ledger)
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: URL(string: "ws://127.0.0.1:65535/test")!)
        client.debugPrimeConnectedStateForTesting(
            task: task,
            isUserInitiatedDisconnect: true,
            hasReceivedSessionCreated: sessionCreated,
            usageBackend: backend,
            usageModel: model
        )
        return (client, ledger, {
            task.cancel()
            session.invalidateAndCancel()
        })
    }

    func testAFinishedDictationWritesOneUnpricedEntryForItsBackend() throws {
        for backend in [UsageEntry.Backend.bundledHelper, .userServer] {
            let (client, ledger, cleanup) = makePrimedClient(backend: backend)
            defer { cleanup() }

            client.sendAudioChunk(oneSecond)
            client.sendAudioChunk(oneSecond)
            client.sendCommit(final: true)
            client.disconnect()
            client.disconnect()

            XCTAssertEqual(
                ledger.entries(),
                [UsageEntry(
                    date: Self.date, feature: .dictation, backend: backend, model: "voxtral-mini-4b",
                    audioSeconds: 2
                )],
                "\(backend)"
            )
        }
    }

    func testASocketThatSentNoAudioWritesNothing() {
        let (client, ledger, cleanup) = makePrimedClient(backend: .bundledHelper)
        defer { cleanup() }

        client.sendCommit(final: true)
        client.disconnect()

        XCTAssertEqual(ledger.entries(), [])
    }

    func testAudioQueuedBeforeTheHandshakeCountsOnlyOnceSent() throws {
        let (client, ledger, cleanup) = makePrimedClient(backend: .userServer, sessionCreated: false)
        defer { cleanup() }

        client.sendAudioChunk(oneSecond)
        client.disconnect()

        XCTAssertEqual(ledger.entries(), [], "queued audio never reached the server")
    }

    func testASocketFailureRecordsTheAudioSentBeforeIt() throws {
        let client = RealtimeAPIWebSocketClient(usageDate: { Self.date })
        let ledger = UsageLedger(fileURL: nil)
        client.setUsageRecorder(ledger)
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: URL(string: "ws://127.0.0.1:65535/test")!)
        defer {
            task.cancel()
            session.invalidateAndCancel()
        }
        client.debugPrimeConnectedStateForTesting(
            task: task, isUserInitiatedDisconnect: true, hasReceivedSessionCreated: true,
            usageBackend: .bundledHelper, usageModel: "m")

        client.sendAudioChunk(oneSecond)
        client.debugHandleTerminalSocketErrorForTesting(task: task, errorMessage: "boom")
        client.disconnect()

        XCTAssertEqual(ledger.entries().map(\.audioSeconds), [1])
    }

    func testASocketWithNoBackendOrAServerWithNoModelName() throws {
        let (silent, silentLedger, cleanupSilent) = makePrimedClient(backend: nil)
        defer { cleanupSilent() }
        silent.sendAudioChunk(oneSecond)
        silent.disconnect()
        XCTAssertEqual(silentLedger.entries(), [], "no backend, no line")

        let (unnamed, ledger, cleanup) = makePrimedClient(backend: .userServer, model: "")
        defer { cleanup() }
        unnamed.sendAudioChunk(oneSecond)
        unnamed.disconnect()
        XCTAssertEqual(ledger.entries().map(\.model), ["default"])
    }

    func testTheLedgerPricesOnlyAMistralSocketAndItsSummaryIgnoresTheRest() throws {
        let ledger = UsageLedger(fileURL: nil)
        ledger.recordRealtimeDictation(
            date: Self.date, backend: .mistral, model: MistralRealtimeWebSocketClient.defaultModel,
            audioSeconds: 60)
        ledger.recordRealtimeDictation(
            date: Self.date, backend: .bundledHelper, model: MistralRealtimeWebSocketClient.defaultModel,
            audioSeconds: 60)

        let entries = ledger.entries()
        XCTAssertNotNil(entries[0].costEUR)
        XCTAssertNil(entries[1].costEUR)
        XCTAssertEqual(entries.map(\.backend), [.mistral, .bundledHelper])
        let summary = MistralUsageSummary(entries: entries, since: nil)
        XCTAssertEqual(summary.dictationCount, 1)
        XCTAssertEqual(summary.audioSeconds, 60)
    }
}
#endif

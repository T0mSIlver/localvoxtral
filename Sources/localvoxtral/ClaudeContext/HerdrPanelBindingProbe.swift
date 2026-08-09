import Foundation
import Synchronization

enum HerdrPanelBindingAbstention: String, Sendable, Equatable {
    case rowNotRendered = "row-not-rendered"
    case gridReadUnavailable = "ax-read-unavailable"
    case stampRefused = "stamp-refused"
    case settleTimeout = "settle-timeout"
    case forwardUnavailable = "forward-unavailable"
    case speculativeForwardUnavailable = "forward-unavailable-for-speculative-candidate"
    case multiHostDoubleMatch = "multi-host-double-match"
}

enum HerdrPanelConfigurationStatus: Sendable, Equatable {
    case ok
    case likelyNotConfigured

    var message: String? {
        switch self {
        case .ok: return nil
        case .likelyNotConfigured:
            return "The herdr agents-panel row may need setup."
        }
    }
}

protocol HerdrPanelMetadataReporting: Sendable {
    func reportPanelToken(
        socketPath: String,
        paneID: String,
        value: String?,
        ttlMilliseconds: Int?
    ) async -> Bool
}

/// Positive proof that the focused terminal surface renders an App-mode client
/// for the herdr server reached through `socketPath`.
///
/// The nonce is stamped into the focused pane's agents-panel metadata and then
/// read back through the terminal's existing focused-grid route. A raw string
/// match is safe here only because the value is fresh, private to this socket
/// exchange, short-lived, and unguessable (the production nonce retains more
/// than 40 random bits). A terminal-attach/observe client never renders the
/// sidebar and therefore cannot echo the token through this route.
@MainActor
struct HerdrPanelBindingProbe {
    struct Match: Sendable, Equatable {
        let token: String
    }

    enum Outcome: Sendable, Equatable {
        case matched(Match)
        case noMatch(HerdrPanelBindingAbstention)
    }

    typealias GridRead = @MainActor @Sendable (TerminalScreenTarget) -> String?
    typealias Now = @MainActor @Sendable () -> Date
    typealias SleepFor = @Sendable (TimeInterval) async -> Void
    typealias RandomBits = @MainActor @Sendable () -> UInt64

    static let tokenTTLMilliseconds = 8_000
    static let settleDelay: TimeInterval = 0.12
    static let settleBudget: TimeInterval = 0.5
    static let maxGridReads = 2

    private let metadata: any HerdrPanelMetadataReporting
    private let readGrid: GridRead
    private let now: Now
    private let sleepFor: SleepFor
    private let randomBits: RandomBits

    init(
        metadata: any HerdrPanelMetadataReporting,
        readGrid: @escaping GridRead,
        now: @escaping Now = Date.init,
        sleepFor: @escaping SleepFor = { seconds in
            try? await Task.sleep(for: .seconds(seconds))
        },
        randomBits: @escaping RandomBits = {
            var generator = SystemRandomNumberGenerator()
            return generator.next()
        }
    ) {
        self.metadata = metadata
        self.readGrid = readGrid
        self.now = now
        self.sleepFor = sleepFor
        self.randomBits = randomBits
    }

    func probe(
        target: TerminalScreenTarget,
        socketPath: String,
        paneID: String
    ) async -> Outcome {
        let token = Self.token(randomBits: randomBits())
        guard await metadata.reportPanelToken(
            socketPath: socketPath,
            paneID: paneID,
            value: token,
            ttlMilliseconds: Self.tokenTTLMilliseconds
        ) else {
            return .noMatch(.stampRefused)
        }

        let startedAt = now()
        for readIndex in 0..<Self.maxGridReads {
            guard let grid = readGrid(target) else {
                return .noMatch(.gridReadUnavailable)
            }
            if grid.contains(token) {
                return .matched(Match(token: token))
            }

            guard readIndex + 1 < Self.maxGridReads else {
                Self.noteAbstention(.rowNotRendered)
                return .noMatch(.settleTimeout)
            }
            await sleepFor(Self.settleDelay)
            guard now().timeIntervalSince(startedAt) <= Self.settleBudget else {
                Self.noteAbstention(.rowNotRendered)
                return .noMatch(.settleTimeout)
            }
        }
        Self.noteAbstention(.rowNotRendered)
        return .noMatch(.settleTimeout)
    }

    static func clear(
        metadata: any HerdrPanelMetadataReporting,
        socketPath: String,
        paneID: String
    ) async {
        // JSON null is an intentional wire-level clear. In herdr source,
        // PaneReportMetadataParams.tokens is HashMap<String, Option<String>>
        // (src/api/schema/panes.rs:365), and normalize_metadata_tokens tests
        // pin both None and "" as clears (src/app/api_helpers.rs:290-299).
        _ = await metadata.reportPanelToken(
            socketPath: socketPath,
            paneID: paneID,
            value: nil,
            ttlMilliseconds: nil
        )
    }

    static func token(randomBits: UInt64) -> String {
        // Ten base-36 digits retain log2(36^10) ~= 51.7 bits. Keeping the low
        // ten digits also makes the length fixed and leaves the complete
        // `lv-mic-` token at 17 columns, under herdr's 22-column continuation
        // row budget.
        let digits = String(randomBits, radix: 36, uppercase: false)
        let suffix = String(digits.suffix(10))
        return "lv-mic-" + String(repeating: "0", count: 10 - suffix.count) + suffix
    }

    static func noteAbstention(_ cause: HerdrPanelBindingAbstention) {
        Log.claudeContext.info(
            "Remote herdr panel binding abstained (\(cause.rawValue, privacy: .public))"
        )
        #if LOCALVOXTRAL_DOGFOOD
        DogfoodCaptureTap.shared.noteJoinAbstention("remoteHerdrPanel: \(cause.rawValue)")
        #endif
    }
}

/// Keeps a successfully matched panel token visible as the dictation's mic
/// indicator. The view model starts and stops this lease alongside the forward
/// it owns; tests inject `sleepFor`, so no assertion depends on wall clock.
final class HerdrPanelMicIndicator: @unchecked Sendable, Equatable {
    typealias SleepFor = @Sendable (TimeInterval) async -> Void

    static let refreshInterval: TimeInterval = 4

    private struct State {
        var started = false
        var stopped = false
        var task: Task<Void, Never>?
        var stopTask: Task<Void, Never>?
    }

    private let state = Mutex(State())
    private let metadata: any HerdrPanelMetadataReporting
    private let socketPath: String
    private let paneID: String
    private let token: String
    private let forward: ClaudeRemoteHerdrForwardHandle
    private let sleepFor: SleepFor

    init(
        metadata: any HerdrPanelMetadataReporting,
        socketPath: String,
        paneID: String,
        token: String,
        forward: ClaudeRemoteHerdrForwardHandle,
        sleepFor: @escaping SleepFor = { seconds in
            try? await Task.sleep(for: .seconds(seconds))
        }
    ) {
        self.metadata = metadata
        self.socketPath = socketPath
        self.paneID = paneID
        self.token = token
        self.forward = forward
        self.sleepFor = sleepFor
    }

    static func == (lhs: HerdrPanelMicIndicator, rhs: HerdrPanelMicIndicator) -> Bool {
        lhs === rhs
    }

    func start() {
        let shouldStart = state.withLock { state in
            guard !state.started, !state.stopped else { return false }
            state.started = true
            return true
        }
        guard shouldStart else { return }

        // Keep the task behind a one-value gate until its handle is recorded.
        // Without this, an immediate teardown on another thread can clear the
        // token while an unrecorded first refresh races in afterwards.
        let (startSignal, startContinuation) = AsyncStream.makeStream(of: Void.self)
        let task = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            var startIterator = startSignal.makeAsyncIterator()
            guard await startIterator.next() != nil, !Task.isCancelled else { return }
            while true {
                await self.sleepFor(Self.refreshInterval)
                guard !Task.isCancelled,
                      self.state.withLock({ !$0.stopped })
                else { return }
                let refreshed = await self.refreshOnce()
                if !refreshed {
                    Log.claudeContext.info("Remote herdr mic indicator refresh was refused")
                }
            }
        }
        state.withLock { state in
            if state.stopped {
                task.cancel()
            } else {
                state.task = task
            }
        }
        startContinuation.yield()
        startContinuation.finish()
    }

    /// Idempotent. Clear is attempted while the forward is still open, and the
    /// forward closes only after that bounded socket request returns.
    func stop() {
        _ = makeStopTask()
    }

    @discardableResult
    func refreshOnce() async -> Bool {
        guard state.withLock({ !$0.stopped }) else { return false }
        return await metadata.reportPanelToken(
            socketPath: socketPath,
            paneID: paneID,
            value: token,
            ttlMilliseconds: HerdrPanelBindingProbe.tokenTTLMilliseconds
        )
    }

    /// Async seam used by deterministic tests; production calls `stop()`,
    /// which performs this same bounded sequence off the main actor.
    func stopAndWait() async {
        await makeStopTask().value
    }

    /// Every caller shares one teardown task. In particular, a test awaiting
    /// `stopAndWait()` after view-model teardown must wait for the clear/close
    /// that `stop()` already started rather than returning at `stopped == true`.
    private func makeStopTask() -> Task<Void, Never> {
        let metadata = metadata
        let socketPath = socketPath
        let paneID = paneID
        let forward = forward
        return state.withLock { state in
            if let stopTask = state.stopTask { return stopTask }
            state.stopped = true
            let refreshTask = state.task
            state.task = nil
            refreshTask?.cancel()
            let stopTask = Task.detached(priority: .utility) {
                // A refresh may already be inside the socket request when
                // teardown begins. Wait for it before clearing so a late
                // refresh can never recreate the token after the clear.
                await refreshTask?.value
                await HerdrPanelBindingProbe.clear(
                    metadata: metadata,
                    socketPath: socketPath,
                    paneID: paneID
                )
                forward.close()
            }
            state.stopTask = stopTask
            return stopTask
        }
    }
}

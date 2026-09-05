import Foundation
import Synchronization

enum HerdrPanelBindingAbstention: String, Sendable, Equatable {
    case rowNotRendered = "row-not-rendered"
    case rowTruncated = "row-truncated"
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
    /// The stamp must cross the forward, herdr must paint a frame, ssh must
    /// carry it back, and the terminal must render it — over a ProxyJump
    /// chain that is several hundred milliseconds end to end. The first field
    /// dictation (2026-08-09) timed out at two reads ~120 ms apart while the
    /// row was visibly rendering moments later; the budget below is what the
    /// loop actually honors now, with `maxGridReads` only as a hard cap so a
    /// test clock that never advances cannot loop forever.
    static let settleBudget: TimeInterval = 1.0
    static let maxGridReads = 9

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
        var lastGrid = ""
        for readIndex in 0..<Self.maxGridReads {
            guard let grid = readGrid(target) else {
                return .noMatch(.gridReadUnavailable)
            }
            switch Self.renderedMatch(grid: grid, token: token) {
            case .full, .truncatedButSufficient:
                return .matched(Match(token: token))
            case .truncatedTooShort:
                // Polling cannot grow a column budget. This is the row
                // rendering CORRECTLY and being cut by herdr's own
                // `truncate_end`, which is a different fault from "no token in
                // the grid" and has a different fix, so it ends the attempt
                // with its own cause instead of burning the settle budget.
                Self.noteAbstention(.rowTruncated)
                return .noMatch(.rowTruncated)
            case .absent:
                break
            }

            guard readIndex + 1 < Self.maxGridReads else {
                Self.noteRowNotRendered(grid: grid)
                return .noMatch(.settleTimeout)
            }
            await sleepFor(Self.settleDelay)
            guard now().timeIntervalSince(startedAt) <= Self.settleBudget else {
                Self.noteRowNotRendered(grid: grid)
                return .noMatch(.settleTimeout)
            }
            lastGrid = grid
        }
        Self.noteRowNotRendered(grid: lastGrid)
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

    /// The fixed, rendered prefix every token carries.
    static let tokenPrefix = "lv-mic-"
    /// Base-36 digits after the prefix. Ten of them retain log2(36^10) ~= 51.7
    /// bits, so the whole token is 17 columns wide.
    static let tokenNonceDigits = 10
    /// The FEWEST nonce digits a rendered token may retain and still be
    /// evidence: log2(36^8) ~= 41.4 bits, which keeps the "more than 40 random
    /// bits" bound `docs/agent/invariants.md` states for this authorization.
    /// Below it the probe abstains rather than accepting weaker proof.
    static let minimumRenderedNonceDigits = 8

    /// How much of a stamped token the focused grid actually carries.
    ///
    /// herdr renders an agents-panel row through `truncate_end(text, budget)`
    /// (`src/ui/text.rs`), where the budget is the sidebar body width minus 1
    /// for an entry's FIRST row and minus 3 for every continuation row
    /// (`src/ui/sidebar.rs`, agent panel render). The sidebar width is the
    /// user's — herdr's own default is 26 but it is drag-resizable down to
    /// `sidebar_min_width` (18), and a scrollbar takes one more column. A
    /// 17-column token therefore does NOT fit a continuation row on a sidebar
    /// narrower than 21 columns, and herdr replaces the tail with `…`.
    /// Measured on the owner's Mac 2026-09-05: sidebar width 20, the token
    /// rendered as `lv-mic-<8 digits>…` and an exact-string match could never
    /// succeed — the join abstained as "row-not-rendered" while the row was
    /// visibly rendering.
    ///
    /// So the match is on the longest rendered PREFIX, floored at
    /// `minimumRenderedNonceDigits`. That floor is what keeps the trust
    /// argument intact: a shorter run is not accepted, it is refused with its
    /// own cause.
    enum RenderedTokenMatch: Sendable, Equatable {
        case full
        case truncatedButSufficient(retainedDigits: Int)
        case truncatedTooShort(retainedDigits: Int)
        case absent
    }

    /// Reads the WHOLE nonce run each `lv-mic-` occurrence carries, rather than
    /// asking whether some prefix appears somewhere.
    ///
    /// The difference is not stylistic. A prefix search matches a DIFFERENT
    /// token whenever the two share leading digits — `lv-mic-0000000005`'s
    /// nine-digit prefix is inside `lv-mic-0000000006` — which would let one
    /// socket's stamp be confirmed by another socket's rendering, exactly the
    /// disambiguation `testTwoLiveSocketsResolveToTheOneWhoseNonceRenders`
    /// exists to hold. Taking the maximal base-36 run after the prefix and
    /// requiring it to be OUR nonce, or a proper prefix of it, cannot do that:
    /// herdr's truncation ends the run with `…`, so a run that continues into
    /// another digit is another token.
    static func renderedMatch(grid: String, token: String) -> RenderedTokenMatch {
        guard token.hasPrefix(tokenPrefix) else { return .absent }
        let nonce = Array(token.dropFirst(tokenPrefix.count))
        guard !nonce.isEmpty else { return .absent }

        let characters = Array(grid)
        let prefix = Array(tokenPrefix)
        var best: RenderedTokenMatch = .absent
        var bestRetained = 0
        var start = 0
        while start + prefix.count <= characters.count {
            guard Array(characters[start..<(start + prefix.count)]) == prefix else {
                start += 1
                continue
            }
            var end = start + prefix.count
            while end < characters.count, Self.isNonceCharacter(characters[end]) { end += 1 }
            let run = Array(characters[(start + prefix.count)..<end])
            if run.count <= nonce.count, run == Array(nonce.prefix(run.count)), !run.isEmpty {
                if run.count == nonce.count { return .full }
                if run.count > bestRetained {
                    bestRetained = run.count
                    best = run.count >= minimumRenderedNonceDigits
                        ? .truncatedButSufficient(retainedDigits: run.count)
                        : .truncatedTooShort(retainedDigits: run.count)
                }
            }
            start += 1
        }
        return best
    }

    private static func isNonceCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isNumber || ("a"..."z").contains(character))
    }

    /// The shape of the grid that was read, as two COUNTS.
    ///
    /// `row-not-rendered` has at least four causes on the remote side — the row
    /// is not configured, the token was cut to the column budget, the agent
    /// entry did not fit the panel body at this client's height, or the sidebar
    /// is collapsed — and the Mac cannot tell them apart. herdr exposes no
    /// client introspection and no config read, so every discriminator would be
    /// a threshold guess over remote-influenceable text, which is exactly the
    /// kind of confidently-wrong diagnostic this area has already paid for.
    ///
    /// What the app DOES have for free is the geometry of the grid it just
    /// read, and two integers are usually the whole answer: an 80x24 client
    /// cannot show a six-row agent entry below a workspace list, and a 133x50
    /// one can (both measured on the owner's Mac, 2026-09-05, same config —
    /// the small one abstained and the large one matched). Counts only, never
    /// content, so this stays inside what the shipped app logs.
    static func gridGeometry(_ grid: String) -> (rows: Int, columns: Int) {
        let lines = grid.split(separator: "\n", omittingEmptySubsequences: false)
        return (rows: lines.count, columns: lines.map(\.count).max() ?? 0)
    }

    static func token(randomBits: UInt64) -> String {
        // Ten base-36 digits retain log2(36^10) ~= 51.7 bits. Keeping the low
        // ten digits also makes the length fixed, at 17 columns including the
        // `lv-mic-` prefix. That fits an agent entry's FIRST panel row at
        // herdr's default sidebar width; narrower sidebars and continuation
        // rows truncate it, which `renderedMatch` is what handles.
        let digits = String(randomBits, radix: 36, uppercase: false)
        let suffix = String(digits.suffix(tokenNonceDigits))
        return tokenPrefix
            + String(repeating: "0", count: tokenNonceDigits - suffix.count)
            + suffix
    }

    /// `row-not-rendered`, with the one fact that separates its causes in
    /// practice and costs nothing to obtain.
    static func noteRowNotRendered(grid: String) {
        let geometry = gridGeometry(grid)
        Log.claudeContext.info(
            """
            Remote herdr panel row not rendered in a \
            \(geometry.columns, privacy: .public)x\(geometry.rows, privacy: .public) grid
            """
        )
        noteAbstention(.rowNotRendered)
    }

    static func noteAbstention(_ cause: HerdrPanelBindingAbstention) {
        Log.claudeContext.info(
            "Remote herdr panel binding abstained (\(cause.rawValue, privacy: .public))"
        )
        let noted = "remoteHerdrPanel: \(cause.rawValue)"
        ClaudeJoinAbstentionTap.note(noted)
        #if LOCALVOXTRAL_DOGFOOD
        DogfoodCaptureTap.shared.noteJoinAbstention(noted)
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

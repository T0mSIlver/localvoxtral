import ClaudeContextWire
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// `localvoxtral-claude-hook --attach --session <id>`: the mod's end of the
/// channel from the app (#1408).
///
/// The mod runs this for the session's life. It attaches to the app's
/// socket, copies each message the app sends to stdout, one line each, and
/// attaches again whenever the app goes away and comes back. A refusal (the
/// app has not seen the session's first hook yet, or the app is not running)
/// is retried with backoff. It ends when its parent, the Claude Code
/// process, does.
///
/// Only lines that decode as a `ClaudeModChannelWire.Message` reach stdout,
/// re-encoded, so the mod never reads bytes the wire does not define.
public struct ClaudeModAttachClient: Sendable {
    public enum Outcome: Equatable, Sendable {
        /// The app answered no, or nothing listens. Retry later.
        case refused
        /// The channel was open and then ended. Attach again.
        case closed
        /// The Claude Code process is gone. Stop.
        case parentGone
    }

    public var socketPath: String
    public var sessionID: String
    public var claudePID: Int32
    public var publisher: UnixSocketPublisher
    /// Writes one message line to the mod.
    public var output: @Sendable (Data) -> Void
    public var isParentAlive: @Sendable () -> Bool
    public var sleep: @Sendable (TimeInterval) -> Void
    /// How often a quiet channel checks that its parent is alive.
    public var parentCheckInterval: TimeInterval
    /// How long the app may take to answer the attach. The publisher's
    /// deadline ends at the write; an app that took the bytes and then hung
    /// would otherwise hold the attach forever, past every retry.
    public var attachReplyTimeout: TimeInterval
    /// Monotonic seconds, for `attachReplyTimeout`.
    public var now: @Sendable () -> TimeInterval
    public static let firstRetryDelay: TimeInterval = 1
    public static let maxRetryDelay: TimeInterval = 30

    public init(
        socketPath: String,
        sessionID: String,
        claudePID: Int32,
        publisher: UnixSocketPublisher = UnixSocketPublisher(timeout: 2),
        output: @escaping @Sendable (Data) -> Void,
        isParentAlive: @escaping @Sendable () -> Bool,
        sleep: @escaping @Sendable (TimeInterval) -> Void,
        parentCheckInterval: TimeInterval = 5,
        attachReplyTimeout: TimeInterval = 5,
        now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.socketPath = socketPath
        self.sessionID = sessionID
        self.claudePID = claudePID
        self.publisher = publisher
        self.output = output
        self.isParentAlive = isParentAlive
        self.sleep = sleep
        self.parentCheckInterval = parentCheckInterval
        self.attachReplyTimeout = attachReplyTimeout
        self.now = now
    }

    /// Attaches until the parent is gone, waiting longer after each refusal.
    public func run() {
        var delay = Self.firstRetryDelay
        while isParentAlive() {
            switch attachOnce() {
            case .parentGone:
                return
            case .closed:
                // Never straight back: whatever ended the channel may end
                // the next one at once.
                delay = Self.firstRetryDelay
                sleep(delay)
            case .refused:
                sleep(delay)
                delay = min(delay * 2, Self.maxRetryDelay)
            }
        }
    }

    /// One attach: connect, read the app's answer, relay until it ends.
    public func attachOnce() -> Outcome {
        guard let line = ClaudeModChannelWire.encodeLine(
            ClaudeModChannelWire.Attach(sessionID: sessionID, claudePID: claudePID)
        ), case .success(let fd) = publisher.openStream(sending: line, to: socketPath)
        else { return .refused }
        defer { close(fd) }

        var pending = Data()
        var isAttached = false
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        let replyDeadline = now() + attachReplyTimeout
        while true {
            var wait = parentCheckInterval
            if !isAttached {
                let remaining = replyDeadline - now()
                guard remaining > 0 else { return .refused }
                wait = min(wait, remaining)
            }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Int32(wait * 1000))
            if ready < 0 {
                if errno == EINTR { continue }
                return isAttached ? .closed : .refused
            }
            if ready == 0 {
                if !isParentAlive() { return .parentGone }
                continue
            }
            let count = read(fd, &chunk, chunk.count)
            if count < 0, errno == EINTR || errno == EAGAIN { continue }
            guard count > 0 else { return isAttached ? .closed : .refused }
            pending.append(contentsOf: chunk[0..<count])

            while let newline = pending.firstIndex(of: 0x0A) {
                let line = Data(pending[pending.startIndex..<newline])
                pending = Data(pending[pending.index(after: newline)...])
                if !isAttached {
                    guard let reply = ClaudeModChannelWire.decode(ClaudeModChannelWire.AttachReply.self, from: line),
                          reply.accepted
                    else { return .refused }
                    isAttached = true
                    continue
                }
                if let message = ClaudeModChannelWire.decode(ClaudeModChannelWire.Message.self, from: line),
                   let encoded = ClaudeModChannelWire.encodeLine(message) {
                    output(encoded)
                }
            }
            // A line longer than the wire allows is not the app talking.
            if pending.count > ClaudeModChannelWire.maxLineBytes {
                return isAttached ? .closed : .refused
            }
        }
    }

    /// `--mod-reply`: sends the one reply or bye on stdin to the app, if it
    /// decodes.
    public static func sendReply(_ stdin: Data, to socketPath: String, publisher: UnixSocketPublisher = .init()) {
        let line = stdin.split(separator: 0x0A).first.map { Data($0) } ?? Data()
        let encoded: Data?
        if let reply = ClaudeModChannelWire.decode(ClaudeModChannelWire.Reply.self, from: line) {
            encoded = ClaudeModChannelWire.encodeLine(reply)
        } else if let bye = ClaudeModChannelWire.decode(ClaudeModChannelWire.Bye.self, from: line) {
            encoded = ClaudeModChannelWire.encodeLine(bye)
        } else {
            encoded = nil
        }
        guard let encoded else { return }
        _ = publisher.publish(line: encoded, to: socketPath)
    }
}

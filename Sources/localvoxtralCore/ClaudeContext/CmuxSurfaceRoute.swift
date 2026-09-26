import Foundation
import Synchronization

/// The joined cmux surface as a route for `AgentPromptSink` (#727): appends
/// go by `surface.send_text` and the submit by `surface.send_key enter`,
/// both naming the one surface the join resolved and dialed only when the
/// socket's peer is the cmux process the join was about. Built by
/// `ClaudeSessionJoinResolver.cmuxSurfaceRoute(for:frontmostPID:)`. Read
/// docs/agent/invariants.md ("The app writes into an agent only through its
/// routes") before widening what it may do.
package final class CmuxSurfaceRoute: AgentPromptRoute, Sendable {
    /// Bytes of text one append may carry. cmux sets no cap, and a
    /// dictation is far below this; a longer text goes by keystrokes.
    package static let maxAppendBytes = 32 * 1024

    package let surfaceID: String
    /// The cmux app the join resolved, which every connection's peer must be.
    package let cmuxPID: pid_t
    private let client: any CmuxSurfaceQuerying & CmuxSurfaceWriting
    /// The user's cmux opt-in, read on every call, so turning it off stops
    /// the writes within the dictation.
    private let isEnabled: @MainActor () -> Bool
    /// The frontmost app's pid now, for deciding where refused text goes.
    private let frontmostPID: @MainActor () -> pid_t?
    /// Whether the joined session still holds the surface, read before
    /// every call: once it exits, the surface is a shell, and an Enter
    /// there runs the dictation as a command.
    private let sessionHoldsSurface: @MainActor () -> Bool
    /// A `cmux ssh` join: the session runs on another host, so the registry
    /// cannot see it exit. Every Enter first needs cmux to report the
    /// surface's workspace as a live remote one, as the join did.
    private let isRemoteJoin: Bool
    /// Whether this cmux reports delivery (`queued`), learned from its first
    /// answer. Until it has, every append checks focus before it is sent.
    private let reportsDelivery = Mutex<Bool?>(nil)

    package init(
        surfaceID: String,
        cmuxPID: pid_t,
        client: any CmuxSurfaceQuerying & CmuxSurfaceWriting,
        isEnabled: @escaping @MainActor () -> Bool,
        frontmostPID: @escaping @MainActor () -> pid_t?,
        sessionHoldsSurface: @escaping @MainActor () -> Bool,
        isRemoteJoin: Bool = false
    ) {
        self.surfaceID = surfaceID
        self.cmuxPID = cmuxPID
        self.client = client
        self.isEnabled = isEnabled
        self.frontmostPID = frontmostPID
        self.sessionHoldsSurface = sessionHoldsSurface
        self.isRemoteJoin = isRemoteJoin
    }

    package var name: String { "cmux surface route" }

    package func deliver(_ call: AgentPromptCall) async -> AgentPromptDelivery {
        guard await isEnabled() else {
            Log.backends.notice("cmux surface route: cmux join turned off; nothing sent")
            return await refusedDelivery()
        }
        guard await sessionHoldsSurface() else {
            Log.backends.notice("cmux surface route: the joined session left the surface; nothing sent")
            return .keepInHistory
        }
        // An older cmux that does not report delivery drops text sent to a
        // surface whose tab is not focused (manaflow-ai/cmux#3129). Its word
        // counts only when the surface was focused before the write and
        // still is after it.
        var focusedBeforeWrite = true
        if reportsDelivery.withLock({ $0 }) != true {
            focusedBeforeWrite = await surfaceIsFocusedInCmux()
        }
        let result: CmuxWriteResult
        switch call {
        case .append(let text):
            guard Self.isSendable(text) else {
                Log.backends.notice("cmux surface route: text has control characters or is too long; nothing sent")
                return await refusedDelivery()
            }
            result = await client.sendText(text, surfaceID: surfaceID, expectedPeerPID: cmuxPID)
        case .submit:
            if isRemoteJoin, await !surfaceIsFocusedRemoteHosted() {
                Log.backends.notice("cmux surface route: remote surface not proved remote-hosted; no Enter")
                return .keepInHistory
            }
            result = await client.sendEnter(surfaceID: surfaceID, expectedPeerPID: cmuxPID)
        }
        if case .accepted(let queued) = result {
            reportsDelivery.withLock { $0 = queued != nil }
        }
        switch result {
        case .accepted(queued: .some):
            return .delivered
        case .accepted(queued: nil):
            if focusedBeforeWrite, await surfaceIsFocusedInCmux() { return .delivered }
            Log.backends.notice("cmux surface route: cmux confirmed no delivery to an unfocused surface")
            return .keepInHistory
        case .refused:
            return await refusedDelivery()
        case .unconfirmed:
            return .keepInHistory
        }
    }

    /// Nothing was sent, so typing cannot double it. While cmux is the
    /// frontmost app the text is typed, as it would be with no route (owner
    /// ruling, 2026-09-26: a refused connection falls back to keystrokes),
    /// unless cmux says another of its surfaces is focused. With another app
    /// frontmost, keys would land there: the text stays in History.
    private func refusedDelivery() async -> AgentPromptDelivery {
        if case .value(let focused) = await client.focusedSurface(expectedPeerPID: cmuxPID),
           focused.surfaceID != surfaceID {
            return .keepInHistory
        }
        // Read after the socket query, which the user may have spent
        // switching apps.
        guard await frontmostPID() == cmuxPID else { return .keepInHistory }
        return .typeInstead
    }

    /// The only proof a remote session still holds the surface: cmux says
    /// the surface is focused and its workspace is a connected remote one.
    /// cmux reports that for the focused surface only.
    private func surfaceIsFocusedRemoteHosted() async -> Bool {
        guard case .value(let focused) = await client.focusedSurface(expectedPeerPID: cmuxPID) else {
            return false
        }
        return focused.surfaceID == surfaceID && focused.workspaceIsRemote == true
    }

    private func surfaceIsFocusedInCmux() async -> Bool {
        guard case .value(let focused) = await client.focusedSurface(expectedPeerPID: cmuxPID) else {
            return false
        }
        return focused.surfaceID == surfaceID
    }

    /// No control character of any kind: cmux turns `\n` and `\r` into
    /// Return, and Tab, Escape and Backspace into keys, and a C1 control can
    /// start a terminal sequence. Such a text goes by keystrokes, which
    /// handle it as a dictation without a route would.
    package static func isSendable(_ text: String) -> Bool {
        guard text.utf8.count <= maxAppendBytes else { return false }
        return !text.unicodeScalars.contains { scalar in
            scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value)
        }
    }
}

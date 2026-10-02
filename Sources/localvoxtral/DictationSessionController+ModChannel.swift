import ClaudeContextWire
import Foundation

/// Overlay Buffer commits into a Claude Code session's prompt box through
/// its mod (#1409): `$.prompt.fill` puts the text at the cursor, with no key
/// posted. Anything short of the mod's `ok` gives the text back to the
/// keyboard, the way the opencode prompt relay does.
extension DictationSessionController {
    /// How long a fill may take before the text goes back to the keyboard:
    /// one publisher spawn each way on the session's machine.
    static let modChannelFillTimeout: Duration = .seconds(2)

    /// The committer that fills `join`'s session through its mod, or nil:
    /// no mod attached, a session that is not a local Claude Code one, or a
    /// surface where a fill is not yet known to show (Claude Desktop, a
    /// browser tab), which keep inserting by keyboard until a hand check
    /// says otherwise.
    func modChannelCommitter(join: ClaudeSessionJoin?) -> ModChannelOverlayCommitter? {
        guard let join, let hub = context.claudeModChannels,
              join.snapshot.agent == .claude,
              join.snapshot.origin.isLocalAuthenticated
        else { return nil }
        let localTerminal: [ClaudeSessionJoinMechanism] = [.ttyDevice, .herdrPane, .cmuxSurface]
        guard localTerminal.contains(join.mechanism) else { return nil }
        let sessionID = join.snapshot.sessionID
        guard hub.isAttached(sessionID) else { return nil }
        Log.overlay.info("overlay commit: through the session's mod")
        return ModChannelOverlayCommitter(hub: hub, sessionID: sessionID) { [weak self] text, pid in
            self?.commitOverlayTextThePromptRelayRefused(text, preferredAppPID: pid, sessionID: sessionID)
        }
    }
}

/// Commits the overlay by asking the session's mod to fill its prompt box.
/// The fill is handed off, not awaited: a refusal, a timeout or a lost
/// channel gives the text back to the keyboard. Secure Keyboard Entry does
/// not stop it, since no key is posted.
@MainActor
final class ModChannelOverlayCommitter: OverlayTextCommitting {
    private let hub: ClaudeModChannelHub
    private let sessionID: String
    private let refused: @MainActor (String, pid_t?) -> Void

    init(hub: ClaudeModChannelHub, sessionID: String, refused: @escaping @MainActor (String, pid_t?) -> Void) {
        self.hub = hub
        self.sessionID = sessionID
        self.refused = refused
    }

    #if DEBUG
    /// Test seam: called once a fill settles, with whether the mod filled.
    static var debugFillSettled: (@MainActor (Bool) -> Void)?
    #endif

    var isAccessibilityTrusted: Bool { true }
    var postsNoKeys: Bool { true }

    func insertTextPrioritizingKeyboard(_ text: String, preferredAppPID: pid_t?) -> TextInsertResult {
        let hub = hub
        let sessionID = sessionID
        let refused = refused
        Task { @MainActor in
            let reply = await hub.send(
                .init(kind: .fill, text: text),
                to: sessionID,
                timeout: DictationSessionController.modChannelFillTimeout
            )
            let filled = reply?.ok == true
            if filled {
                Log.overlay.info("overlay commit: the mod filled the prompt box")
            } else {
                Log.overlay.notice(
                    "overlay commit: the mod did not fill (\(reply?.reason ?? "no reply", privacy: .public)); keyboard instead"
                )
                refused(text, preferredAppPID)
            }
            #if DEBUG
            ModChannelOverlayCommitter.debugFillSettled?(filled)
            #endif
        }
        return .insertedByAccessibility
    }

    func pasteUsingCommandV(_: String, preferredAppPID _: pid_t?) -> Bool {
        false
    }
}

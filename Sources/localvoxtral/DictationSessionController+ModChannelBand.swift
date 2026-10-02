import ClaudeContextWire
import Foundation

/// The session a dictation is joined to, and what its band last showed.
struct ModChannelBand: Equatable {
    let sessionID: String
    var phase: ClaudeModChannelWire.Phase
    var text: String
}

/// While an Overlay Buffer dictation is joined to a local Claude Code
/// session whose mod is attached, the mod draws a band above that session's
/// prompt: listening and the words so far, then finishing, then nothing
/// (#1411). It reaches the session wherever it is drawn, the terminal, the
/// Claude Desktop Code tab or a phone, so the join's surface does not matter
/// here the way it does for a fill.
extension DictationSessionController {
    /// Enough of the tail to read at a glance; the band is one or two lines.
    static let modChannelBandMaxCharacters = 240
    /// How often a band that has not changed is sent again: well inside the
    /// 30 s the mod keeps a band it has not heard about, so the band goes
    /// when the app does, not when the user pauses or a polish runs long.
    static let modChannelBandHeartbeat: Duration = .seconds(10)

    /// Tells the joined session's mod what the dictation is doing now.
    /// Posts nothing when that is what it last said.
    func postModChannelBand(_ phase: ClaudeModChannelWire.Phase) {
        guard let hub = context.claudeModChannels else { return }
        if phase == .done {
            modChannelBandHeartbeatTask?.cancel()
            modChannelBandHeartbeatTask = nil
            guard let band = modChannelBand else { return }
            modChannelBand = nil
            hub.post(.init(kind: .state, phase: .done), to: band.sessionID)
            return
        }
        guard isOverlayBufferModeEnabled else { return }
        let sessionID: String
        if let band = modChannelBand {
            sessionID = band.sessionID
        } else {
            guard let join = context.claudeSessionJoin,
                  join.snapshot.agent == .claude,
                  join.snapshot.origin.isLocalAuthenticated,
                  hub.isAttached(join.snapshot.sessionID)
            else { return }
            sessionID = join.snapshot.sessionID
        }
        let text = String(currentOverlayDisplayText().suffix(Self.modChannelBandMaxCharacters))
        let band = ModChannelBand(sessionID: sessionID, phase: phase, text: text)
        guard band != modChannelBand else { return }
        modChannelBand = band
        hub.post(.init(kind: .state, text: text, phase: phase), to: sessionID)
        keepModChannelBandAlive()
    }

    /// Sends the band again every `modChannelBandHeartbeat` on the session
    /// clock until `done` cancels it.
    private func keepModChannelBandAlive() {
        guard modChannelBandHeartbeatTask == nil else { return }
        let clock = dependencies.clock
        modChannelBandHeartbeatTask = Task { [weak self] in
            while true {
                await clock.sleep(Self.modChannelBandHeartbeat)
                guard !Task.isCancelled, let self, let band = self.modChannelBand,
                      let hub = self.context.claudeModChannels
                else { return }
                hub.post(.init(kind: .state, text: band.text, phase: band.phase), to: band.sessionID)
            }
        }
    }
}

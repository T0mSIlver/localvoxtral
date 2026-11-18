import ClaudeContextWire
import Foundation

extension ClaudeIntegrationSettingsModel {
    /// What the pane says about the listener, in one short line.
    ///
    /// Short because it goes in Settings next to a row (owner rule: long text
    /// belongs in the alert and the log, never in the popover, and a Settings
    /// status line has the same problem for the same reason). The DETAIL of a
    /// failure goes to `alert` and to `Log`.
    public enum ListenerStatus: Equatable, Sendable {
        case idle
        case listening(port: UInt16)
        case portConflict(port: UInt16)
        case failed

        public var text: String {
            switch self {
            case .idle: return "Not listening because no hosts are enrolled."
            case .listening(let port): return "Listening on 127.0.0.1:\(port)."
            case .portConflict(let port): return "Port \(port) is already in use."
            case .failed: return "Could not start listening."
            }
        }

        /// The actionable half, when there is one. Settings shows this under the
        /// status; a status that only says "it broke" is a bug report, not a UI.
        public var remedy: String? {
            switch self {
            case .idle, .listening: return nil
            case .portConflict(let port):
                return "Another app holds \(port), often a second copy of localvoxtral. "
                    + "Quit it and press Retry."
            case .failed: return "See Console for details, then press Retry."
            }
        }

        public var isFailure: Bool {
            switch self {
            case .idle, .listening: return false
            case .portConflict, .failed: return true
            }
        }
    }
}

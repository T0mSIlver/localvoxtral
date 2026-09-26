import ClaudeContextWire
import Foundation

/// One consented setup attempt for one remote host.
public struct RemoteHostSetupRun: Sendable, Equatable {
    public enum Step: Int, CaseIterable, Sendable, Equatable, Identifiable {
        case sshConfig
        case shellStartup
        case remotePlugin
        case environmentCrossing
        case remoteHerdr
        case remoteVibe
        case checkSetup

        public var id: Int { rawValue }

        public var title: String {
            switch self {
            case .sshConfig: return "Mac SSH config"
            case .shellStartup: return "Mac shell startup"
            case .remotePlugin: return "Remote plugin"
            case .environmentCrossing: return "Terminal environment"
            case .remoteHerdr: return "Remote herdr"
            case .remoteVibe: return "Remote Vibe hooks"
            case .checkSetup: return "Check setup"
            }
        }
    }

    public enum State: Sendable, Equatable {
        case pending
        case running
        case done(String)
        case skipped(String)
        case failed(reason: String, remedy: String)
    }

    public struct Item: Sendable, Equatable, Identifiable {
        public var step: Step
        public var state: State
        public var id: Int { step.rawValue }

        package init(step: Step, state: State) {
            self.step = step
            self.state = state
        }
    }

    public var hostID: String
    public var startedAt: Date
    public var items: [Item]

    public init(hostID: String, startedAt: Date) {
        self.hostID = hostID
        self.startedAt = startedAt
        items = Step.allCases.map { Item(step: $0, state: .pending) }
    }
}

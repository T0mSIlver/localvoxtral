import AppKit
import Foundation
import Network

/// Tells the forward coordinator when the Mac woke or its network changed, the
/// two moments a failed or parked forward must start over (#659).
///
/// A network change is a satisfied path that differs from the previous
/// update: the network coming back (the usual case after a wake, whose own
/// trigger often fires before Wi-Fi rejoins), or a hop between two working
/// networks (Wi-Fi to Ethernet, a VPN coming up), which `NetworkMonitor`'s
/// connected/disconnected signal does not see and which kills the ssh
/// connection just the same. A lost path fires nothing: there is nothing to
/// reconnect over yet. The first update is the path the forwards started on.
@MainActor
final class ClaudeRemoteForwardRecoveryTriggers {
    private let monitor = NWPathMonitor()
    private var wakeObserver: NSObjectProtocol?
    /// The previous update's signature, nil while the path was unsatisfied.
    private var lastPath: String?
    private var sawFirstUpdate = false

    init(onTrigger: @escaping @MainActor @Sendable (ClaudeRemoteForwardCoordinator.RecoveryTrigger) -> Void) {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { onTrigger(.wake) }
        }
        monitor.pathUpdateHandler = { [weak self] path in
            let signature = path.status == .satisfied ? Self.signature(of: path) : nil
            // The monitor delivers on the main queue (`start` below), so the
            // updates run in order, on the main actor.
            MainActor.assumeIsolated {
                guard let self else { return }
                let previous = self.lastPath
                let isFirst = !self.sawFirstUpdate
                self.lastPath = signature
                self.sawFirstUpdate = true
                guard !isFirst, signature != nil, signature != previous else { return }
                onTrigger(.networkChange)
            }
        }
        monitor.start(queue: .main)
    }

    func stop() {
        monitor.cancel()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        wakeObserver = nil
    }

    private nonisolated static func signature(of path: NWPath) -> String {
        let interfaces = path.availableInterfaces.map(\.name).sorted()
        let gateways = path.gateways.map { String(describing: $0) }.sorted()
        return (interfaces + ["|"] + gateways).joined(separator: ",")
    }
}

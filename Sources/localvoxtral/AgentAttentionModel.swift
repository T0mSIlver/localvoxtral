import AppKit
import ClaudeContextWire
import Foundation
import UserNotifications

/// The needs-you cue (#717): the queue the menu bar icon and the popover
/// line read, fed by `AgentAttentionTracker`. Each new entry plays a sound
/// and posts a banner. Off, with nothing queued, while no answer shortcut
/// is set.
@MainActor
@Observable
final class AgentAttentionModel {
    private(set) var queue = AgentAttentionQueue()
    @ObservationIgnored
    let tracker: AgentAttentionTracker
    @ObservationIgnored
    let announcer: (any AgentAttentionAnnouncing)?

    init(tracker: AgentAttentionTracker, announcer: (any AgentAttentionAnnouncing)?) {
        self.tracker = tracker
        self.announcer = announcer
        tracker.onChange = { [weak self, weak tracker] in
            guard let self, let tracker else { return }
            let removed = Set(self.queue.entries.map(\.sessionID))
                .subtracting(tracker.queue.entries.map(\.sessionID))
            self.queue = tracker.queue
            if !removed.isEmpty { announcer?.withdraw(sessionIDs: removed) }
        }
        tracker.onCue = { entry in announcer?.announce(entry) }
    }

    /// The popover's sentence, nil when nobody waits.
    var popoverLine: String? { AgentAttentionText.popoverLine(queue) }
}

/// The sound and the banner.
@MainActor
protocol AgentAttentionAnnouncing: AnyObject {
    /// Asks macOS to allow banners. Called when the user sets the answer
    /// shortcut, which is when they turn the cue on.
    func requestPermission()
    func announce(_ entry: AgentAttentionEntry)
    /// Takes down the banners of sessions that left the queue.
    func withdraw(sessionIDs: Set<String>)
}

/// A system sound, and a banner per session that replaces the session's
/// previous one. The banner names the session and the agent, never what it
/// asked: the app never has that text.
@MainActor
final class AgentAttentionAnnouncer: NSObject, AgentAttentionAnnouncing, UNUserNotificationCenterDelegate {
    static let soundName = NSSound.Name("Glass")
    private static let identifierPrefix = "agent-attention."

    private let center = UNUserNotificationCenter.current()

    override init() {
        super.init()
        center.delegate = self
    }

    func requestPermission() {
        center.requestAuthorization(options: [.alert]) { granted, error in
            if let error {
                Log.claudeContext.error("needs-you banner: permission request failed (\(error.localizedDescription, privacy: .public))")
            } else {
                Log.claudeContext.notice("needs-you banner: permission granted=\(granted, privacy: .public)")
            }
        }
    }

    func announce(_ entry: AgentAttentionEntry) {
        NSSound(named: Self.soundName)?.play()
        let content = UNMutableNotificationContent()
        content.title = AgentAttentionText.sentence(entry)
        content.body = AgentAttentionText.detail(entry)
        let request = UNNotificationRequest(
            identifier: Self.identifierPrefix + entry.sessionID, content: content, trigger: nil
        )
        center.add(request) { error in
            if let error {
                Log.claudeContext.error("needs-you banner: not posted (\(error.localizedDescription, privacy: .public))")
            }
        }
    }

    func withdraw(sessionIDs: Set<String>) {
        center.removeDeliveredNotifications(withIdentifiers: sessionIDs.map { Self.identifierPrefix + $0 })
    }

    /// Shown even while the app is active: a menu bar app is active whenever
    /// its menu or Settings is open.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }
}

import ClaudeContextWire
import Foundation
import UserNotifications

/// The needs-you cue (#717): the queue the menu bar icon and the popover
/// line read, fed by `AgentAttentionTracker`. Each new entry posts a banner
/// with a sound. Off, with nothing queued, while "Tell me when an
/// agent needs you" is off.
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

/// The banner and its sound.
@MainActor
protocol AgentAttentionAnnouncing: AnyObject {
    /// Asks macOS to allow banners and their sound. Called when the user
    /// turns the cue on.
    func requestPermission()
    func announce(_ entry: AgentAttentionEntry)
    /// Takes down the banners of sessions that left the queue.
    func withdraw(sessionIDs: Set<String>)
}

/// What the announcer reads from a notification grant.
struct AgentAttentionNotificationGrant: Sendable {
    var status: UNAuthorizationStatus
    var sound: UNNotificationSetting

    var statusName: String {
        switch status {
        case .notDetermined: "not determined"
        case .denied: "denied"
        case .authorized: "authorized"
        case .provisional: "provisional"
        @unknown default: "unknown(\(status.rawValue))"
        }
    }

    var soundName: String {
        switch sound {
        case .notSupported: "not requested"
        case .disabled: "off"
        case .enabled: "on"
        @unknown default: "unknown(\(sound.rawValue))"
        }
    }
}

/// The slice of `UNUserNotificationCenter` the announcer uses. Tests stand
/// in for it: the real center traps in a process with no app bundle.
protocol AgentAttentionNotificationCenter: AnyObject, Sendable {
    func setDelegate(_ delegate: any UNUserNotificationCenterDelegate)
    func requestAuthorization(
        options: UNAuthorizationOptions, completionHandler: @escaping @Sendable (Bool, (any Error)?) -> Void
    )
    func grant(completionHandler: @escaping @Sendable (AgentAttentionNotificationGrant) -> Void)
    func add(_ request: UNNotificationRequest, completionHandler: @escaping @Sendable ((any Error)?) -> Void)
    func removeDeliveredNotifications(withIdentifiers identifiers: [String])
}

final class SystemAgentAttentionNotificationCenter: AgentAttentionNotificationCenter, @unchecked Sendable {
    private let center = UNUserNotificationCenter.current()

    func setDelegate(_ delegate: any UNUserNotificationCenterDelegate) { center.delegate = delegate }

    func requestAuthorization(
        options: UNAuthorizationOptions, completionHandler: @escaping @Sendable (Bool, (any Error)?) -> Void
    ) {
        center.requestAuthorization(options: options, completionHandler: completionHandler)
    }

    func grant(completionHandler: @escaping @Sendable (AgentAttentionNotificationGrant) -> Void) {
        center.getNotificationSettings { settings in
            completionHandler(.init(status: settings.authorizationStatus, sound: settings.soundSetting))
        }
    }

    func add(_ request: UNNotificationRequest, completionHandler: @escaping @Sendable ((any Error)?) -> Void) {
        center.add(request, withCompletionHandler: completionHandler)
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}

/// A banner per session that replaces the session's previous one, with the
/// user's alert sound. The sound rides the notification, so macOS's "Play
/// sound for notifications" switch and Focus silence it. The banner names
/// the session and the agent, never what it asked: the app never has that
/// text.
@MainActor
final class AgentAttentionAnnouncer: NSObject, AgentAttentionAnnouncing, UNUserNotificationCenterDelegate {
    /// `.default` rather than Glass: `UNNotificationSound(named:)` finds
    /// only files in the app's bundle or `~/Library/Sounds`, and Glass lives
    /// in `/System/Library/Sounds`.
    static let sound = UNNotificationSound.default
    nonisolated static let permissionOptions: UNAuthorizationOptions = [.alert, .sound]
    private static let identifierPrefix = "agent-attention."

    private let center: any AgentAttentionNotificationCenter

    init(center: any AgentAttentionNotificationCenter = SystemAgentAttentionNotificationCenter()) {
        self.center = center
        super.init()
        center.setDelegate(self)
    }

    func requestPermission() {
        Self.requestPermission(from: center)
    }

    private nonisolated static func requestPermission(from center: any AgentAttentionNotificationCenter) {
        center.requestAuthorization(options: permissionOptions) { granted, error in
            if let error {
                Log.claudeContext.error("needs-you banner: permission request failed (\(error.localizedDescription, privacy: .public))")
            } else {
                Log.claudeContext.notice("needs-you banner: permission granted=\(granted, privacy: .public)")
            }
        }
    }

    /// Run at launch while the cue is on. A grant made before the banner
    /// carried a sound covers banners only, so macOS shows no sound switch
    /// for the app; asking again with `.sound` adds it. A denied grant is
    /// left alone.
    func requestSoundIfMissing() {
        center.grant { [center] grant in
            Log.claudeContext.notice(
                "needs-you banner: authorization=\(grant.statusName, privacy: .public) sound=\(grant.soundName, privacy: .public)"
            )
            guard grant.status != .denied, grant.sound == .notSupported else { return }
            Log.claudeContext.notice("needs-you banner: grant lacks sound, asking again")
            Self.requestPermission(from: center)
        }
    }

    func announce(_ entry: AgentAttentionEntry) {
        let content = UNMutableNotificationContent()
        content.title = AgentAttentionText.sentence(entry)
        content.body = AgentAttentionText.detail(entry)
        content.sound = Self.sound
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

    /// Shown, with its sound, even while the app is active: a menu bar app
    /// is active whenever its menu or Settings is open.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}

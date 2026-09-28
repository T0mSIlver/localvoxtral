import Foundation
import Synchronization
import UserNotifications
import XCTest
@testable import localvoxtral

/// The needs-you sound rides the notification (#899), so macOS's sound
/// switch and Focus control it.
@MainActor
final class AgentAttentionAnnouncerTests: XCTestCase {
    func testAnnounceCarriesTheSoundOnTheNotification() async {
        let center = FakeNotificationCenter()
        let announcer = AgentAttentionAnnouncer(center: center)

        announcer.announce(AgentAttentionEntry(
            sessionID: "s1", kind: .waiting, since: Date(timeIntervalSince1970: 0), name: "payments", agent: .claude
        ))

        XCTAssertEqual(center.posted, [.init(identifier: "agent-attention.s1", hasDefaultSound: true)])
    }

    func testPermissionRequestIncludesSound() async {
        let center = FakeNotificationCenter()
        AgentAttentionAnnouncer(center: center).requestPermission()

        XCTAssertEqual(center.requestedOptions, [[.alert, .sound]])
    }

    /// A grant made for banners alone shows no sound switch in System
    /// Settings; the launch check asks again so it appears.
    func testLaunchCheckAsksAgainWhenTheGrantLacksSound() async {
        let center = FakeNotificationCenter(grant: .init(status: .authorized, sound: .notSupported))
        AgentAttentionAnnouncer(center: center).requestSoundIfMissing()

        XCTAssertEqual(center.requestedOptions, [[.alert, .sound]])
    }

    /// The user turned the sound off, or denied notifications: nothing to ask.
    func testLaunchCheckLeavesAnAnsweredGrantAlone() async {
        for grant in [
            AgentAttentionNotificationGrant(status: .authorized, sound: .disabled),
            AgentAttentionNotificationGrant(status: .authorized, sound: .enabled),
            AgentAttentionNotificationGrant(status: .denied, sound: .notSupported),
        ] {
            let center = FakeNotificationCenter(grant: grant)
            AgentAttentionAnnouncer(center: center).requestSoundIfMissing()

            XCTAssertEqual(center.requestedOptions, [], "\(grant.statusName), sound \(grant.soundName)")
        }
    }
}

/// Answers synchronously, so a test reads what the announcer did right after
/// the call.
private struct PostedNotification: Equatable {
    var identifier: String
    var hasDefaultSound: Bool
}

private final class FakeNotificationCenter: AgentAttentionNotificationCenter, @unchecked Sendable {
    private let state: Mutex<(options: [UNAuthorizationOptions], posted: [PostedNotification])> = Mutex(([], []))
    private let currentGrant: AgentAttentionNotificationGrant

    init(grant: AgentAttentionNotificationGrant = .init(status: .authorized, sound: .enabled)) {
        currentGrant = grant
    }

    var requestedOptions: [UNAuthorizationOptions] { state.withLock { $0.options } }
    var posted: [PostedNotification] { state.withLock { $0.posted } }

    func setDelegate(_ delegate: any UNUserNotificationCenterDelegate) {}

    func requestAuthorization(
        options: UNAuthorizationOptions, completionHandler: @escaping @Sendable (Bool, (any Error)?) -> Void
    ) {
        state.withLock { $0.options.append(options) }
        completionHandler(true, nil)
    }

    func grant(completionHandler: @escaping @Sendable (AgentAttentionNotificationGrant) -> Void) {
        completionHandler(currentGrant)
    }

    func add(_ request: UNNotificationRequest, completionHandler: @escaping @Sendable ((any Error)?) -> Void) {
        let posted = PostedNotification(
            identifier: request.identifier, hasDefaultSound: request.content.sound == UNNotificationSound.default
        )
        state.withLock { $0.posted.append(posted) }
        completionHandler(nil)
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {}
}

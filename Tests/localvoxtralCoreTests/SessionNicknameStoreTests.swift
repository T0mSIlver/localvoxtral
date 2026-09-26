import Foundation
@testable import localvoxtralCore
import XCTest

final class SessionNicknameStoreTests: XCTestCase {
    private typealias Entry = SessionNicknameStore.Entry

    func testANewNicknameReplacesTheSessionsOldOne() {
        let store = SessionNicknameStore(load: []) { _ in }
        store.setNickname("payments", for: "a")
        store.setNickname("billing", for: "a")
        XCTAssertEqual(store.nickname(for: "a"), "billing")
    }

    func testANicknameMovesToTheSessionLastGivenIt() {
        let store = SessionNicknameStore(load: []) { _ in }
        store.setNickname("payments", for: "a")
        store.setNickname("Payments", for: "b")
        XCTAssertNil(store.nickname(for: "a"))
        XCTAssertEqual(store.nickname(for: "b"), "Payments")
    }

    func testTheOldestIsDroppedPastCapacity() {
        let store = SessionNicknameStore(load: []) { _ in }
        for index in 0...SessionNicknameStore.capacity {
            store.setNickname("name \(index)", for: "s\(index)")
        }
        XCTAssertNil(store.nickname(for: "s0"))
        XCTAssertEqual(store.nickname(for: "s1"), "name 1")
    }

    func testANicknameWithNoLetterOrDigitIsIgnored() {
        let saves = Saves()
        let store = SessionNicknameStore(load: []) { saves.append($0) }
        store.setNickname("...", for: "a")
        XCTAssertNil(store.nickname(for: "a"))
        XCTAssertEqual(saves.count, 0)
    }

    func testNicknamesSurviveARestart() {
        let suite = "SessionNicknameStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        SessionNicknameStore.userDefaults(defaults, key: "nicknames").setNickname("payments", for: "a")

        let reloaded = SessionNicknameStore.userDefaults(defaults, key: "nicknames")

        XCTAssertEqual(reloaded.nickname(for: "a"), "payments")
    }
}

private final class Saves: @unchecked Sendable {
    private let lock = NSLock()
    private var saved: [[SessionNicknameStore.Entry]] = []

    var count: Int { lock.withLock { saved.count } }

    func append(_ entries: [SessionNicknameStore.Entry]) {
        lock.withLock { saved.append(entries) }
    }
}

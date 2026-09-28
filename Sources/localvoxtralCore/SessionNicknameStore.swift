import Foundation
import Synchronization

/// Spoken nicknames (#723 step 2): "call this session payments" names the
/// session dictated into, and "go to payments" finds it ahead of any
/// default name. Keyed by registry session id, which an agent keeps across
/// a resume. One session holds a nickname at a time.
package final class SessionNicknameStore: @unchecked Sendable {
    /// Oldest set first; past it, the oldest is dropped.
    package static let capacity = 100

    package struct Entry: Codable, Equatable, Sendable {
        package var sessionID: String
        package var nickname: String

        package init(sessionID: String, nickname: String) {
            self.sessionID = sessionID
            self.nickname = nickname
        }
    }

    private let entries: Mutex<[Entry]>
    private let save: @Sendable ([Entry]) -> Void

    /// - Parameters:
    ///   - load: what an earlier run saved, oldest set first.
    ///   - save: called with every change, oldest set first.
    package init(load: [Entry], save: @escaping @Sendable ([Entry]) -> Void) {
        entries = Mutex(Array(load.suffix(Self.capacity)))
        self.save = save
    }

    package func nickname(for sessionID: String) -> String? {
        entries.withLock { $0.last(where: { $0.sessionID == sessionID })?.nickname }
    }

    /// Replaces the session's nickname, and takes the nickname from any
    /// other session that held it.
    package func setNickname(_ nickname: String, for sessionID: String) {
        let key = SessionNameMatching.key(nickname)
        guard !key.isEmpty else { return }
        let saved = entries.withLock { entries in
            entries.removeAll {
                $0.sessionID == sessionID || SessionNameMatching.key($0.nickname) == key
            }
            entries.append(Entry(sessionID: sessionID, nickname: nickname))
            if entries.count > Self.capacity {
                entries.removeFirst(entries.count - Self.capacity)
            }
            return entries
        }
        save(saved)
    }
}

extension SessionNicknameStore {
    /// Backed by `UserDefaults` under `key`, as JSON.
    package static func userDefaults(_ defaults: UserDefaults, key: String) -> SessionNicknameStore {
        let load = defaults.data(forKey: key)
            .flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
        nonisolated(unsafe) let defaults = defaults
        return SessionNicknameStore(load: load) { entries in
            guard let data = try? JSONEncoder().encode(entries) else { return }
            defaults.set(data, forKey: key)
        }
    }
}

import Foundation

/// Where an Overlay Buffer dictation's words go when it stops (#840). The
/// overlay lists the choices and Tab moves between them; nothing changes
/// the destination but Tab or a shortcut that opens the overlay on one.
package enum DictationDestination: Equatable, Sendable {
    /// The app that was focused when the dictation started.
    case focusedApp
    /// A coding agent session that needs you. Picking it brings its pane
    /// forward; the words commit there like any dictation into that pane.
    case session(id: String)
    /// The quick capture Inbox (#751): never inserted anywhere.
    case inbox
}

/// The overlay's destinations for one dictation, in a fixed order: the
/// focused app, the sessions that need you in the order the answer hotkey
/// reaches them, then the Inbox. The focused app and the Inbox are always
/// there, so with nobody waiting one Tab reaches the Inbox.
package struct DictationDestinationList: Equatable, Sendable {
    package private(set) var entries: [DictationDestination]
    package private(set) var selected: DictationDestination

    /// - Parameters:
    ///   - waitingSessionIDs: the needs-you queue in answer order.
    ///   - focusedSessionID: the session the focused pane shows, if any. It
    ///     is the focused app's entry and is not listed twice.
    ///   - selected: the entry the overlay opens on; an entry the list does
    ///     not hold falls back to the focused app.
    package init(
        waitingSessionIDs: [String],
        focusedSessionID: String?,
        selected: DictationDestination = .focusedApp
    ) {
        var seen = Set<String>()
        let sessions = waitingSessionIDs.filter { id in
            id != focusedSessionID && seen.insert(id).inserted
        }
        entries = [.focusedApp] + sessions.map(DictationDestination.session) + [.inbox]
        self.selected = entries.contains(selected) ? selected : .focusedApp
    }

    /// The entry Tab moves to, wrapping from the Inbox to the focused app.
    package var next: DictationDestination { neighbor(of: selected, offset: 1) }

    /// The entry ⇧Tab moves to.
    package var previous: DictationDestination { neighbor(of: selected, offset: -1) }

    /// The entry after (Tab) or before (⇧Tab) `base`, which need not be the
    /// picked one: a second Tab while a pane is still coming forward moves
    /// on from where the first was going.
    package func moving(from base: DictationDestination, forward: Bool) -> DictationDestination {
        neighbor(of: entries.contains(base) ? base : selected, offset: forward ? 1 : -1)
    }

    /// Picks `destination` when the list holds it; returns whether it did.
    @discardableResult
    package mutating func select(_ destination: DictationDestination) -> Bool {
        guard entries.contains(destination) else { return false }
        selected = destination
        return true
    }

    /// The queue changed while the overlay is open: sessions that started
    /// waiting join, sessions that left go, and the picked session stays
    /// even once picking it took it out of the queue.
    package mutating func refresh(waitingSessionIDs: [String], focusedSessionID: String?) {
        var waiting = waitingSessionIDs
        if case .session(let id) = selected, !waiting.contains(id) {
            // Kept where it was relative to the others that remain.
            let before = entries.prefix { $0 != selected }.compactMap { entry -> String? in
                if case .session(let other) = entry { return other }
                return nil
            }
            let insertAt = waiting.lastIndex { before.contains($0) }.map { $0 + 1 } ?? 0
            waiting.insert(id, at: insertAt)
        }
        self = DictationDestinationList(
            waitingSessionIDs: waiting,
            focusedSessionID: focusedSessionID,
            selected: selected
        )
    }

    private func neighbor(of base: DictationDestination, offset: Int) -> DictationDestination {
        guard let index = entries.firstIndex(of: base) else { return .focusedApp }
        let count = entries.count
        return entries[((index + offset) % count + count) % count]
    }
}

/// What the overlay header shows for a `DictationDestinationList`: one pill
/// per entry, the picked one filled.
package struct OverlayDestinationStrip: Equatable, Sendable {
    package enum Kind: Equatable, Sendable {
        /// `joined` says what the join badge said: true for a session the
        /// dictation is grounded in, false for "no session attached", nil
        /// when there is nothing to say.
        case focusedApp(joined: Bool?)
        case session
        case inbox
    }

    package struct Item: Equatable, Sendable {
        package let label: String
        package let kind: Kind
        package let isSelected: Bool
    }

    package static let inboxLabel = "Inbox"

    package let items: [Item]

    /// - Parameters:
    ///   - focusedAppLabel: the joined session's name, else the app's.
    ///   - sessionName: the name the popover line uses for a session.
    package init(
        list: DictationDestinationList,
        focusedAppLabel: String,
        focusedAppJoined: Bool?,
        sessionName: (String) -> String
    ) {
        items = list.entries.map { entry in
            let isSelected = entry == list.selected
            switch entry {
            case .focusedApp:
                return Item(label: focusedAppLabel, kind: .focusedApp(joined: focusedAppJoined), isSelected: isSelected)
            case .session(let id):
                return Item(label: sessionName(id), kind: .session, isSelected: isSelected)
            case .inbox:
                return Item(label: Self.inboxLabel, kind: .inbox, isSelected: isSelected)
            }
        }
    }

    package var selectedKind: Kind? { items.first(where: \.isSelected)?.kind }
}

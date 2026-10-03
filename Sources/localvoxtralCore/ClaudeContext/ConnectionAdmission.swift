/// The connection cap shared by `ClaudeContextBroker` and
/// `ClaudeRemoteContextListener`. A refused connection loses one context
/// update, so the listener logs the first refusal of a full spell and, on the
/// next admission, how many it refused; a flood of peers costs two lines.
package struct ConnectionAdmission: Sendable, Equatable {
    package enum Decision: Equatable, Sendable {
        /// `refusedWhileFull` connections were refused since the last
        /// admission; non-zero ends a full spell.
        case admitted(refusedWhileFull: Int)
        /// Over the cap. `first` marks the refusal that starts a full spell.
        case refused(first: Bool)
    }

    package private(set) var active = 0
    private var refusedWhileFull = 0

    package init() {}

    package mutating func admit(limit: Int) -> Decision {
        guard active < limit else {
            refusedWhileFull += 1
            return .refused(first: refusedWhileFull == 1)
        }
        active += 1
        defer { refusedWhileFull = 0 }
        return .admitted(refusedWhileFull: refusedWhileFull)
    }

    package mutating func release() {
        active -= 1
    }
}

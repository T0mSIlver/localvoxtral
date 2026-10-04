import Foundation

package enum PreferredTextInsertionTargetPolicy {
    package enum PasteActivationAction: Equatable {
        case useCurrentFrontmost
        case activate(pid_t)
        case deny
    }

    package static func accessibilityTargetPID(
        systemFocusedPID: pid_t?,
        preferredPID: pid_t?,
        selfPID: pid_t
    ) -> pid_t? {
        if let preferredPID = normalizedPreferredPID(preferredPID, selfPID: selfPID) {
            return preferredPID
        }

        guard let systemFocusedPID,
              systemFocusedPID != selfPID
        else {
            return nil
        }

        return systemFocusedPID
    }

    package static func pasteActivationAction(
        frontmostPID: pid_t?,
        preferredPID: pid_t?,
        selfPID: pid_t
    ) -> PasteActivationAction {
        if let preferredPID = normalizedPreferredPID(preferredPID, selfPID: selfPID) {
            if frontmostPID == preferredPID {
                return .useCurrentFrontmost
            }
            return .activate(preferredPID)
        }

        guard let frontmostPID else { return .deny }
        return frontmostPID == selfPID ? .deny : .useCurrentFrontmost
    }

    private static func normalizedPreferredPID(_ preferredPID: pid_t?, selfPID: pid_t) -> pid_t? {
        guard let preferredPID,
              preferredPID != 0,
              preferredPID != selfPID
        else {
            return nil
        }
        return preferredPID
    }
}

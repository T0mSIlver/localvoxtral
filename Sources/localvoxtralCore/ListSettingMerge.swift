import Foundation

/// A list setting the user builds up (global terms, refused suggestions),
/// which another running copy may have saved since this one read it (#1575).
/// Writing this copy's array whole would drop what the other copy added and
/// bring back what it removed, so a write applies only this copy's own
/// changes to what is saved: a three-way merge on the items' identity.
package enum ListSettingMerge {
    /// - Parameters:
    ///   - base: this copy's value before its change, the last it read or wrote.
    ///   - ours: this copy's value after its change.
    ///   - saved: the value saved now, possibly by another copy.
    /// - Returns: `ours` less what another copy removed, then what another
    ///   copy added, in its saved order.
    package static func merge(base: [String], ours: [String], saved: [String]) -> [String] {
        let baseItems = Set(base)
        let savedItems = Set(saved)
        let ourItems = Set(ours)
        let kept = ours.filter { savedItems.contains($0) || !baseItems.contains($0) }
        let theirs = saved.filter { !baseItems.contains($0) && !ourItems.contains($0) }
        return kept + theirs
    }
}

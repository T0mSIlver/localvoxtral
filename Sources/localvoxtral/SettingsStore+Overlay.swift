import CoreGraphics
import Foundation

extension SettingsStore {
    func persistOverlayBufferPlacement() {
        guard let placement = overlayBufferPlacement, placement.isWellFormed else {
            defaults.removeObject(forKey: Keys.overlayBufferPositionScreenID)
            defaults.removeObject(forKey: Keys.overlayBufferPositionOffsetX)
            defaults.removeObject(forKey: Keys.overlayBufferPositionOffsetY)
            return
        }
        defaults.set(placement.screenID, forKey: Keys.overlayBufferPositionScreenID)
        defaults.set(Double(placement.topLeftOffset.x), forKey: Keys.overlayBufferPositionOffsetX)
        defaults.set(Double(placement.topLeftOffset.y), forKey: Keys.overlayBufferPositionOffsetY)
    }

    /// Reads a stored placement back, rejecting anything the resolver could not
    /// clamp: a half-written trio, an empty display id, a NaN offset. A first
    /// run has none of the three keys and lands here as nil, which is the
    /// anchored position.
    static func loadOverlayBufferPlacement(defaults: UserDefaults) -> OverlayManualPlacement? {
        guard let screenID = defaults.string(forKey: Keys.overlayBufferPositionScreenID),
              !screenID.isEmpty,
              defaults.object(forKey: Keys.overlayBufferPositionOffsetX) != nil,
              defaults.object(forKey: Keys.overlayBufferPositionOffsetY) != nil
        else { return nil }
        let placement = OverlayManualPlacement(
            screenID: screenID,
            topLeftOffset: CGPoint(
                x: defaults.double(forKey: Keys.overlayBufferPositionOffsetX),
                y: defaults.double(forKey: Keys.overlayBufferPositionOffsetY)
            )
        )
        return placement.isWellFormed ? placement : nil
    }
}

import Foundation

/// Content of the About pane's "Build" row: is this binary a dogfood build,
/// and is the capture armed?
///
/// Deliberately NOT wrapped in `#if LOCALVOXTRAL_DOGFOOD` like the rest of
/// this directory: the row exists in every build variant (a constant group
/// structure is the settings-pane rule), and keeping the strings pure lets the
/// tier-0 suite pin them without the compile flag. Only `isDogfoodBuild`
/// consults the flag — it is the in-binary ground truth that
/// `package_app.sh` mirrors into Info.plist as `LVXDogfoodCapture`.
enum DogfoodBuildStatus {
    static var isDogfoodBuild: Bool {
        #if LOCALVOXTRAL_DOGFOOD
        true
        #else
        false
        #endif
    }

    static func label(isDogfoodBuild: Bool, captureArmed: Bool) -> String {
        guard isDogfoodBuild else { return "Standard" }
        return captureArmed ? "Dogfood — capture armed" : "Dogfood — capture disarmed"
    }

    /// One short reference line under the label; nil for standard builds,
    /// which have nothing to say (and must not advertise dogfood plumbing).
    static func detail(isDogfoodBuild: Bool, captureArmed: Bool) -> String? {
        guard isDogfoodBuild else { return nil }
        return captureArmed
            ? "Records: ~/Library/Application Support/localvoxtral/dogfood"
            : "Arm: defaults write com.localvoxtral.app debug.dogfood_capture_enabled -bool true (relaunch)"
    }
}

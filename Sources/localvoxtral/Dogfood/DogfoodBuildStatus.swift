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
}

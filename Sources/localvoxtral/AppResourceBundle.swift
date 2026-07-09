import Foundation

extension Bundle {
    /// The app's SwiftPM resource bundle, resolved so it works BOTH in a
    /// packaged .app and in dev contexts (`swift build/run/test`).
    ///
    /// `Bundle.module` cannot be used directly in a packaged app: SwiftPM's
    /// generated accessor only checks the .app ROOT and the builder's
    /// absolute `.build` path, while `package_app.sh` installs the bundle at
    /// `Contents/Resources`. On any machine without that `.build` path the
    /// accessor `fatalError`s at first touch — a launch crash that
    /// same-machine CI smoke used to mask (#87). Patching the generated
    /// accessor is not an option either: the toolchain regenerates it clean
    /// on every build, silently reverting the patch (that was #87's root
    /// cause). So resolve `Contents/Resources` first, and only fall back to
    /// `Bundle.module` where its build-path candidate is actually valid
    /// (dev builds and tests, which run out of `.build`).
    static let localvoxtralResources: Bundle = {
        if let url = Bundle.main.resourceURL?
            .appendingPathComponent("localvoxtral_localvoxtral.bundle"),
            let bundle = Bundle(url: url)
        {
            return bundle
        }
        return .module
    }()
}

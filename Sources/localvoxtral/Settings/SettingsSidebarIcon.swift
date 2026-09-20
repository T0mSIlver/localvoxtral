import AppKit
import SwiftUI

/// What a Settings sidebar row draws left of its title.
enum SettingsSidebarIcon: Hashable {
    /// A colored tile with a white SF Symbol: the app's own panes.
    case tile(systemImage: String, tint: Color)
    /// A bundled monochrome brand mark (`Resources/BrandIcons`), drawn in the
    /// row's label color.
    case brandMark(resourceName: String)
    /// An SF Symbol drawn like a brand mark. Terminal.app's mark is Apple's
    /// `apple.terminal` symbol, which Apple provides for referring to that app.
    case symbolMark(systemName: String)
    /// A user-added app's real icon, desaturated. The app ships no mark we
    /// could bundle, so LaunchServices supplies the icon.
    case appIcon(bundleIDs: [String])
}

extension TerminalAppDescriptor {
    var sidebarIcon: SettingsSidebarIcon {
        if isUserAdded {
            return .appIcon(bundleIDs: detectionBundleIDs)
        }
        if slug == "apple-terminal" {
            return .symbolMark(systemName: "apple.terminal")
        }
        return .brandMark(resourceName: "BrandIcon-\(slug)")
    }
}

/// Loads the sidebar's brand marks.
///
/// Every mark is a single-color SVG loaded as a template image, so SwiftUI
/// tints it black, white, or the selected-row color. Sources, all reduced to
/// one fill:
///
/// - Simple Icons (CC0): Claude, opencode, Mistral AI (the Vibe row), Ghostty, iTerm2, Warp, WezTerm,
///   Alacritty, Hyper.
/// - The projects' own repositories: herdr (`assets/logo.svg`; its ram bleeds
///   off the square, so it is knocked out of a rounded tile rather than
///   left with hard cuts), cmux (the sign-in chevron, gradient dropped),
///   kitty (`logo/kitty.svg`), Tabby (`app/assets/logo.svg`, side faces at
///   half alpha to keep the depth), Rio (`misc/logo-2024.svg`, eyes knocked
///   out of the tile).
///
/// The marks are their owners' trademarks, shown only to identify the
/// integration a row configures.
@MainActor
enum SettingsBrandMarks {
    private static var brandCache: [String: NSImage] = [:]
    /// Marks that failed to load. The bundle cannot change under a running
    /// app, so a miss is remembered: rows re-render on every hover, and the
    /// failure is logged once instead of on each pass.
    private static var brandMisses: Set<String> = []
    private static var appIconCache: [String: NSImage] = [:]
    /// Bundle IDs LaunchServices did not resolve. Remembered for the same
    /// reason as `brandMisses`: a row for a removed app would otherwise ask
    /// LaunchServices again on every hover.
    private static var appIconMisses: Set<String> = []
    /// Seam for tests; production asks LaunchServices.
    static var applicationURLLookup: (String) -> URL? = {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
    }

    static func image(resourceName: String) -> NSImage? {
        if let cached = brandCache[resourceName] {
            return cached
        }
        if brandMisses.contains(resourceName) {
            return nil
        }
        guard
            let url = Bundle.localvoxtralResources.url(
                forResource: resourceName, withExtension: "svg"
            ),
            let image = NSImage(contentsOf: url)
        else {
            brandMisses.insert(resourceName)
            Log.config.error(
                "Settings brand mark \(resourceName, privacy: .public).svg did not load"
            )
            return nil
        }
        image.isTemplate = true
        brandCache[resourceName] = image
        return image
    }

    /// The first installed app among `bundleIDs`. Hits and misses are both
    /// cached until `forgetAppIcons()`, which the terminal model's installed
    /// sweep calls, so icons refresh on the same schedule as the rows' dots:
    /// each Settings open and each add or remove.
    static func appIcon(bundleIDs: [String]) -> NSImage? {
        for bundleID in bundleIDs {
            if let cached = appIconCache[bundleID] {
                return cached
            }
            if appIconMisses.contains(bundleID) {
                continue
            }
            if let url = applicationURLLookup(bundleID) {
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                appIconCache[bundleID] = icon
                return icon
            }
            appIconMisses.insert(bundleID)
        }
        return nil
    }

    static func forgetAppIcons() {
        appIconCache.removeAll()
        appIconMisses.removeAll()
    }

    #if DEBUG
    static func resetCachesForTesting() {
        brandCache.removeAll()
        brandMisses.removeAll()
        forgetAppIcons()
        applicationURLLookup = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    }
    #endif
}

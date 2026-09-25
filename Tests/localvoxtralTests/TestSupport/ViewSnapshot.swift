import AppKit
import CryptoKit
import SwiftUI
import XCTest

/// Renders a SwiftUI view to a PNG the way the app shows it: in an
/// `NSHostingView` inside a window, drawn with `cacheDisplay(in:to:)`.
/// `ImageRenderer` cannot draw a `ScrollView` or an `NSViewRepresentable`,
/// and every Settings pane is both.
///
/// The window is never ordered on screen, so a run on a Mac with someone at
/// the keyboard shows nothing.
@MainActor
enum ViewSnapshot {
    /// Where the PNGs go: `LOCALVOXTRAL_SNAPSHOT_DIR` when set, else
    /// `.build/snapshots` in the package. CI uploads the second.
    static var directory: URL {
        if let path = ProcessInfo.processInfo.environment["LOCALVOXTRAL_SNAPSHOT_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // TestSupport
            .deletingLastPathComponent()  // localvoxtralTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // package root
            .appendingPathComponent(".build/snapshots", isDirectory: true)
    }

    /// Lays `view` out at `width` × `height`, lets SwiftUI run its appear
    /// handlers, and writes `<name>.png`. With `growToFit`, the window grows
    /// until no scroll view inside it has content past its bottom edge, so a
    /// long Settings pane is pictured whole instead of cut at the window's
    /// default height.
    @discardableResult
    static func record<V: View>(
        _ view: V,
        name: String,
        width: CGFloat,
        height: CGFloat,
        growToFit: Bool = false,
        appearance: NSAppearance.Name = .aqua
    ) throws -> URL {
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless], backing: .buffered, defer: false)
        // Without it, `close()` releases the window a second time when the
        // test's reference goes: a segfault in the next test.
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        defer { window.close() }

        settle(hosting)
        if growToFit {
            // A pane can grow twice: the first pass reveals rows that were
            // not laid out while they sat below the fold.
            for _ in 0..<4 {
                let overflow = scrollOverflow(in: hosting)
                guard overflow > 0.5 else { break }
                window.setContentSize(
                    NSSize(width: width, height: hosting.frame.height + overflow.rounded(.up)))
                settle(hosting)
            }
        }

        let bounds = hosting.bounds
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: bounds) else {
            throw SnapshotError.noBitmap(name)
        }
        hosting.cacheDisplay(in: bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw SnapshotError.noPNG(name)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(name).png")
        try png.write(to: url, options: .atomic)
        // In the log so two runs can be compared without their artifacts:
        // equal hashes are pixel-identical renders.
        let digest = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
        print("view-snapshot \(name).png sha256=\(digest)")
        return url
    }

    /// Several turns of the main run loop, each handling only what is already
    /// pending (`.distantPast` returns at once; nothing waits on the clock):
    /// SwiftUI runs `onAppear`, commits the state it sets, and a scroll view
    /// sizes its document on the turn after the first layout.
    private static func settle(_ view: NSView) {
        for _ in 0..<5 {
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(mode: .default, before: .distantPast)
        }
        view.layoutSubtreeIfNeeded()
    }

    /// How far the tallest scroll document reaches past its scroll view.
    private static func scrollOverflow(in view: NSView) -> CGFloat {
        var overflow: CGFloat = 0
        if let scrollView = view as? NSScrollView, let document = scrollView.documentView {
            overflow = document.frame.height - scrollView.contentView.bounds.height
        }
        for subview in view.subviews {
            overflow = max(overflow, scrollOverflow(in: subview))
        }
        return overflow
    }

    enum SnapshotError: Error {
        case noBitmap(String)
        case noPNG(String)
    }
}

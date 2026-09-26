import Darwin
import Foundation
import localvoxtralCore

/// Reads the snapshot the app wrote. The sandbox moves `NSHomeDirectory()`
/// into the extension's container; the file lives under the real home, which
/// the extension's entitlements open read-only.
enum SnapshotFile {
    static var url: URL {
        let home: URL
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir {
            home = URL(fileURLWithPath: String(cString: directory), isDirectory: true)
        } else {
            home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        }
        return WidgetShared.fileURL(home: home)
    }

    static func read() -> WidgetSnapshot? {
        do {
            let snapshot = try JSONDecoder().decode(WidgetSnapshot.self, from: Data(contentsOf: url))
            guard snapshot.version == WidgetSnapshot.currentVersion else {
                Log.widgets.notice("snapshot version \(snapshot.version, privacy: .public) is not this widget's; waiting for the app to rewrite it")
                return nil
            }
            return snapshot
        } catch {
            Log.widgets.notice("no widget snapshot to read yet: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

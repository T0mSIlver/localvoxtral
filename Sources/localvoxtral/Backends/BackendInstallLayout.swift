import Foundation

struct BackendInstallLayout: Equatable, Sendable {
    let root: URL

    init(root: URL? = nil) {
        if let root {
            self.root = root
        } else {
            let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            self.root = applicationSupport
                .appendingPathComponent("localvoxtral", isDirectory: true)
                .appendingPathComponent("backends", isDirectory: true)
        }
    }

    // The remaining child paths describe only legacy installs swept at launch.
    // Bundled executables and Hugging Face snapshots never live under root.
    var tools: URL {
        root.appendingPathComponent("tools", isDirectory: true)
    }

    var toolBin: URL {
        root.appendingPathComponent("bin", isDirectory: true)
    }

    var downloads: URL {
        root.appendingPathComponent("downloads", isDirectory: true)
    }
}

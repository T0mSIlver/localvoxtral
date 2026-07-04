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

    var uvCache: URL {
        root.appendingPathComponent("uv-cache", isDirectory: true)
    }

    var uvBinaryDirectory: URL {
        root
            .appendingPathComponent("uv", isDirectory: true)
            .appendingPathComponent(UVDistribution.pinned.version, isDirectory: true)
    }

    var managedUVBinary: URL {
        uvBinaryDirectory.appendingPathComponent("uv")
    }

    var pythonInstalls: URL {
        root.appendingPathComponent("python", isDirectory: true)
    }

    var tools: URL {
        root.appendingPathComponent("tools", isDirectory: true)
    }

    var toolBin: URL {
        root.appendingPathComponent("bin", isDirectory: true)
    }

    var downloads: URL {
        root.appendingPathComponent("downloads", isDirectory: true)
    }

    var environment: [String: String] {
        [
            "UV_CACHE_DIR": uvCache.path,
            "UV_PYTHON_INSTALL_DIR": pythonInstalls.path,
            "UV_TOOL_DIR": tools.path,
            "UV_TOOL_BIN_DIR": toolBin.path,
        ]
    }
}

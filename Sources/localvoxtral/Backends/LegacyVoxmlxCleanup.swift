import Foundation

/// Best-effort removal of the retired app-managed voxmlx installation. Every
/// candidate is constructed beneath the app-owned backend root; shared Hugging
/// Face model snapshots live elsewhere and are deliberately untouched.
struct LegacyVoxmlxCleanup {
    private let layout: BackendInstallLayout
    private let fileManager: FileManager

    init(layout: BackendInstallLayout = BackendInstallLayout(), fileManager: FileManager = .default) {
        self.layout = layout
        self.fileManager = fileManager
    }

    @discardableResult
    func run() -> [URL] {
        var removed: [URL] = []

        removeIfPresent(
            layout.tools.appendingPathComponent("voxmlx", isDirectory: true),
            into: &removed
        )
        for entry in entries(of: layout.toolBin, withPrefix: "voxmlx") {
            removeIfPresent(entry, into: &removed)
        }
        for entry in entries(of: layout.downloads, withPrefix: "voxmlx") {
            removeIfPresent(entry, into: &removed)
        }

        // These directories existed only to install and run Python backends.
        for name in ["uv", "uv-cache", "python"] {
            removeIfPresent(layout.root.appendingPathComponent(name, isDirectory: true), into: &removed)
        }
        if dropInstalledMarkerEntry() {
            removed.append(installedMarkerURL)
        }

        if !removed.isEmpty {
            Log.backends.notice(
                "Removed retired voxmlx install: \(removed.map(\.lastPathComponent).joined(separator: ", "), privacy: .public)"
            )
        }
        return removed
    }

    private var installedMarkerURL: URL {
        layout.root.appendingPathComponent("installed.json")
    }

    private func entries(of directory: URL, withPrefix prefix: String) -> [URL] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        return names
            .filter { $0.hasPrefix(prefix) }
            .map { directory.appendingPathComponent($0) }
    }

    private func removeIfPresent(_ url: URL, into removed: inout [URL]) {
        guard isUnderOwnedRoot(url) else {
            Log.backends.error(
                "Retired voxmlx cleanup refused path outside app backend root: \(url.path, privacy: .public)"
            )
            return
        }
        do {
            try fileManager.removeItem(at: url)
            removed.append(url)
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError
        {
            // Idempotent no-op.
        } catch {
            Log.backends.error(
                "Retired voxmlx cleanup failed for \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func isUnderOwnedRoot(_ url: URL) -> Bool {
        let root = layout.root.standardizedFileURL.path
        let candidate = url.standardizedFileURL.path
        return candidate.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    private func dropInstalledMarkerEntry() -> Bool {
        guard fileManager.fileExists(atPath: installedMarkerURL.path),
              let data = try? Data(contentsOf: installedMarkerURL),
              var marker = (try? JSONSerialization.jsonObject(with: data)) as? [String: String],
              marker.removeValue(forKey: "voxmlx") != nil
        else { return false }

        do {
            let rewritten = try JSONSerialization.data(
                withJSONObject: marker,
                options: [.prettyPrinted, .sortedKeys]
            )
            try rewritten.write(to: installedMarkerURL, options: .atomic)
            return true
        } catch {
            Log.backends.error(
                "Retired voxmlx cleanup failed to rewrite installed.json: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }
}

extension LegacyVoxmlxCleanup: @unchecked Sendable {}

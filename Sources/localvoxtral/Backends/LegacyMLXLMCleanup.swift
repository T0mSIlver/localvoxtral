import Foundation

/// Best-effort removal of the uv-installed mlx-lm polishing backend left
/// behind on user Macs after the bundled `localvoxtral-polishd` helper
/// replaced it (2026-07). Idempotent: once everything is gone, running it
/// again is a silent no-op, so it runs on every launch.
///
/// Deliberately untouched: the voxmlx tool (still uv-installed), the managed
/// uv binary and its caches (voxmlx installs/updates still need them), and
/// the downloaded model weights (the bundled helper reads the same HF cache
/// the old engine populated).
struct LegacyMLXLMCleanup {
    private let layout: BackendInstallLayout
    private let fileManager: FileManager

    /// uv tool venv directory name (`tools/mlx-lm`) and `installed.json` key.
    private static let legacyToolID = "mlx-lm"
    /// Entry points uv linked into `bin/` (`mlx_lm.server`, `mlx_lm.generate`, …).
    private static let legacyBinPrefix = "mlx_lm."
    /// Wheels the installer parked in `downloads/`.
    private static let legacyWheelPrefix = "mlx_lm-"

    init(layout: BackendInstallLayout = BackendInstallLayout(), fileManager: FileManager = .default) {
        self.layout = layout
        self.fileManager = fileManager
    }

    /// Removes whatever legacy pieces exist and returns their URLs (empty when
    /// there was nothing to do). Failures are logged and skipped — cleanup
    /// must never block launch.
    @discardableResult
    func run() -> [URL] {
        var removed: [URL] = []

        removeIfPresent(
            layout.tools.appendingPathComponent(Self.legacyToolID, isDirectory: true),
            into: &removed
        )
        for entry in entries(of: layout.toolBin, withPrefix: Self.legacyBinPrefix) {
            removeIfPresent(entry, into: &removed)
        }
        for entry in entries(of: layout.downloads, withPrefix: Self.legacyWheelPrefix) {
            removeIfPresent(entry, into: &removed)
        }
        if dropLegacyInstalledMarkerEntry() {
            removed.append(installedMarkerURL)
        }

        if !removed.isEmpty {
            Log.backends.info(
                "Removed orphaned mlx-lm install: \(removed.map(\.lastPathComponent).joined(separator: ", "), privacy: .public)"
            )
        }
        return removed
    }

    private var installedMarkerURL: URL {
        layout.root.appendingPathComponent("installed.json")
    }

    /// Directory listing by name prefix. Dangling symlinks (uv links bin
    /// entries into the tool venv, which may already be gone) still show up
    /// here, unlike with `fileExists(atPath:)`.
    private func entries(of directory: URL, withPrefix prefix: String) -> [URL] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        return names
            .filter { $0.hasPrefix(prefix) }
            .map { directory.appendingPathComponent($0) }
    }

    private func removeIfPresent(_ url: URL, into removed: inout [URL]) {
        // removeItem handles dangling symlinks (it unlinks, not resolves);
        // a missing path throws NSFileNoSuchFileError, which is the no-op case.
        do {
            try fileManager.removeItem(at: url)
            removed.append(url)
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError
        {
            // Already gone — the idempotent path.
        } catch {
            Log.backends.error(
                "Orphaned mlx-lm cleanup failed for \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Drops the `mlx-lm` entry from `installed.json` so the marker only
    /// tracks backends the app still installs. Returns true when it rewrote
    /// the file.
    private func dropLegacyInstalledMarkerEntry() -> Bool {
        guard fileManager.fileExists(atPath: installedMarkerURL.path),
              let data = try? Data(contentsOf: installedMarkerURL),
              var marker = (try? JSONSerialization.jsonObject(with: data)) as? [String: String],
              marker.removeValue(forKey: Self.legacyToolID) != nil
        else {
            return false
        }
        do {
            let rewritten = try JSONSerialization.data(
                withJSONObject: marker,
                options: [.prettyPrinted, .sortedKeys]
            )
            try rewritten.write(to: installedMarkerURL, options: .atomic)
            return true
        } catch {
            Log.backends.error(
                "Orphaned mlx-lm cleanup failed to rewrite installed.json: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }
}

extension LegacyMLXLMCleanup: @unchecked Sendable {}

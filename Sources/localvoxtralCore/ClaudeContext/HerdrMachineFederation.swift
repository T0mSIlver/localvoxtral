import Foundation

#if canImport(Darwin) || canImport(Glibc)
#if canImport(Darwin)
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
#else
import Glibc
#endif

/// What herdr's saved-machine feature says about the client on this Mac.
///
/// herdr 0.9.0 attaches several SSH machines to ONE local client
/// (`herdr machine add`). While a remote machine is selected, the local server
/// keeps a focused pane it has merely stopped presenting, so `pane.current` on
/// the local socket stops describing what the user is looking at. The local
/// herdr arm asks this before it trusts that answer (issue #286).
///
/// Federation lives entirely in herdr's CLIENT: the catalog is a per-user file,
/// no server knows about it, and the socket API exposes nothing about it. Files
/// are therefore the only place to read it, short of running herdr's own CLI,
/// which a GUI app cannot locate reliably.
package enum HerdrMachineFederation: Sendable, Equatable {
    /// No saved machines. The local socket's focused pane is what the surface
    /// displays, exactly as it was before 0.9.
    case notFederated
    /// Machines are saved and the client is showing Local.
    case showingLocal
    /// Machines are saved and the client is showing this one.
    case showingMachine(HerdrMachineProfile)
    /// herdr's state is present but could not be read or decoded.
    case unreadable

    /// The more abstaining of two readings, used to merge the release and
    /// development state directories. A user runs one of them; the other is
    /// absent, which reads as `notFederated` and never masks the live one.
    package static func moreAbstaining(
        _ first: HerdrMachineFederation, _ second: HerdrMachineFederation
    ) -> HerdrMachineFederation {
        func rank(_ value: HerdrMachineFederation) -> Int {
            switch value {
            case .notFederated: return 0
            case .showingLocal: return 1
            case .showingMachine: return 2
            case .unreadable: return 3
            }
        }
        return rank(first) >= rank(second) ? first : second
    }
}

/// Whether a socket path is the API socket of one named herdr session.
///
/// herdr derives the socket from the session name alone
/// (`src/session.rs::api_socket_path_for` → `data_dir_for`): the default
/// session keeps it at `<config dir>/herdr.sock`, a named one at
/// `<config dir>/sessions/<name>/herdr.sock`. A federated machine names its
/// session in the profile, and the sessions it hosts publish
/// `HERDR_SOCKET_PATH` — this is the pure classification that reconciles the
/// two, so the federated join arm can keep only the candidates that live on
/// the machine the client is showing.
///
/// Every input is lexically normalized before splitting (see
/// `normalizedSocketPath`), and the single-socket count in the arm is computed
/// over those normalized paths: two spellings of one server must count as one,
/// and one spelling must never join as another.
///
/// The default session refuses the trailing `sessions` namespace: a socket
/// sitting directly in a `sessions` directory or in `sessions/<name>` is
/// never the default session's socket in any herdr configuration. A
/// `sessions` component HIGHER up (an XDG-relocated root, a directory
/// literally named `sessions`) does not retire the default match — only the
/// last components decide. A session literally named "default" IS the
/// default session (`src/session.rs::normalize_name` maps it to the bare
/// `<config dir>/herdr.sock`), so `…/sessions/default/herdr.sock` is refused
/// for it.
///
/// The comparison is case-sensitive on the normalized string: herdr writes
/// these paths, and a classifier may not assume the filesystem's case rules.
package enum HerdrSessionSocket {
    package static let socketFileName = "herdr.sock"
    package static let sessionsDirectoryName = "sessions"
    /// herdr's `validate_name` (`src/session.rs`): ASCII letters, numbers,
    /// `.`, `_`, `-`; non-empty, at most 64 bytes, never `.` or `..`.
    package static let maximumSessionNameBytes = 64

    /// Lexically standardized path: collapses `.`, `..`, and `//`, and drops
    /// a trailing `/` or `/.`. Pure string work with no filesystem access, so
    /// an attacker-shaped `HERDR_SOCKET_PATH` label cannot make this touch the
    /// disk. Case is preserved (see above).
    package static func normalizedSocketPath(_ path: String) -> String {
        let isAbsolute = path.hasPrefix("/")
        var components: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: false) {
            switch component {
            case "", ".":
                continue
            case "..":
                if !components.isEmpty { components.removeLast() }
            default:
                components.append(component)
            }
        }
        let joined = components.joined(separator: "/")
        return isAbsolute ? "/" + joined : joined
    }

    /// herdr's `validate_name`, mirrored so a profile session name that herdr
    /// itself would refuse cannot classify any socket.
    package static func isValidSessionName(_ name: String) -> Bool {
        guard !name.isEmpty,
              name != ".",
              name != "..",
              name.utf8.count <= maximumSessionNameBytes
        else { return false }
        return name.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-")
        }
    }

    /// The socket path of the session named `sessionName`, or nil when the
    /// path does not follow herdr's layout for that session.
    package static func isSocket(
        _ path: String,
        ofSessionNamed sessionName: String
    ) -> Bool {
        let normalized = normalizedSocketPath(path)
        guard normalized.hasPrefix("/") else { return false }
        let components = normalized.split(separator: "/", omittingEmptySubsequences: true)
        guard components.last == Substring(socketFileName) else { return false }
        // Rebased to zero-based indices: the slice keeps the split's own.
        let directory = Array(components.dropLast())

        if sessionName == HerdrMachineProfile.defaultSessionName {
            // Not a shape herdr writes for any session, and never the default
            // one — refused fail-closed.
            return !(directory.last == Substring(sessionsDirectoryName)
                || (directory.count >= 2
                    && directory[directory.count - 2] == Substring(sessionsDirectoryName)))
        }
        guard isValidSessionName(sessionName), directory.count >= 2 else { return false }
        return directory[directory.count - 2] == Substring(sessionsDirectoryName)
            && directory[directory.count - 1] == Substring(sessionName)
    }
}

/// One saved machine, as `herdr machine add` recorded it. The fields are the
/// ones `herdr machine list --json` prints; the catalog holds nothing else
/// (no credentials, no key material, no control sockets).
///
/// Public because the public `HerdrMachineImportCandidate` carries one: a
/// public struct's public property cannot name an internal type.
public struct HerdrMachineProfile: Sendable, Equatable, Hashable, Identifiable {
    /// herdr's opaque profile id (32 lowercase hex digits).
    public var id: String
    /// The user-facing name given at `machine add`.
    public var label: String
    /// The ssh destination exactly as the user typed it: an ssh config alias,
    /// `user@host`, or an `ssh://` URL. Never canonicalized here.
    public var target: String
    /// The remote herdr session the profile attaches. herdr's default session
    /// keeps its socket at `<config dir>/herdr.sock`; a named one lives at
    /// `<config dir>/sessions/<name>/herdr.sock`.
    public var session: String
    public var enabled: Bool

    package static let defaultSessionName = "default"

    package init(id: String, label: String, target: String, session: String, enabled: Bool) {
        self.id = id
        self.label = label
        self.target = target
        self.session = session
        self.enabled = enabled
    }
}

/// herdr's saved-machine catalog, resolved the way a client starting now
/// would resolve it: every profile in file order, and the selected one after
/// the selection file and the catalog's own copy have been reconciled.
///
/// Public because the public `HerdrMachineCatalogReading` carries one as an
/// associated value; the members stay internal.
public struct HerdrMachineCatalog: Sendable, Equatable {
    package var profiles: [HerdrMachineProfile]
    /// The enabled profile the client is showing, or nil for Local.
    package var selectedProfileID: String?

    package var selectedProfile: HerdrMachineProfile? {
        guard let selectedProfileID else { return nil }
        return profiles.first { $0.id == selectedProfileID && $0.enabled }
    }

    package var enabledProfiles: [HerdrMachineProfile] { profiles.filter(\.enabled) }

    package init(profiles: [HerdrMachineProfile], selectedProfileID: String? = nil) {
        self.profiles = profiles
        self.selectedProfileID = selectedProfileID
    }
}

/// The catalog as the reader found it. `absent` and `unreadable` are kept
/// apart for the same reason `HerdrStateFile` keeps them apart.
///
/// Public because the public settings-model init takes a seam returning one;
/// a public signature cannot name an internal type.
public enum HerdrMachineCatalogReading: Sendable, Equatable {
    /// No catalog file: this user never ran `herdr machine add`.
    case absent
    case catalog(HerdrMachineCatalog)
    /// A catalog or selection file exists and could not be read or decoded.
    case unreadable
}

/// One state file as the reader found it. `absent` and `unreadable` are kept
/// apart on purpose: a missing catalog means this user saved no machines, while
/// a catalog that exists and cannot be read means the arm knows nothing and
/// must abstain.
package enum HerdrStateFile: Sendable, Equatable {
    case absent
    case contents(Data)
    case unreadable
}

/// Reads herdr's client-side machine catalog and machine selection.
///
/// The two files are `<state dir>/client/endpoints.json` (the saved machines)
/// and `<state dir>/client/endpoint-selection.json` (the one being viewed,
/// rewritten by the client on every switch). herdr's state directory is
/// `$XDG_STATE_HOME/herdr` when that variable is set and `~/.local/state/herdr`
/// otherwise, with `herdr-dev` in place of `herdr` for a development build.
///
/// KNOWN RESIDUAL: a GUI app does not see the user's shell environment, so a
/// user who exports `XDG_STATE_HOME` relocates the catalog somewhere this
/// reader cannot find, and reads back `notFederated`. That leaves them on the
/// pre-0.9 behavior this guard exists to correct. Closing it needs herdr's own
/// CLI, whose path a GUI app cannot resolve either.
package struct HerdrMachineFederationReader: Sendable {
    private let clientDirectories: [URL]
    private let readFile: @Sendable (URL) -> HerdrStateFile

    package init(clientDirectories: [URL], readFile: @escaping @Sendable (URL) -> HerdrStateFile) {
        self.clientDirectories = clientDirectories
        self.readFile = readFile
    }

    /// Production reader over this user's home directory.
    package static func live() -> HerdrMachineFederationReader {
        HerdrMachineFederationReader(
            clientDirectories: Self.liveClientDirectories(),
            readFile: Self.liveReadFile
        )
    }

    package func federation() -> HerdrMachineFederation {
        clientDirectories
            .map { Self.federation(from: catalog(inClientDirectory: $0)) }
            .reduce(.notFederated, HerdrMachineFederation.moreAbstaining)
    }

    /// Every saved machine across the release and development state
    /// directories, for callers that need the profiles themselves (the
    /// Settings import offer, the federated join arm). A user runs one build,
    /// so at most one directory has a catalog; two catalogs are concatenated
    /// in directory order and the first selection wins. Any unreadable
    /// directory makes the whole reading unreadable: a partial list would
    /// silently omit the machine the user is looking at.
    package func catalog() -> HerdrMachineCatalogReading {
        var merged: HerdrMachineCatalog?
        for directory in clientDirectories {
            switch catalog(inClientDirectory: directory) {
            case .absent:
                continue
            case .unreadable:
                return .unreadable
            case .catalog(let found):
                if var existing = merged {
                    existing.profiles += found.profiles
                    if existing.selectedProfileID == nil {
                        existing.selectedProfileID = found.selectedProfileID
                    }
                    merged = existing
                } else {
                    merged = found
                }
            }
        }
        return merged.map(HerdrMachineCatalogReading.catalog) ?? .absent
    }

    /// What one catalog reading means for the local herdr arm. Disabled
    /// machines are not connected and cannot be selected, so a catalog with no
    /// enabled profile leaves the arm exactly where it was.
    package static func federation(from reading: HerdrMachineCatalogReading) -> HerdrMachineFederation {
        switch reading {
        case .absent:
            return .notFederated
        case .unreadable:
            return .unreadable
        case .catalog(let catalog):
            guard !catalog.enabledProfiles.isEmpty else { return .notFederated }
            return catalog.selectedProfile.map(HerdrMachineFederation.showingMachine) ?? .showingLocal
        }
    }

    private func catalog(inClientDirectory directory: URL) -> HerdrMachineCatalogReading {
        let catalogFile = readFile(directory.appendingPathComponent("endpoints.json"))
        switch catalogFile {
        case .absent:
            // No catalog is the state of every herdr before 0.9 and of every
            // 0.9 user who saved no machine. Nothing to guard against.
            return .absent
        case .unreadable:
            return .unreadable
        case .contents(let data):
            guard let catalog = try? JSONDecoder().decode(Catalog.self, from: data),
                  catalog.version == Self.supportedStateVersion
            else { return .unreadable }
            let profiles = (catalog.ssh ?? []).map {
                HerdrMachineProfile(
                    id: $0.id,
                    label: $0.label,
                    target: $0.target,
                    session: $0.session,
                    enabled: $0.enabled
                )
            }
            let enabled = Set(profiles.filter(\.enabled).map(\.id))
            guard !enabled.isEmpty else {
                // With nothing enabled there is nothing to select, and the
                // selection file cannot make a machine appear; it is not read.
                return .catalog(HerdrMachineCatalog(profiles: profiles, selectedProfileID: nil))
            }
            switch selectedProfile(
                inClientDirectory: directory, enabledProfiles: enabled, catalog: catalog
            ) {
            case .success(let selected):
                return .catalog(HerdrMachineCatalog(profiles: profiles, selectedProfileID: selected))
            case .failure:
                return .unreadable
            }
        }
    }

    /// Which machine the client is showing, or nil for Local.
    ///
    /// herdr resolves this in `load_from_paths` (`src/client/endpoint/catalog.rs`)
    /// and this follows it exactly. A selection file naming an enabled profile
    /// wins. A selection file saying Local wins too, and overrides the copy the
    /// catalog carries. Only a selection that names a profile which is gone or
    /// disabled loses, and then the catalog's copy answers. A selection file
    /// that exists and cannot be decoded fails instead, because with machines
    /// saved it is the only thing that separates Local from a machine.
    private func selectedProfile(
        inClientDirectory directory: URL,
        enabledProfiles: Set<String>,
        catalog: Catalog
    ) -> Result<String?, SelectionUnreadable> {
        let catalogSelection = catalog.selectedProfile.flatMap { enabledProfiles.contains($0) ? $0 : nil }
        switch readFile(directory.appendingPathComponent("endpoint-selection.json")) {
        case .absent:
            return .success(catalogSelection)
        case .unreadable:
            return .failure(SelectionUnreadable())
        case .contents(let data):
            guard let selection = try? JSONDecoder().decode(Selection.self, from: data),
                  selection.version == Self.supportedStateVersion
            else { return .failure(SelectionUnreadable()) }
            guard let selected = selection.selectedProfile else {
                // herdr writes null for Local, and serde reads a missing field
                // as the same None, so both mean Local here.
                return .success(nil)
            }
            return .success(enabledProfiles.contains(selected) ? selected : catalogSelection)
        }
    }

    private struct SelectionUnreadable: Error {}

    /// herdr refuses any other version in its own loader and runs the client
    /// Local-only when it does. This reader abstains instead of guessing: a
    /// future schema that renames or reinterprets these fields would otherwise
    /// decode as "no machines saved" and silently retire the guard.
    private static let supportedStateVersion = 1

    /// herdr's `SavedSshEndpoint` is `deny_unknown_fields` and every field is
    /// required, so a profile missing one of these is not a catalog herdr
    /// itself would load; decoding fails and the reading is unreadable.
    private struct Catalog: Decodable {
        struct Profile: Decodable {
            var id: String
            var label: String
            var target: String
            var session: String
            var enabled: Bool
        }

        var version: Int
        var selectedProfile: String?
        var ssh: [Profile]?

        enum CodingKeys: String, CodingKey {
            case version
            case selectedProfile = "selected_profile"
            case ssh
        }
    }

    private struct Selection: Decodable {
        var version: Int
        var selectedProfile: String?

        enum CodingKeys: String, CodingKey {
            case version
            case selectedProfile = "selected_profile"
        }
    }

    // MARK: - Live file access

    private static func liveClientDirectories() -> [URL] {
        let state: URL
        if let overridden = ProcessInfo.processInfo.environment["XDG_STATE_HOME"], !overridden.isEmpty {
            state = URL(fileURLWithPath: overridden, isDirectory: true)
        } else {
            state = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent(".local/state", isDirectory: true)
        }
        // A development build of herdr keeps its own directory, and a user
        // running one is federated just the same.
        return ["herdr", "herdr-dev"].map {
            state.appendingPathComponent($0, isDirectory: true)
                .appendingPathComponent("client", isDirectory: true)
        }
    }

    /// Reads one state file, refusing anything that is not a plain file this
    /// user owns. The refusals are `unreadable`, never `absent`: a path that
    /// exists in a shape this reader does not understand is exactly the case
    /// the arm must not treat as "no machines saved".
    package static let liveReadFile: @Sendable (URL) -> HerdrStateFile = { url in
        // herdr caps its own catalog at 64 KiB, so a larger file is not a
        // catalog this reader understands.
        let maximumBytes: off_t = 64 * 1024
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            return errno == ENOENT || errno == ENOTDIR ? .absent : .unreadable
        }
        guard status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == geteuid(),
              status.st_size <= maximumBytes,
              let data = try? Data(contentsOf: url, options: [.uncached])
        else { return .unreadable }
        return .contents(data)
    }
}
#endif

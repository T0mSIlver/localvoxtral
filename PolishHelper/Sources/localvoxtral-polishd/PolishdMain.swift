import Foundation
import MLX
import PolishHelperCore

/// localvoxtral's bundled polishing engine: loads a local MLX model and
/// serves the OpenAI chat-completions subset on loopback. Spawned and
/// supervised by the app (BackendProcessSupervisor); /health only answers
/// once the model is loaded, matching the mlx_lm.server readiness contract.
@main
struct PolishdMain {
    struct Options {
        var modelID: String?
        var modelDirectory: String?
        var port: UInt16 = 8472
        var parentPID: pid_t?
        var defaultMaxTokens = 2048
        var cacheLimitMB = 64
    }

    static func main() async {
        do {
            try await run(options: try parse(arguments: Array(CommandLine.arguments.dropFirst())))
        } catch {
            PolishdLog.error("\(error)")
            exit(1)
        }
    }

    static func parse(arguments: [String]) throws -> Options {
        var options = Options()
        var iterator = arguments.makeIterator()
        func value(for flag: String) throws -> String {
            guard let next = iterator.next() else {
                throw OptionError.missingValue(flag)
            }
            return next
        }
        while let flag = iterator.next() {
            switch flag {
            case "--model": options.modelID = try value(for: flag)
            case "--model-dir": options.modelDirectory = try value(for: flag)
            case "--port":
                guard let port = UInt16(try value(for: flag)) else {
                    throw OptionError.invalidValue(flag)
                }
                options.port = port
            case "--parent-pid":
                guard let pid = pid_t(try value(for: flag)) else {
                    throw OptionError.invalidValue(flag)
                }
                options.parentPID = pid
            case "--default-max-tokens":
                guard let tokens = Int(try value(for: flag)), tokens > 0 else {
                    throw OptionError.invalidValue(flag)
                }
                options.defaultMaxTokens = tokens
            case "--cache-limit-mb":
                guard let limit = Int(try value(for: flag)), limit >= 0 else {
                    throw OptionError.invalidValue(flag)
                }
                options.cacheLimitMB = limit
            default:
                throw OptionError.unknownFlag(flag)
            }
        }
        guard options.modelID != nil || options.modelDirectory != nil else {
            throw OptionError.missingModel
        }
        return options
    }

    enum OptionError: Error, CustomStringConvertible {
        case missingValue(String)
        case invalidValue(String)
        case unknownFlag(String)
        case missingModel

        var description: String {
            switch self {
            case .missingValue(let flag): "missing value for \(flag)"
            case .invalidValue(let flag): "invalid value for \(flag)"
            case .unknownFlag(let flag): "unknown flag: \(flag)"
            case .missingModel: "one of --model <hf-repo-id> or --model-dir <path> is required"
            }
        }
    }

    static func run(options: Options) async throws {
        // Retained for the whole process lifetime — deinit cancels the kqueue
        // source, so a discarded watchdog silently never fires (integration
        // test testHelperExitsWhenParentPIDDies caught exactly that).
        var watchdog: ParentProcessWatchdog?
        if let parentPID = options.parentPID {
            watchdog = ParentProcessWatchdog(parentPID: parentPID) {
                PolishdLog.info("parent \(parentPID) exited; shutting down")
                exit(0)
            }
        }
        defer { withExtendedLifetime(watchdog) {} }

        let modelDirectory: URL
        if let path = options.modelDirectory {
            modelDirectory = URL(filePath: path)
        } else if let repoID = options.modelID {
            modelDirectory = try HFCacheModelLocator.locate(
                repoID: repoID,
                cacheRoot: HFCacheModelLocator.defaultCacheRoot()
            )
        } else {
            throw OptionError.missingModel
        }

        // Keep the recycling cache small: the polish model is <1 GB and the
        // helper idles between dictations — without a limit, freed buffers
        // linger as process footprint up to MLX's default (1.5x working set).
        Memory.cacheLimit = options.cacheLimitMB << 20

        PolishdLog.info("loading model from \(modelDirectory.path)")
        let loadStart = ContinuousClock.now
        let model = try await MLXPolishModel.load(
            directory: modelDirectory,
            defaultMaxTokens: options.defaultMaxTokens
        )
        PolishdLog.info("model loaded in \(loadStart.duration(to: .now)); \(memorySummary())")

        let router = PolishdRouter(
            responder: model,
            modelName: options.modelID ?? modelDirectory.lastPathComponent
        )
        let server = try HTTPServer(port: options.port) { request in
            await router.handle(request)
        }
        try await server.start()
        PolishdLog.info("ready on 127.0.0.1:\(server.boundPort)")

        while true {
            try await Task.sleep(for: .seconds(3600))
        }
    }

    static func memorySummary() -> String {
        "active \(Memory.activeMemory >> 20) MiB, cache \(Memory.cacheMemory >> 20) MiB"
    }
}

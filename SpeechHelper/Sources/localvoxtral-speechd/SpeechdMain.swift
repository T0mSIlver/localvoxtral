import Foundation
import SpeechEngine
import SpeechEngineText

/// localvoxtral's bundled realtime ASR engine: loads the Voxtral MLX model and serves the
/// OpenAI-Realtime websocket subset on loopback, a drop-in for the Python `voxmlx` process.
/// Spawned and supervised by the app (BackendProcessSupervisor); the model is loaded BEFORE
/// the listener binds, so `/health` becoming reachable is the readiness signal (matching the
/// supervisor's readinessURL contract).
@main
struct SpeechdMain {
    struct Options {
        var modelID: String?
        var modelDirectory: String?
        var port: UInt16 = 8471  // matches BackendCatalog.voxmlx.port
        var parentPID: pid_t?
        var transcriptionDelayMs: Int?
        var cacheLimitMB = 4096
    }

    enum OptionError: Error, CustomStringConvertible {
        case missingValue(String), invalidValue(String), unknownFlag(String), missingModel
        var description: String {
            switch self {
            case .missingValue(let f): return "missing value for \(f)"
            case .invalidValue(let f): return "invalid value for \(f)"
            case .unknownFlag(let f): return "unknown flag \(f)"
            case .missingModel: return "one of --model or --model-dir is required"
            }
        }
    }

    static func main() async {
        do {
            try await run(parse(Array(CommandLine.arguments.dropFirst())))
        } catch {
            FileHandle.standardError.write(Data("speechd: \(error)\n".utf8))
            exit(1)
        }
    }

    static func parse(_ arguments: [String]) throws -> Options {
        var options = Options()
        var it = arguments.makeIterator()
        func value(_ flag: String) throws -> String {
            guard let v = it.next() else { throw OptionError.missingValue(flag) }
            return v
        }
        while let flag = it.next() {
            switch flag {
            case "--model": options.modelID = try value(flag)
            case "--model-dir": options.modelDirectory = try value(flag)
            case "--port":
                guard let p = UInt16(try value(flag)) else { throw OptionError.invalidValue(flag) }
                options.port = p
            case "--parent-pid":
                guard let pid = pid_t(try value(flag)) else { throw OptionError.invalidValue(flag) }
                options.parentPID = pid
            case "--transcription-delay-ms":
                guard let ms = Int(try value(flag)), ms > 0 else { throw OptionError.invalidValue(flag) }
                options.transcriptionDelayMs = ms
            case "--cache-limit-mb":
                guard let mb = Int(try value(flag)), mb >= 0 else { throw OptionError.invalidValue(flag) }
                options.cacheLimitMB = mb
            default:
                throw OptionError.unknownFlag(flag)
            }
        }
        guard options.modelID != nil || options.modelDirectory != nil else {
            throw OptionError.missingModel
        }
        return options
    }

    static func run(_ options: Options) async throws {
        // Load BEFORE binding the listener so /health only answers once inference is ready.
        let server = try await RealtimeSpeechServer.load(
            modelID: options.modelID,
            modelDirectory: options.modelDirectory,
            port: options.port,
            transcriptionDelayMs: options.transcriptionDelayMs,
            cacheLimitMB: options.cacheLimitMB
        )

        // Exit if the supervising app dies, so a killed app never orphans the model.
        var watchdog: ParentProcessWatchdog?
        if let pid = options.parentPID {
            watchdog = ParentProcessWatchdog(parentPID: pid) {
                FileHandle.standardError.write(Data("speechd: parent \(pid) exited; stopping\n".utf8))
                exit(0)
            }
        }
        _ = watchdog  // retained for the process lifetime

        // A listener that dies in a live process is invisible to the supervisor (it only
        // watches process exit) — die loudly to get restarted.
        server.onListenerFailure = { error in
            FileHandle.standardError.write(Data("speechd: listener failed: \(error)\n".utf8))
            exit(1)
        }
        try await server.start()
        FileHandle.standardError.write(
            Data("speechd: ready on 127.0.0.1:\(server.boundPort)\n".utf8))

        // Park forever; the watchdog and listener-failure paths own process exit.
        try await withUnsafeThrowingContinuation { (_: UnsafeContinuation<Void, Error>) in }
    }
}

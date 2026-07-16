import Darwin

public struct SpeechdLaunchOptions: Equatable {
    public var modelID: String?
    /// Exact HF commit prepared by the app. Nil keeps `--model` useful for
    /// development against a custom repo that intentionally follows main.
    public var modelRevision: String?
    public var modelDirectory: String?
    public var port: UInt16 = 8471
    public var parentPID: pid_t?
    public var transcriptionDelayMs: Int?
    public var cacheLimitMB = 4096

    public init() {}
}

public enum SpeechdOptionError: Error, CustomStringConvertible, Equatable {
    case missingValue(String)
    case invalidValue(String)
    case unknownFlag(String)
    case missingModel

    public var description: String {
        switch self {
        case .missingValue(let flag): return "missing value for \(flag)"
        case .invalidValue(let flag): return "invalid value for \(flag)"
        case .unknownFlag(let flag): return "unknown flag \(flag)"
        case .missingModel: return "one of --model or --model-dir is required"
        }
    }
}

public enum SpeechdOptionParser {
    public static func parse(_ arguments: [String]) throws -> SpeechdLaunchOptions {
        var options = SpeechdLaunchOptions()
        var iterator = arguments.makeIterator()
        func value(_ flag: String) throws -> String {
            guard let value = iterator.next() else {
                throw SpeechdOptionError.missingValue(flag)
            }
            return value
        }

        while let flag = iterator.next() {
            switch flag {
            case "--model":
                options.modelID = try value(flag)
            case "--model-revision":
                options.modelRevision = try value(flag)
            case "--model-dir":
                options.modelDirectory = try value(flag)
            case "--port":
                guard let port = UInt16(try value(flag)) else {
                    throw SpeechdOptionError.invalidValue(flag)
                }
                options.port = port
            case "--parent-pid":
                guard let pid = pid_t(try value(flag)) else {
                    throw SpeechdOptionError.invalidValue(flag)
                }
                options.parentPID = pid
            case "--transcription-delay-ms":
                guard let milliseconds = Int(try value(flag)), milliseconds > 0 else {
                    throw SpeechdOptionError.invalidValue(flag)
                }
                options.transcriptionDelayMs = milliseconds
            case "--cache-limit-mb":
                guard let megabytes = Int(try value(flag)), megabytes >= 0 else {
                    throw SpeechdOptionError.invalidValue(flag)
                }
                options.cacheLimitMB = megabytes
            default:
                throw SpeechdOptionError.unknownFlag(flag)
            }
        }

        guard options.modelID != nil || options.modelDirectory != nil else {
            throw SpeechdOptionError.missingModel
        }
        return options
    }
}

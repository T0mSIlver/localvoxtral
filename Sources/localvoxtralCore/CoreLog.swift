import Foundation
#if canImport(os)
import os
#endif

/// The loggers the core writes to. On Apple platforms they are `os.Logger`s
/// with the app's subsystem and categories, so Console shows one stream;
/// on Linux, where only the core's tests run, they drop every message.
package enum CoreLog {
    #if canImport(os)
    package static let polishing = Logger(subsystem: "com.localvoxtral", category: "Polishing")
    #else
    package static let polishing = SilentLogger()
    #endif
}

#if !canImport(os)
/// Stands in for `os.Logger` where there is none: it accepts the same
/// messages, privacy annotations included, and drops them.
package struct SilentLogger: Sendable {
    package func debug(_ message: SilentLogMessage) {}
    package func info(_ message: SilentLogMessage) {}
    package func notice(_ message: SilentLogMessage) {}
    package func warning(_ message: SilentLogMessage) {}
    package func error(_ message: SilentLogMessage) {}
}

package struct SilentLogMessage: ExpressibleByStringInterpolation {
    package struct StringInterpolation: StringInterpolationProtocol {
        package init(literalCapacity: Int, interpolationCount: Int) {}
        package mutating func appendLiteral(_ literal: String) {}
        package mutating func appendInterpolation<T>(_ value: T) {}
        package mutating func appendInterpolation<T>(_ value: T, privacy: SilentLogPrivacy) {}
    }

    package init(stringLiteral value: String) {}
    package init(stringInterpolation: StringInterpolation) {}
}

package enum SilentLogPrivacy: Sendable {
    case `public`
    case `private`
}
#endif

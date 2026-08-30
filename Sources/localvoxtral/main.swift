import Foundation

/// The executable's entry point, ahead of the SwiftUI app.
///
/// `localvoxtralApp` used to carry `@main`; a diagnostic verb has to answer and
/// exit without a menu bar item, a Settings scene, or an `NSApplication` run
/// loop, and there is no way back out of `App.main()`. So the argument check
/// happens here, before anything is constructed. Without the verb this file
/// does exactly what `@main` did.
switch ClaudeSurfaceProbe.invocation(arguments: CommandLine.arguments) {
case .notRequested:
    localvoxtralApp.main()
case .run(let options):
    exit(ClaudeSurfaceProbeCommand.run(options: options))
case .usageError(let message):
    FileHandle.standardError.write(Data("\(message)\n\n\(ClaudeSurfaceProbe.usageText)\n".utf8))
    exit(2)
}

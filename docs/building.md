# Building from source

Requires a Mac with Apple Silicon, macOS 15+, and Xcode (on Xcode 26+ the
Metal compiler is a separate one-time download:
`xcodebuild -downloadComponent MetalToolchain`).

```bash
./scripts/package_app.sh release
open ./dist/localvoxtral.app
```

For development:

```bash
swift build        # app package (never compiles the MLX C++ core)
swift test         # tier-0 unit suite (500+ tests)
```

The MLX helpers in `PolishHelper/` and `SpeechHelper/` (the bundled
`localvoxtral-polishd` and `localvoxtral-speechd` engines) are separate
SwiftPM packages. `swift build` compiles a helper but cannot produce working
Metal kernels. Only the xcodebuild step inside `package_app.sh` can, so build
the app with `package_app.sh`, not `swift build`.

To work from a non-Mac machine, run the integration or eval lanes, or
contribute a change, see [CONTRIBUTING.md](../CONTRIBUTING.md) and the agent
guide ([AGENTS.md](../AGENTS.md)), which documents the remote-build workflow.
[docs/agent/test-tiers.md](agent/test-tiers.md) lists every test tier.

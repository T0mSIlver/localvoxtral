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

The MLX helpers (`PolishHelper/`, `SpeechHelper/` — the bundled
`localvoxtral-polishd` / `localvoxtral-speechd` engines) are separate SwiftPM
packages. `swift build` of a helper compiles but cannot produce working Metal
kernels — only the xcodebuild lane inside `package_app.sh` can, which is why
"build the app" is `package_app.sh` and not `swift build`.

Working from a non-Mac machine, wanting to run the integration or eval
lanes, or contributing a change? See [CONTRIBUTING.md](../CONTRIBUTING.md)
and the agent guide ([AGENTS.md](../AGENTS.md)) — the latter documents the
remote-build workflow and the full test-tier matrix.

# SpeechHelper — agent notes

This is the bundled `localvoxtral-speechd` MLX streaming-ASR helper, a
SEPARATE SwiftPM package so the root build never compiles the MLX C++ core.
Its vendored dependency pin and upgrade procedure live in `DEPENDENCY.md`.

- `swift build` here compiles but CANNOT produce working Metal kernels —
  only the xcodebuild lane in `scripts/package_app.sh` can (package aggregate
  scheme `SpeechHelper`); a swift-build binary fails at runtime loading the
  metallib. Unit tests are Metal-free:
  `./scripts/remote-build.sh test --package-path SpeechHelper`.
- On Xcode 26+ the Metal compiler is a separate ~700 MB component — one-time
  host setup is `xcodebuild -downloadComponent MetalToolchain` (the catalog
  fetch fails transiently sometimes; retry). `xcrun --find metal` succeeding
  does NOT mean the toolchain is installed; only invoking `metal` proves it.
- Engine, model-pin, packaging, or integration-contract changes here MUST run
  the speechd live-model lane once, on the final diff: the PR's CI lane runs
  it when its filter matches (or with `[run-speechd-integration]` in the
  PR), so run `./scripts/remote-build.sh integration-speechd` by hand only
  when neither applies. Triggers in `../docs/agent/test-tiers.md`.

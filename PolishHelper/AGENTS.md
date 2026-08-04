# PolishHelper — agent notes

This is the bundled `localvoxtral-polishd` MLX polishing helper, a SEPARATE
SwiftPM package so the root build never compiles the MLX C++ core.

- `swift build` here compiles but CANNOT produce working Metal kernels —
  only the xcodebuild lane in `scripts/package_app.sh` can (package aggregate
  scheme `PolishHelper`); a swift-build binary fails at runtime loading the
  metallib. Unit tests are Metal-free:
  `./scripts/remote-build.sh test --package-path PolishHelper`.
- On Xcode 26+ the Metal compiler is a separate ~700 MB component — one-time
  host setup is `xcodebuild -downloadComponent MetalToolchain` (the catalog
  fetch fails transiently sometimes; retry). `xcrun --find metal` succeeding
  does NOT mean the toolchain is installed; only invoking `metal` proves it.
- Engine, model-pin, prompt, or request-shape changes here MUST run the LLM
  lanes (`./scripts/remote-build.sh integration-polishd`, eval scoreboard in
  the PR's Proof section) — the rule and triggers are in
  `../docs/agent/test-tiers.md` ("When must the LLM lanes run?").
- Adding a model option to `PolishModelCatalog`: run
  `./scripts/remote-build.sh integration-polishd <hf-repo>` as the per-model
  gate (it self-provisions the weights).

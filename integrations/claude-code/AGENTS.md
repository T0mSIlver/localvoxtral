# Claude Code plugins — agent notes

STOP: before changing the plugins or hook shims here, read
`../../docs/agent/invariants.md` in full (trust boundaries, fail-open vs
fail-closed rules, the stdout gate) and this directory's `README.md` (wire
format, threat model, install/update semantics). The local plugin's hooks
must stay fail-open; the remote shim's stdout must stay fail-closed to the
listener's exact response grammar. These paths do not run the LLM lane, which
executes none of them (#643); a change to what a hook record carries into the
Claude blocks shows in `PolishRequestGoldenTests`.

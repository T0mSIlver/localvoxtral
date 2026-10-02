# Claude Code plugins — agent notes

STOP: before changing the plugins or hook shims here, read
`../../docs/agent/invariants.md` in full (trust boundaries, fail-open vs
fail-closed rules, the stdout gate) and this directory's `README.md` (wire
format, threat model, install/update semantics). The local plugin's hooks
must stay fail-open; the remote shim's stdout must stay fail-closed to the
listener's exact response grammar. These paths do not run the LLM lane, which
executes none of them (#643); a change to what a hook record carries into the
Claude blocks shows in `PolishRequestGoldenTests`.

`plugins/localvoxtral-mod` is a Claude Code mod (a TypeScript hooks module).
Before changing it, load the `plugin-authoring` skill for the API. Check it
with `claude plugin validate` and `claude plugin test` on its folder; both run
on Linux. A mod hook that answers a `classic.<Event>` without calling `next`
also silences the person's own settings hooks for that event (measured on
Claude Code 2.1.287, #1407), so never do it.

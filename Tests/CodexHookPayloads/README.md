# Recorded Codex hook payloads

Hook stdin exactly as Codex CLI 0.156.0 wrote it on Linux, 2026-09-26 (#716).
A probe plugin whose hooks copied stdin to a file ran in a pty-driven
interactive `codex` session, once for a plain turn (a `Bash` read, an
`apply_patch` edit), once for a turn that spawned a subagent, and once for a
patch with relative `Add File`/`Move to` paths. Files are named
`<event>[-<tool>]`, prefixed `subagent-` when the payload carries an
`agent_id`.

Record new ones the same way rather than editing these: the parser tests
exist to catch Codex changing its payload.

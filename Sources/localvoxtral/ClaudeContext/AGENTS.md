# Claude Code context path — agent notes

STOP: before changing anything here (or in `Sources/ClaudeContext*` /
`integrations/claude-code/`), read `../../../docs/agent/invariants.md` in
full. Every join arm, trust boundary, and fail-closed rule in this subtree is
deliberate, most encode measured failures, and several are security
boundaries (transport-derived trust, `LocalWorkspacePath`'s no-public-init
rule, abstain-on-ambiguity). These paths are also LLM-lane-relevant
(`scripts/ci/llm-lane-filter.sh`).

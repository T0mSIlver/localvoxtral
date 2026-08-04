# docs/

Committed documentation — tracked normally. Machine-local scratch (setup
runbooks, handoff notes, drafts) goes in the gitignored `local-notes/`
directory instead, never here.

## Using localvoxtral

- [Install](install.md) — one-line install, requirements, Gatekeeper notes
- [Dictating](dictation.md) — shortcuts, output modes, settings reference,
  screenshots
- [Terminals & coding agents](coding-agents.md) — dictating into Claude Code
  and other CLI agents, session joins, the SSH remote plugin
- [Under the hood](under-the-hood.md) — privacy, the managed local engines
  and their pinned models, bring-your-own-server
- [Roadmap](roadmap.md)

## Developing localvoxtral

- [Building from source](building.md) — plus [CONTRIBUTING.md](../CONTRIBUTING.md)
  for contribution expectations
- [Architecture](architecture.md) — the subsystem map
- [Dogfood builds](dogfood-builds.md) — the instrumented build variant: what
  it captures, how to install and identify one

## Agent-facing deep guides (`docs/agent/`)

Loaded on demand from [AGENTS.md](../AGENTS.md)'s router — humans are welcome
too:

- [Invariants & deliberate tradeoffs](agent/invariants.md) — trust
  boundaries, session-join arms, fail-closed rules. Read before touching the
  Claude Code context path.
- [Test tiers & eval lanes](agent/test-tiers.md) — the full tier matrix,
  when the LLM lanes must run, eval recordings and ablations
- [Field debugging](agent/field-debugging.md) — try-pr, crashlog dispatch,
  signing/TCC, dogfood capture

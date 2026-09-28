# Documentation

Guides for using localvoxtral, its coding-agent integrations, and working on
its code.

## Using localvoxtral

- [Install](install.md): install, update, Gatekeeper fixes, nightly builds
- [Dictating](dictation.md): shortcuts, output modes, settings reference,
  screenshots
- [Terminals & coding agents](coding-agents.md): dictating into Claude Code
  and other CLI agents, jumping to the agent that needs you, session joins,
  the SSH remote plugin
- [Integration matrix](integration-matrix.md): for each coding agent and
  terminal, what joins, what context is attached, and why the gaps exist
- [Under the hood](under-the-hood.md): privacy, the managed local engines
  and their pinned models, bring-your-own-server
- [Roadmap](roadmap.md)

## Integrations

- [Claude Code](../integrations/claude-code/README.md)
- [opencode](../integrations/opencode/README.md)
- [Mistral Vibe](../integrations/vibe/README.md)
- [Codex](../integrations/codex/README.md)
- [herdr](../integrations/herdr/README.md): dictating into a herdr pane, on
  this Mac, on an ssh host and on a federated machine
- [Remote Claude Code over SSH](remote-claude-context.md)

## Developing localvoxtral

- [Building from source](building.md), plus [CONTRIBUTING.md](../CONTRIBUTING.md)
  for contribution expectations
- [Architecture](architecture.md): the subsystem map
- [Test harness](test-harness.md): the control socket and the WAV
  microphone that debug and UI smoke builds carry, and release builds never
- [Remote Claude Code context over SSH](remote-claude-context.md): enrolling
  a host, what the token does and does not authorize, the per-Mac forward
  port, manual checks, and uninstalling

## Guides for agents that work on localvoxtral

These live in the agent folder of the docs. Agents load them on demand from
[AGENTS.md](../AGENTS.md), and people can read them too.

- [Invariants & deliberate tradeoffs](agent/invariants.md): trust
  boundaries, session-join arms, fail-closed rules. Read before touching the
  Claude Code context path.
- [Test tiers & eval lanes](agent/test-tiers.md): the full tier matrix,
  when the LLM lanes must run, eval recordings and ablations
- [Field debugging](agent/field-debugging.md): try-pr, crashlog dispatch,
  signing/TCC, diagnostic records

Machine-local scratch (setup runbooks, handoff notes, drafts) goes in the
gitignored `local-notes/` directory, never in the docs folder.

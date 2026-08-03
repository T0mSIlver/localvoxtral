# docs/

Committed, user-facing documentation. Note the unusual arrangement: `docs/*`
is **gitignored by default** — this directory doubles as local scratch space
for machine-specific notes (Mac setup, handoff notes) that must never be
committed. A doc becomes part of the repo by adding a `!/docs/<file>` line to
`.gitignore` next to the existing ones.

## Index

- [Dogfood builds](dogfood-builds.md) — the instrumented build variant: what
  it captures, how to install and identify one.

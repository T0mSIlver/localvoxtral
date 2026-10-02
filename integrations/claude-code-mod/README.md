# localvoxtral mod (prototype)

A Claude Code mod: a plugin whose hooks are TypeScript functions running
inside Claude Code, not shell commands. Mods are early access in Claude Code
(2.1.287 here), and the API may change between releases.

This prototype shows the [connection indicator](../claude-code/README.md#connection-indicator-opt-in-status-line)
as the plugin's own status line. It runs the app's publisher in
`--statusline` mode every 5 seconds with this session's id, and pins the
answer under the prompt. It needs no entry in `~/.claude/settings.json` and
leaves your own status line alone. The app does not install it yet.

Try it from a checkout:

```sh
claude --plugin-dir integrations/claude-code-mod
```

Check it on any machine:

```sh
claude plugin validate integrations/claude-code-mod
claude plugin test integrations/claude-code-mod
```

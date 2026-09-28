# Recorded Claude Desktop hook payloads

Hook stdin as Claude Code 2.1.281 wrote it when run the way Claude Desktop
runs a Code-tab session on an ssh host (2026-09-27, #834): Desktop's own CLI
binary (`~/.claude/remote/ccd-cli/2.1.281`) with Desktop's flags,
`--output-format stream-json --input-format stream-json
--permission-prompt-tool stdio`, driven over stdin. A `--settings` hook
copied stdin to a file. The permission prompt was left unanswered for 8 s,
as a user who looked away would leave it.

- `Notification-permission_prompt.json`: a `Bash` call waiting for approval.
  It fires 6 s after Desktop is asked.
- `Notification-AskUserQuestion.json`: an AskUserQuestion call. Desktop
  answers it through the same permission request, so it arrives as a
  `permission_prompt` too, 6 s after the request.
- `UserPromptSubmit.json`: the prompt that opened the turn.
- `Stop.json`: the turn's end.

The cwd and transcript paths were rewritten to a neutral repository name;
everything else is as recorded. Record new ones the same way rather than
editing these.

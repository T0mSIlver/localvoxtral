---
name: localvoxtral-doctor
description: Use when the user's localvoxtral dictation misbehaves, for example a dictation did not join this session, its text was not inserted, or speech or polish failed. Names the localvoxtral commands that check the setup and read the app's log.
---

# localvoxtral diagnostics

localvoxtral is the speech-to-text app the user dictates with, on their Mac.
A dictation "joins" a coding agent session when the app finds the session it
was spoken into and uses that session's context. Two commands report on it.
Both take `--json` and change nothing.

`localvoxtral doctor` checks the app and where the `localvoxtral` command
points, the microphone and Accessibility permissions, the speech and polish
engines, each coding agent's plugin or hooks and dictation note, each remote
host, and which session the last five dictations joined. Each check reads ok,
warning, failed or skipped, and each problem names the step that fixes it.
Exit status: 0 nothing failed, 3 the app is not running, 4 a check failed.

On a remote host, `localvoxtral doctor` first checks this host's end of the
tunnel to the Mac: the forwarded port, whether the Mac's listener accepts the
token, the installed Claude Code plugin against the version each running
session loaded, the Vibe hooks and the last hook's outcome. It then prints
the Mac's checks for this host.

`localvoxtral logs` prints the app's lines from the Mac's unified log: one
line per dictation saying which session it joined and why, and the app's
errors. `--join` keeps only the join lines, and `--since` widens the window
from the last hour (`12h`, `3d`, `2026-09-25`). It works while the app is not
running, and only on the Mac.

import type { EngineInterface, Register } from 'claude-code'

// The status-line indicator the app's publisher already draws
// (integrations/claude-code/README.md, "Connection indicator"), pinned as
// this plugin's status line instead of the settings `statusLine` command.
// A plugin status line needs no edit to ~/.claude/settings.json, combines
// with the person's own line, and shows where the settings one does not:
// Claude Desktop's Code tab.
//
// Fail-open like the command hooks: no publisher, a failed run or an empty
// answer clears the line and never throws into the session.

const REFRESH_MS = 5000
const ANSI = /\u001b\[[0-9;]*m/g

async function findPublisher(
  $: EngineInterface,
  configured: string,
): Promise<string | undefined> {
  const home = (await $.env.get('HOME')) ?? ''
  const candidates = [
    (await $.env.get('LOCALVOXTRAL_CLAUDE_HOOK_BIN')) ?? '',
    `${home}/Library/Application Support/localvoxtral/claude/publisher`,
    configured,
    '/Applications/localvoxtral.app/Contents/MacOS/localvoxtral-claude-hook',
    `${home}/Applications/localvoxtral.app/Contents/MacOS/localvoxtral-claude-hook`,
  ]
  for (const path of candidates) {
    if (path !== '' && (await $.fs.exists(path))) return path
  }
  return undefined
}

export const register: Register = (on, options) => {
  on('session.start', async ($, e, next) => {
    const started = await next(e)
    if (!e.isInteractive) return started
    const publisher = await findPublisher($, String(options.publisher_path ?? ''))
    if (publisher === undefined) return started

    const refresh = async () => {
      try {
        const sessionID = await $.session.id()
        const { exitCode, stdout } = await $.process.run([publisher, '--statusline'], {
          stdin: JSON.stringify({ session_id: sessionID }),
          env: { NO_COLOR: '1' },
          timeoutMs: 3000,
        })
        const line = stdout.replace(ANSI, '').trim()
        $.ui.status(exitCode === 0 && line !== '' ? line : undefined)
      } catch {
        $.ui.status(undefined)
      }
    }
    await refresh()
    $.clock.every(REFRESH_MS, refresh)
    return started
  })
}

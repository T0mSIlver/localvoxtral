import type { EngineInterface, Register } from 'claude-code'

// The connection indicator the publisher draws for the settings status line
// (../../../README.md, "Connection indicator"), pinned as this plugin's own
// status line: no edit to ~/.claude/settings.json, and the person's own
// status line stays theirs.
//
// Fail-open like the command hooks: no publisher, a failed run or an empty
// answer clears the line and never throws into the session.

const REFRESH_MS = 5000
const ANSI = /\u001b\[[0-9;]*m/g
// The two commands the app's Status line row writes: the publisher itself,
// or the script that combines it with the person's own line.
const SETTINGS_INDICATOR = /localvoxtral-claude-hook|localvoxtral-statusline\.sh/

async function findPublisher($: EngineInterface, configured: string): Promise<string | undefined> {
  const home = (await $.env.get('HOME')) ?? ''
  // The shim's order (../../localvoxtral/hooks/publish.sh), so both find
  // the same binary.
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

async function settingsShowIndicator($: EngineInterface): Promise<boolean> {
  const { statusLine } = await $.settings.read()
  const command =
    typeof statusLine === 'object' && statusLine !== null
      ? (statusLine as { command?: unknown }).command
      : undefined
  return typeof command === 'string' && SETTINGS_INDICATOR.test(command)
}

export const register: Register = (on, options) => {
  on('session.start', async ($, e, next) => {
    const started = await next(e)
    if (!e.isInteractive || (await settingsShowIndicator($))) return started
    const publisher = await findPublisher($, String(options.publisher_path ?? ''))
    if (publisher === undefined) return started

    const refresh = async () => {
      try {
        const { exitCode, stdout } = await $.process.run([publisher, '--statusline'], {
          stdin: JSON.stringify({ session_id: await $.session.id() }),
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

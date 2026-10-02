import type { EngineInterface, Register } from 'claude-code'

import {
  type ChannelMessage,
  type ChannelReply,
  type Outcome,
  parseMessage,
  RESTART_DELAY_MS,
  SHORTEST_LIFE_MS,
  WIRE_VERSION,
} from './channel'

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

/**
 * Keeps `--attach` running for the session's life and answers each message
 * with what `handle` did.
 * Never throws into the session.
 */
async function runChannel(
  $: EngineInterface,
  publisher: string,
): Promise<void> {
  const sessionID = await $.session.id()
  for (;;) {
    const startedAt = await $.clock.now()
    try {
      let buffered = ''
      const child = $.process.spawn({ argv: [publisher, '--attach', '--session', sessionID] })
      for await (const { stream, text } of child) {
        if (stream !== 'stdout') continue
        buffered += text
        let newline = buffered.indexOf('\n')
        while (newline >= 0) {
          const message = parseMessage(buffered.slice(0, newline))
          buffered = buffered.slice(newline + 1)
          if (message !== null) void answer($, publisher, sessionID, message)
          newline = buffered.indexOf('\n')
        }
      }
    } catch {
      // The child could not start; the restart below decides what is next.
    }
    if ((await $.clock.now()) - startedAt < SHORTEST_LIFE_MS) return
    await $.clock.sleep(RESTART_DELAY_MS)
  }
}

async function answer(
  $: EngineInterface,
  publisher: string,
  sessionID: string,
  message: ChannelMessage,
): Promise<void> {
  let outcome: Outcome
  try {
    outcome = await handle($, message)
  } catch {
    outcome = { ok: false, reason: 'failed' }
  }
  const reply: ChannelReply = { mod_reply: WIRE_VERSION, session_id: sessionID, id: message.id, ...outcome }
  try {
    await $.process.run([publisher, '--mod-reply'], { stdin: `${JSON.stringify(reply)}\n`, timeoutMs: 3000 })
  } catch {
    // The app waits out its own timeout.
  }
}

/** Does what one message asks. A kind this build does not know is not done. */
async function handle($: EngineInterface, message: ChannelMessage): Promise<Outcome> {
  switch (message.kind) {
    case 'ping':
      return { ok: true }
    case 'fill': {
      // At the cursor, as typing would put it (#1409). The app gives the
      // text back to the keyboard on anything but ok.
      if (message.text === undefined || message.text === '') return { ok: false, reason: 'no_text' }
      const filled = await $.prompt.fill({ text: message.text, mode: 'insert' })
      return filled.isFilled ? { ok: true } : { ok: false, reason: filled.refusal ?? 'refused' }
    }
    case 'terms': {
      // The project's names, from what this session already holds (#1410):
      // its own transcript, served from the prompt cache, no tool.
      if (message.text === undefined || message.text === '') return { ok: false, reason: 'no_text' }
      const forked = await $.model.fork({ prompt: message.text })
      if (!forked.isAnswered) return { ok: false, reason: forked.reason }
      const { input_tokens, cache_creation_input_tokens, cache_read_input_tokens, output_tokens } = forked.usage
      return {
        ok: true,
        text: forked.text,
        usage: { input_tokens, cache_creation_input_tokens, cache_read_input_tokens, output_tokens },
      }
    }
    default:
      return { ok: false, reason: 'unknown_kind' }
  }
}

// Not gated on `isInteractive`, which is false for an SDK host and may be
// for a Claude Desktop session, where the indicator and the channel matter
// most.
export const register: Register = (on, options) => {
  on('session.start', async ($, e, next) => {
    const started = await next(e)
    const publisher = await findPublisher($, String(options.publisher_path ?? ''))
    if (publisher === undefined) return started
    // A module reload or the session's end can cut the loop mid-call.
    runChannel($, publisher).catch(() => {})
    if (await settingsShowIndicator($)) return started

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

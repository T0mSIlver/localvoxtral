import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { Band } from '../types'
import {
  BAND_STALE_MS,
  bandOf,
  type ChannelBye,
  type ChannelMessage,
  draftOf,
  insertedAt,
  needsKeys,
  type ChannelReply,
  NEW_SESSION_POLL_MS,
  NEW_SESSION_WAIT_MS,
  type Outcome,
  parseMessage,
  waitingLine,
  RESTART_DELAY_MS,
  SESSION_CHANGED,
  SHORTEST_LIFE_MS,
  SUBMIT_ANSWER_MS,
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

// The session the mod said `bye` for, and whether the process ends with it
// (any end but `/clear`). Module state: `session.end` sets it, the channel
// loop reads it.
let endingSession: string | undefined
let processEnds = false
// Resolves when `session.end` cuts the channel of a `/clear`, so the read
// loop stops waiting on a child the app may never close.
let cutChannel: () => void = () => {}

/**
 * Keeps `--attach` running for the session's life and answers each message
 * with what `handle` did. After the app's `bye`, attaches again under the
 * session id a `/clear` moved the process to (#1646).
 * Never throws into the session.
 */
async function runChannel(
  $: EngineInterface,
  publisher: string,
): Promise<void> {
  let sessionID = await $.session.id()
  for (;;) {
    const startedAt = await $.clock.now()
    let saidBye = false
    try {
      let buffered = ''
      const child = $.process.spawn({ argv: [publisher, '--attach', '--session', sessionID] })
      const cut = new Promise<'cut'>((resolve) => {
        cutChannel = () => resolve('cut')
      })
      read: for (;;) {
        const piece = await Promise.race([child.next(), cut])
        if (piece === 'cut') {
          // Ends the child; not awaited, since a pull may still be pending.
          void child.return(undefined as never).catch(() => {})
          break
        }
        if (piece.done === true) break
        const { stream, text } = piece.value
        if (stream !== 'stdout') continue
        buffered += text
        let newline = buffered.indexOf('\n')
        while (newline >= 0) {
          const message = parseMessage(buffered.slice(0, newline))
          buffered = buffered.slice(newline + 1)
          if (message?.kind === 'bye') {
            // The app ended this session's channel; leaving the loop ends
            // the child.
            saidBye = true
            void child.return(undefined as never).catch(() => {})
            break read
          }
          if (message?.kind === 'state' && message.waiting !== undefined) void update($, waiting, () => message.waiting ?? [])
          else if (message?.kind === 'state') void showBand($, message)
          else if (message !== null) void answer($, publisher, sessionID, message)
          newline = buffered.indexOf('\n')
        }
      }
    } catch {
      // The child could not start; the restart below decides what is next.
    }
    // Nobody tells this mod who waits until it attaches again.
    await update($, waiting, () => [])
    if (saidBye || endingSession === sessionID) {
      if (processEnds) return
      const next = await newSessionID($, sessionID)
      if (next === undefined) return
      sessionID = next
      continue
    }
    if ((await $.clock.now()) - startedAt < SHORTEST_LIFE_MS) return
    await $.clock.sleep(RESTART_DELAY_MS)
  }
}

/** The id the process went on under after `ended`, or undefined in time. */
async function newSessionID($: EngineInterface, ended: string): Promise<string | undefined> {
  for (let waited = 0; waited <= NEW_SESSION_WAIT_MS; waited += NEW_SESSION_POLL_MS) {
    const id = await $.session.id()
    if (id !== ended) return id
    await $.clock.sleep(NEW_SESSION_POLL_MS)
  }
  return undefined
}

/**
 * Tells the app the session ends (#1646), so it drops the session when the
 * channel closes instead of waiting out a TTL. Inside `session.end`'s short
 * budget; a failure leaves the app the session's own SessionEnd hook.
 */
async function sayBye($: EngineInterface, publisher: string, sessionID: string): Promise<void> {
  const bye: ChannelBye = { mod_bye: WIRE_VERSION, session_id: sessionID }
  try {
    await $.process.run([publisher, '--mod-reply'], { stdin: `${JSON.stringify(bye)}\n`, timeoutMs: 1000 })
  } catch {
    // The app keeps the session until its SessionEnd hook or TTL.
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
    // A /clear or a resume moves the process to another session before
    // `session.end` cuts this attach. A request issued for this session
    // must not act on that one's prompt box or transcript.
    outcome =
      message.kind !== 'ping' && (await $.session.id()) !== sessionID
        ? { ok: false, reason: SESSION_CHANGED }
        : await handle($, message)
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

const band = atom({ plugin: 'localvoxtral-mod', key: 'band' } as const, null)
// The other sessions waiting for the person, oldest first (#1695).
const waiting = atom({ plugin: 'localvoxtral-mod', key: 'waiting' } as const, [])
let bandUpdatedAt = 0

/** Shows what a `state` message says; the app waits for no answer. */
async function showBand($: EngineInterface, message: ChannelMessage): Promise<void> {
  const next: Band = bandOf(message)
  const at = await $.clock.now()
  bandUpdatedAt = at
  await update($, band, () => next)
  if (next !== null) {
    $.clock.after(BAND_STALE_MS, async () => {
      if (bandUpdatedAt === at) await update($, band, () => null)
    })
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
    case 'send':
      if (message.text === undefined || message.text === '') return { ok: false, reason: 'no_text' }
      return send($, message.text)
    case 'draft':
      // What the person already typed, for polish and the space before the
      // fill (#1406). Read where the dictation will land, at the stop.
      return { ok: true, ...draftOf(await $.prompt.read()) }
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

// The main loop's running turn, from `turn.start` to its `turn.complete`:
// a plugin's submit waits for it.
let runningTurn: string | undefined

/**
 * A spoken send (#1644): the text goes in at the cursor, then the box's
 * whole text is submitted as the person's own and the box emptied, so
 * nothing is sent twice or left behind. Answers `queued` when the submit
 * waits for a running turn; a submit refused later puts the text back.
 */
async function send($: EngineInterface, text: string): Promise<Outcome> {
  const reason = needsKeys(insertedAt(await $.prompt.read(), text))
  if (reason !== undefined) return { ok: false, reason }
  const filled = await $.prompt.fill({ text, mode: 'insert' })
  if (!filled.isFilled) return { ok: false, reason: filled.refusal ?? 'refused' }
  const whole = filled.text
  const emptied = await $.prompt.fill({ text: '', mode: 'replace' })
  if (!emptied.isFilled) return { ok: true, submitted: false, reason: emptied.refusal ?? 'refused' }

  const busy = runningTurn !== undefined
  const submitted = $.prompt.submit({ text: whole, asUser: true }).then(
    async (result) => {
      if (result.drop === undefined) return 'sent' as const
      await putBack($, whole)
      return 'dropped' as const
    },
    async () => {
      await putBack($, whole)
      return 'dropped' as const
    },
  )
  if (busy) return { ok: true, submitted: true, queued: true }
  const first = await Promise.race([submitted, $.clock.sleep(SUBMIT_ANSWER_MS).then(() => 'waiting' as const)])
  if (first === 'dropped') return { ok: true, submitted: false, reason: 'dropped' }
  return first === 'sent' ? { ok: true, submitted: true } : { ok: true, submitted: true, queued: true }
}

/**
 * A submit that did not go: its text back in the box, after anything typed
 * since, so neither is cut into the other.
 */
async function putBack($: EngineInterface, text: string): Promise<void> {
  try {
    const box = await $.prompt.read()
    await $.prompt.fill({ text: box.text === '' ? text : ` ${text}`, mode: 'append' })
  } catch {
    // The engine shows the drop's reason; nothing else to do.
  }
}

// The publisher the channel runs, once `session.start` found one.
let channelPublisher: string | undefined

// Not gated on `isInteractive`, which is false for an SDK host and may be
// for a Claude Desktop session, where the indicator and the channel matter
// most.
export const register: Register = (on, options) => {
  on('turn.start', async ($, e, next) => {
    runningTurn = e.turnId
    return next(e)
  })

  on('turn.complete', async ($, e, next) => {
    if (e.agentId === undefined && e.turnId === runningTurn) runningTurn = undefined
    return next(e)
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (e.props.hasSurvey) return next(e)
    const shown = await read($, band)
    const columns = e.props.bodyColumns ?? 80
    const others = waitingLine(await read($, waiting), columns)
    if (shown === null && others === null) return next(e)
    const { Box, Text } = $.ui.resolve(e)
    // Two lines at most: the tail of the words, as wide as the box.
    const room = Math.max(20, columns * 2 - 16)
    const words = shown === null ? '' : shown.text.length > room ? `…${shown.text.slice(-(room - 1))}` : shown.text
    return (
      <Box flexDirection="column">
        {shown !== null && (
          <Box>
            <Text color="red">● </Text>
            <Text bold>{shown.phase === 'listening' ? 'Listening' : 'Finishing'} </Text>
            <Text dimColor>{words}</Text>
          </Box>
        )}
        {others !== null && <Text color="yellow">{others}</Text>}
      </Box>
    )
  })

  on('session.end', async ($, e, next) => {
    // A turn the end cut short raises no `turn.complete` the mod sees.
    runningTurn = undefined
    if (channelPublisher !== undefined) {
      endingSession = e.sessionId
      processEnds = e.reason !== 'clear'
      await sayBye($, channelPublisher, e.sessionId)
      // Without the app's answer (an app that is down or predates the bye)
      // the child would go on attaching as the cleared session: end it, so
      // the channel moves to the new id.
      if (!processEnds) cutChannel()
    }
    return next(e)
  })

  on('session.start', async ($, e, next) => {
    const started = await next(e)
    const publisher = await findPublisher($, String(options.publisher_path ?? ''))
    if (publisher === undefined) return started
    channelPublisher = publisher
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

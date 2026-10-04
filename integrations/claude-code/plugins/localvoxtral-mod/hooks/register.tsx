import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { Band, InboxView } from '../types'
import {
  AppendStream,
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
  NO_TURN,
  type Outcome,
  parseMessage,
  waitingLine,
  RESTART_DELAY_MS,
  SESSION_CHANGED,
  SHORTEST_LIFE_MS,
  SUBMIT_ANSWER_MS,
  WIRE_VERSION,
} from './channel'
import { detailOf, INBOX_PANE, inboxOf } from './inbox'

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

/** The `localvoxtral` command: the app's own copy beside the publisher first. */
async function findCLI($: EngineInterface, configuredPublisher: string): Promise<string | undefined> {
  const home = (await $.env.get('HOME')) ?? ''
  const bundled = 'localvoxtral.app/Contents/MacOS/localvoxtral-cli'
  const candidates = [
    (await $.env.get('LOCALVOXTRAL_CLI_BIN')) ?? '',
    configuredPublisher.endsWith('/localvoxtral-claude-hook')
      ? configuredPublisher.replace(/localvoxtral-claude-hook$/, 'localvoxtral-cli')
      : '',
    `/Applications/${bundled}`,
    `${home}/Applications/${bundled}`,
    '/usr/local/bin/localvoxtral',
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
          else if (message?.kind === 'append') queueAppend($, sessionID, message)
          // After every append written before it, so its count is final.
          else if (message?.kind === 'ack') appends = appends.then(() => answer($, publisher, sessionID, message))
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

// Live Auto-Paste's deltas (#1645), filled one after another in the order
// they arrived: a fill awaits the engine, and two in flight could land
// swapped.
const stream = new AppendStream()
let appends: Promise<void> = Promise.resolve()

/** Queues one `append`; it is not answered, the stop's `ack` counts it. */
function queueAppend($: EngineInterface, sessionID: string, message: ChannelMessage): void {
  appends = appends.then(async () => {
    if (!stream.admits(message.seq)) return
    let isFilled = false
    try {
      // A delta meant for the session the process left goes nowhere.
      if (message.text !== undefined && message.text !== '' && (await $.session.id()) === sessionID) {
        isFilled = (await $.prompt.fill({ text: message.text, mode: 'insert' })).isFilled
      }
    } catch {
      // Counted as not filled: the app types or keeps it and what follows.
    }
    stream.settle(isFilled)
  })
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
      // An empty text submits the box as the appends left it (#1645).
      if (message.text === undefined) return { ok: false, reason: 'no_text' }
      return send($, message.text)
    case 'ack':
      return { ok: true, seq: stream.ack() }
    case 'abort': {
      // A spoken stop phrase (#1696): ends the main loop's running turn, as
      // Escape would, with no key. Nothing running is not an error the
      // person needs a key for.
      const turnId = runningTurn
      if (turnId === undefined) return { ok: false, reason: NO_TURN }
      await $.turn.abort({ turnId })
      return { ok: true }
    }
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
 * An empty text submits the box as it stands (#1645).
 */
async function send($: EngineInterface, text: string): Promise<Outcome> {
  const box = await $.prompt.read()
  if (text === '' && box.text.trim() === '') return { ok: false, reason: 'no_text' }
  const reason = needsKeys(insertedAt(box, text))
  if (reason !== undefined) return { ok: false, reason }
  let whole = box.text
  if (text !== '') {
    const filled = await $.prompt.fill({ text, mode: 'insert' })
    if (!filled.isFilled) return { ok: false, reason: filled.refusal ?? 'refused' }
    whole = filled.text
  }
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
const inbox = atom({ plugin: 'localvoxtral-mod', key: 'inbox' } as const, { status: 'loading' })

/**
 * Reads this project's captures into the Inbox pane. Their words stay in the
 * pane: none reaches the session's prompt or its model.
 */
async function loadInbox($: EngineInterface, cli: string | undefined): Promise<void> {
  let view: InboxView
  if (cli === undefined) {
    view = { status: 'failed', reason: 'The localvoxtral command is not installed here.' }
  } else {
    try {
      const run = await $.process.run([cli, 'capture', 'list', '--project', await $.session.cwd(), '--json'], {
        timeoutMs: 5000,
      })
      view = inboxOf(run, await $.clock.now())
    } catch {
      view = { status: 'failed', reason: 'localvoxtral could not list the Inbox.' }
    }
  }
  await update($, inbox, () => view)
}

/** Brings the app's Inbox forward on the capture; filing happens there. */
async function openCapture($: EngineInterface, cli: string | undefined, id: string): Promise<void> {
  try {
    if (cli !== undefined) {
      const { exitCode } = await $.process.run([cli, 'capture', 'open', id, '--json'], { timeoutMs: 5000 })
      if (exitCode === 0) return
    }
  } catch {
    // Said below.
  }
  $.ui.toast('localvoxtral could not open that capture.')
}

export const register: Register = (on, options) => {
  on('command.run', { command: 'inbox' }, async $ => {
    await update($, inbox, () => ({ status: 'loading' }) as const)
    await $.ui.open({ id: INBOX_PANE, title: 'Inbox' })
    await loadInbox($, await findCLI($, String(options.publisher_path ?? '')))
    return { text: 'Opened the Inbox pane.' }
  })

  on('ui.render', { component: 'Pane', requestId: INBOX_PANE }, async ($, e) => {
    const { Box, Button, Text } = $.ui.resolve(e)
    const view = await read($, inbox)
    if (view.status === 'loading') return <Text dimColor>Reading the Inbox…</Text>
    if (view.status === 'failed') return <Text dimColor>{view.reason}</Text>
    if (view.captures.length === 0) return <Text dimColor>No captures for this project.</Text>
    const cli = await findCLI($, String(options.publisher_path ?? ''))
    return (
      <Box flexDirection="column">
        {view.captures.map(capture => (
          <Box key={capture.id} flexDirection="column" marginBottom={1}>
            <Text>{capture.title}</Text>
            <Box>
              <Text dimColor>{detailOf(capture, view.at)} </Text>
              <Button
                key={`open-${capture.id}`}
                label="Open in localvoxtral"
                dimColor
                onPress={() => openCapture($, cli, capture.id)}
              />
            </Box>
          </Box>
        ))}
      </Box>
    )
  })

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
    try {
      await $.command.register({ name: 'inbox', description: "Show this project's localvoxtral captures" })
    } catch {
      // A host with no slash commands still gets the indicator and the channel.
    }
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

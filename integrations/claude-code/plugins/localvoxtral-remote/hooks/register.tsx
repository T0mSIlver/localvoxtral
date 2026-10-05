import { atom, read, update } from 'claude-code'
import type { EngineInterface, HttpResponse, Register } from 'claude-code'

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
import { sameHex } from './hmac'
import { detailOf, INBOX_PANE, inboxOf } from './inbox'
import {
  answerProof,
  BACKOFF_MS,
  BUSY_RETRY_MS,
  hookOKAt,
  isChannelKey,
  isToken,
  ASK_ABANDON_MS,
  INBOX_OPEN_PATH,
  INBOX_PATH,
  type InboxRequest,
  parsePollAnswer,
  POLL_ABANDON_MS,
  POLL_PATH,
  type PollRequest,
  PROOF_HEADER,
  randomHex,
  remotePort,
  REPLY_PATH,
  requestProof,
  STAMP_CHECK_MS,
} from './remote'

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

/**
 * How replies and byes reach the app: the publisher's `--mod-reply` on the
 * Mac, or the listener through a remote host's forward (#1412).
 */
type Link =
  | { kind: 'publisher'; publisher: string }
  | { kind: 'remote'; port: number; token: string; key: string }
type RemoteLink = Extract<Link, { kind: 'remote' }>

/**
 * The remote link the options describe: only the remote plugin's copy of
 * this module has a `token` field, and it attaches only with a token and a
 * channel key.
 */
function remoteLinkOf(options: Record<string, unknown>): RemoteLink | undefined {
  const { token, channel_key: key, port } = options
  if (!isToken(token) || !isChannelKey(key)) return undefined
  return { kind: 'remote', port: remotePort(port), token, key }
}

function remoteHeaders(link: RemoteLink, body: string): Record<string, string> {
  return {
    Authorization: `Bearer ${link.token}`,
    'Content-Type': 'application/json',
    [PROOF_HEADER]: requestProof(link.key, body),
  }
}

/** Hands one reply or bye line to the app, within `timeoutMs`. */
async function sendToApp($: EngineInterface, link: Link, line: string, timeoutMs: number): Promise<void> {
  if (link.kind === 'publisher') {
    await $.process.run([link.publisher, '--mod-reply'], { stdin: `${line}\n`, timeoutMs })
    return
  }
  const sent = $.http.fetch(`http://127.0.0.1:${link.port}${REPLY_PATH}`, {
    method: 'POST',
    headers: remoteHeaders(link, line),
    body: line,
  })
  sent.catch(() => {})
  await Promise.race([sent, $.clock.sleep(timeoutMs)])
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
async function runPublisherChannel(
  $: EngineInterface,
  link: Extract<Link, { kind: 'publisher' }>,
): Promise<void> {
  const { publisher } = link
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
          if (message !== null && dispatch($, link, sessionID, message) === 'bye') {
            // The app ended this session's channel; leaving the loop ends
            // the child.
            saidBye = true
            void child.return(undefined as never).catch(() => {})
            break read
          }
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

/** Acts on one message from the app; says when it is the app's `bye`. */
function dispatch($: EngineInterface, link: Link, sessionID: string, message: ChannelMessage): 'bye' | undefined {
  if (message.kind === 'bye') return 'bye'
  if (message.kind === 'state' && message.waiting !== undefined) void update($, waiting, () => message.waiting ?? [])
  else if (message.kind === 'state') void showBand($, message)
  else if (message.kind === 'append') queueAppend($, sessionID, message)
  // After every append written before it, so its count is final.
  else if (message.kind === 'ack') appends = appends.then(() => answer($, link, sessionID, message))
  else void answer($, link, sessionID, message)
  return undefined
}

/**
 * The channel from a remote host (#1412): long polls on the app's listener
 * through the forward, each answer's lines handled as the publisher's are.
 * A dial that fails, or an answer without the channel key's proof, waits
 * out `BACKOFF_MS` unless a hook reaches the app sooner. Never throws into
 * the session.
 */
async function runRemoteChannel($: EngineInterface, link: RemoteLink): Promise<void> {
  let sessionID = await $.session.id()
  const instance = randomHex(16)
  let attach: number | undefined
  let acked = 0
  let challenge = ''
  let failedAt: number | undefined
  for (;;) {
    if (failedAt !== undefined) {
      await backOff($, failedAt)
      failedAt = undefined
    }
    let saidBye = endingSession === sessionID
    if (!saidBye) {
      const nonce = randomHex(16)
      const request: PollRequest = {
        mod_poll: WIRE_VERSION,
        session_id: sessionID,
        instance,
        nonce,
        challenge,
        attach: attach ?? 0,
        acked,
      }
      const body = JSON.stringify(request)
      // Good once: a failure below starts over without one.
      challenge = ''
      const cut = new Promise<'cut'>((resolve) => {
        cutChannel = () => resolve('cut')
      })
      let answered: HttpResponse | 'late' | 'cut'
      try {
        const polled = $.http.fetch(`http://127.0.0.1:${link.port}${POLL_PATH}`, {
          method: 'POST',
          headers: remoteHeaders(link, body),
          body,
        })
        polled.catch(() => {})
        answered = await Promise.race([polled, $.clock.sleep(POLL_ABANDON_MS).then(() => 'late' as const), cut])
      } catch {
        answered = 'late'
      }
      if (answered === 'late') {
        // Nobody tells this mod who waits until it attaches again.
        await update($, waiting, () => [])
        failedAt = await $.clock.now()
        continue
      }
      if (answered !== 'cut') {
        // An app without the route: nothing to attach to this session.
        if (answered.status === 404) {
          await update($, waiting, () => [])
          return
        }
        // Another process of this session holds the channel, or no hook
        // has named the session yet.
        if (answered.status === 409 || answered.status === 503) {
          await $.clock.sleep(BUSY_RETRY_MS)
          continue
        }
        const proof = answered.headers[PROOF_HEADER.toLowerCase()] ?? ''
        const poll = answered.status === 200 ? parsePollAnswer(answered.text) : null
        if (poll === null || !sameHex(proof, answerProof(link.key, nonce, answered.text))) {
          await update($, waiting, () => [])
          failedAt = await $.clock.now()
          continue
        }
        challenge = poll.next
        if (poll.attach !== attach) {
          // A new attach numbers its lines from 1.
          attach = poll.attach
          acked = 0
        }
        poll.lines.forEach((line, index) => {
          const seq = poll.first + index
          if (seq <= acked || saidBye) return
          acked = seq
          const message = parseMessage(line)
          if (message !== null && dispatch($, link, sessionID, message) === 'bye') saidBye = true
        })
      }
      saidBye ||= endingSession === sessionID
    }
    if (!saidBye) continue
    // Nobody tells this mod who waits until it attaches again.
    await update($, waiting, () => [])
    if (processEnds) return
    const next = await newSessionID($, sessionID)
    if (next === undefined) return
    sessionID = next
    attach = undefined
    acked = 0
  }
}

/** Waits out a failed dial, or until post.sh records a hook that reached the app. */
async function backOff($: EngineInterface, failedAt: number): Promise<void> {
  const runtime = await $.env.get('XDG_RUNTIME_DIR')
  const home = await $.env.get('HOME')
  const stamp =
    runtime !== undefined && runtime !== ''
      ? `${runtime}/localvoxtral/hook-status`
      : home !== undefined && home !== ''
        ? `${home}/.cache/localvoxtral/hook-status`
        : undefined
  for (;;) {
    if ((await $.clock.now()) - failedAt >= BACKOFF_MS) return
    if (stamp !== undefined) {
      try {
        const okAt = hookOKAt(await $.fs.read(stamp))
        // The stamp counts seconds: an ok in the failure's second counts.
        if (okAt !== undefined && okAt + 1000 > failedAt) return
      } catch {
        // No stamp yet.
      }
    }
    await $.clock.sleep(STAMP_CHECK_MS)
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
async function sayBye($: EngineInterface, link: Link, sessionID: string): Promise<void> {
  const bye: ChannelBye = { mod_bye: WIRE_VERSION, session_id: sessionID }
  try {
    await sendToApp($, link, JSON.stringify(bye), 1000)
  } catch {
    // The app keeps the session until its SessionEnd hook or TTL.
  }
}

async function answer(
  $: EngineInterface,
  link: Link,
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
    await sendToApp($, link, JSON.stringify(reply), 3000)
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

const band = atom({ plugin: 'localvoxtral-remote', key: 'band' } as const, null)
// The other sessions waiting for the person, oldest first (#1695).
const waiting = atom({ plugin: 'localvoxtral-remote', key: 'waiting' } as const, [])
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

// How the channel reaches the app, once `session.start` found a way.
let channelLink: Link | undefined

// Not gated on `isInteractive`, which is false for an SDK host and may be
// for a Claude Desktop session, where the indicator and the channel matter
// most.
const inbox = atom({ plugin: 'localvoxtral-remote', key: 'inbox' } as const, { status: 'loading' })

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

/**
 * One Inbox ask through a remote host's forward (#1412), signed like a poll:
 * the status and body of an answer that carries the key's proof, `old` for
 * an app without the route, or undefined.
 */
async function askApp(
  $: EngineInterface,
  link: RemoteLink,
  path: string,
  id?: string,
): Promise<{ status: number; text: string } | 'old' | undefined> {
  try {
    const nonce = randomHex(16)
    const request: InboxRequest = { mod_inbox: WIRE_VERSION, session_id: await $.session.id(), nonce }
    if (id !== undefined) request.id = id
    const body = JSON.stringify(request)
    const asked = $.http.fetch(`http://127.0.0.1:${link.port}${path}`, {
      method: 'POST',
      headers: remoteHeaders(link, body),
      body,
    })
    asked.catch(() => {})
    const answered = await Promise.race([asked, $.clock.sleep(ASK_ABANDON_MS).then(() => undefined)])
    if (answered === undefined) return undefined
    const proof = answered.headers[PROOF_HEADER.toLowerCase()] ?? ''
    if (sameHex(proof, answerProof(link.key, nonce, answered.text))) return { status: answered.status, text: answered.text }
    // Unsigned, so it says nothing the pane acts on beyond this line.
    return answered.status === 404 ? 'old' : undefined
  } catch {
    return undefined
  }
}

/**
 * Reads this session's project's captures from the app through the forward:
 * ids, titles, kinds, states and dates; their words stay on the Mac.
 */
async function loadRemoteInbox($: EngineInterface, link: RemoteLink): Promise<void> {
  const result = await askApp($, link, INBOX_PATH)
  let view: InboxView
  if (result === 'old') view = { status: 'failed', reason: 'Update localvoxtral on your Mac to see its Inbox here.' }
  else if (result?.status === 200) view = inboxOf({ exitCode: 0, stdout: result.text }, await $.clock.now())
  else if (result?.status === 409) view = { status: 'failed', reason: 'localvoxtral has not seen this session yet.' }
  else view = { status: 'failed', reason: 'localvoxtral could not list the Inbox.' }
  await update($, inbox, () => view)
}

/** Brings the app's Inbox forward on the capture; filing happens there. */
async function openCapture($: EngineInterface, cli: string | undefined, id: string): Promise<void> {
  try {
    if (channelLink?.kind === 'remote') {
      const result = await askApp($, channelLink, INBOX_OPEN_PATH, id)
      if (typeof result === 'object' && result.status === 200) return
    } else if (cli !== undefined) {
      const { exitCode } = await $.process.run([cli, 'capture', 'open', id, '--json'], { timeoutMs: 5000 })
      if (exitCode === 0) return
    }
  } catch {
    // Said below.
  }
  $.ui.toast('localvoxtral could not open that capture.')
}

async function registerInbox($: EngineInterface): Promise<void> {
  try {
    await $.command.register({ name: 'inbox', description: "Show this project's localvoxtral captures" })
  } catch {
    // A host with no slash commands still gets the indicator and the channel.
  }
}

export const register: Register = (on, options) => {
  on('command.run', { command: 'inbox' }, async $ => {
    await update($, inbox, () => ({ status: 'loading' }) as const)
    await $.ui.open({ id: INBOX_PANE, title: 'Inbox' })
    if (channelLink?.kind === 'remote') await loadRemoteInbox($, channelLink)
    else await loadInbox($, await findCLI($, String(options.publisher_path ?? '')))
    return { text: 'Opened the Inbox pane.' }
  })

  on('ui.render', { component: 'Pane', requestId: INBOX_PANE }, async ($, e) => {
    const { Box, Button, Text } = $.ui.resolve(e)
    const view = await read($, inbox)
    if (view.status === 'loading') return <Text dimColor>Reading the Inbox…</Text>
    if (view.status === 'failed') return <Text dimColor>{view.reason}</Text>
    if (view.captures.length === 0) return <Text dimColor>No captures for this project.</Text>
    const cli = channelLink?.kind === 'remote' ? undefined : await findCLI($, String(options.publisher_path ?? ''))
    return (
      <Box flexDirection="column">
        {view.captures.map(capture => (
          <Box key={capture.id} flexDirection="column" marginBottom={1}>
            <Text>{capture.title === '' ? 'Untitled capture' : capture.title}</Text>
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
    if (channelLink !== undefined) {
      endingSession = e.sessionId
      processEnds = e.reason !== 'clear'
      await sayBye($, channelLink, e.sessionId)
      // Without the app's answer (an app that is down or predates the bye)
      // the child would go on attaching as the cleared session: end it, so
      // the channel moves to the new id.
      if (!processEnds) cutChannel()
    }
    return next(e)
  })

  on('session.start', async ($, e, next) => {
    const started = await next(e)
    if ('token' in options) {
      // The remote plugin's copy (#1412): the channel and the Inbox over the
      // forward, and no indicator, which needs the app's binaries on this
      // machine.
      const remote = remoteLinkOf(options)
      if (remote === undefined) return started
      channelLink = remote
      await registerInbox($)
      runRemoteChannel($, remote).catch(() => {})
      return started
    }
    await registerInbox($)
    const publisher = await findPublisher($, String(options.publisher_path ?? ''))
    if (publisher === undefined) return started
    const link = { kind: 'publisher', publisher } as const
    channelLink = link
    // A module reload or the session's end can cut the loop mid-call.
    runPublisherChannel($, link).catch(() => {})
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

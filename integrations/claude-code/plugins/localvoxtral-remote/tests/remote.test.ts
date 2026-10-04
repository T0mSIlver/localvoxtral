import type { HttpInit, HttpResponse, RenderPropsOf } from 'claude-code'
import { describe, expect, mock, test } from 'claude-code/testing'

import { hmacHex } from '../hooks/hmac'
import { answerProof, BACKOFF_MS, requestProof } from '../hooks/remote'

// The remote plugin's copy of the mod's hooks module (#1412), driven through
// the long poll as a host runs it. The handlers it shares with the Mac copy
// are tested in localvoxtral-mod; these cover the transport.

const TOKEN = 'tok_0123456789abcdefXYZ'
const KEY = 'a'.repeat(64)
const OPTIONS = { token: TOKEN, port: '29891', channel_key: KEY }
const STARTED = { surface: 'terminal', isInteractive: true, cwd: '/work' } as const
const POLL = 'http://127.0.0.1:29891/v1/mod/poll'
const REPLY = 'http://127.0.0.1:29891/v1/mod/reply'
const INBOX = 'http://127.0.0.1:29891/v1/mod/inbox'
const INBOX_OPEN = 'http://127.0.0.1:29891/v1/mod/inbox/open'
const NOW = Date.parse('2026-10-04T12:00:00Z')
const CAPTURE = '3f9c2a1b-0000-4000-8000-000000000001'
// The app's answer, as RemoteInboxRoute writes it: no words, no note.
const LISTED = JSON.stringify({
  ok: true,
  captures: {
    inboxAvailable: true,
    captures: [
      { id: CAPTURE, title: 'Italic kerning', kind: 'issue', state: 'ready', capturedAt: '2026-10-04T10:00:00Z' },
      { id: '81d04e77-0000-4000-8000-000000000002', title: '', state: 'drafting', capturedAt: '2026-10-04T11:00:00Z' },
    ],
  },
})
const PANE = {
  title: 'Inbox',
  isFocused: false,
  bodyColumns: 40,
  placement: 'inline',
  scroll: { top: 0, height: 0 },
  view: {},
} as unknown as RenderPropsOf['Pane']

type Poll = { session_id: string; instance: string; nonce: string; challenge: string; attach: number; acked: number }
const PROPS = {
  hasSurvey: false,
  isWorking: false,
  maxRows: 4,
  bodyColumns: 80,
  scroll: { top: 0, height: 0 },
} as unknown as RenderPropsOf['AbovePrompt']

/**
 * A listener as the app runs it: checks each request's token and proof,
 * answers each poll with the next batch (or holds it), and records replies.
 * `forge` answers with a proof under another key, as a squatter would.
 */
function fakeApp(
  clock: { sleep(ms: number): Promise<void> },
  batches: (string[] | 'drop')[],
  answer: { forge?: boolean; status?: number } = {},
) {
  const polls: Poll[] = []
  const replies: unknown[] = []
  const refusals: string[] = []
  const fetch = async (url: string, init: HttpInit | undefined): Promise<HttpResponse> => {
    const body = init?.body ?? ''
    if (init?.headers?.Authorization !== `Bearer ${TOKEN}`) refusals.push('token')
    if (init?.headers?.['X-Lvx-Mod-Proof'] !== requestProof(KEY, body)) refusals.push('proof')
    if (url === REPLY) {
      replies.push(JSON.parse(body))
      return { status: 200, ok: true, headers: {}, text: '' }
    }
    expect(url).toBe(POLL)
    const poll = JSON.parse(body) as Poll
    polls.push(poll)
    if (answer.status !== undefined) return { status: answer.status, ok: false, headers: {}, text: '' }
    const lines = batches.shift()
    if (lines === 'drop') {
      await clock.sleep(1000)
      throw new Error('connection reset')
    }
    if (lines === undefined) await clock.sleep(25000)
    const next = (polls.length % 16).toString(16).repeat(32)
    const text = JSON.stringify({ attach: 7, first: poll.acked + 1, lines: lines ?? [], next })
    const proof = answerProof(answer.forge === true ? 'b'.repeat(64) : KEY, poll.nonce, text)
    return { status: 200, ok: true, headers: { 'x-lvx-mod-proof': proof }, text }
  }
  return { polls, replies, refusals, fetch }
}

describe('remote channel', () => {
  test('HMAC-SHA256 matches RFC 4231 test case 2', () => {
    expect(hmacHex('Jefe', 'what do ya want for nothing?')).toBe(
      '5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843',
    )
  })

  test('proofs match the vectors the app checks (ClaudeRemoteModWireTests)', () => {
    expect(requestProof(KEY, '{"x":1}')).toBe('c32d4043464e45b4bfea427d675b52d1f1a9128f8b1d1a3743e915343d4de5e4')
    expect(answerProof(KEY, '0'.repeat(32), '{"x":1}')).toBe(
      '7dbc754e5a775a96107f4e869de08792b7e943498144df60a7ecc9aa1a10e6e8',
    )
  })

  test('answers what a proven poll carries, signed, and acks it on the next poll', { options: OPTIONS }, async ($, on) => {
    const clock = mock.clock(on)
    mock.env(on, { HOME: '/home/tom' })
    const app = fakeApp(clock, [['{"mod_message":1,"kind":"ping","id":"a"}', '{"mod_message":1,"kind":"later","id":"b"}']])
    on('session.start', ($, e) => ({ cwd: e.cwd }))
    on('session.id', () => ({ value: 'sess-1' }))
    on('http.fetch', async ($, e) => ({ value: await app.fetch(e.url, e.init) }))

    await $.session.start(STARTED)
    await clock.advance(1000)

    expect(app.refusals).toEqual([])
    expect(app.replies).toEqual([
      { mod_reply: 1, session_id: 'sess-1', id: 'a', ok: true },
      { mod_reply: 1, session_id: 'sess-1', id: 'b', ok: false, reason: 'unknown_kind' },
    ])
    expect(app.polls.map(poll => [poll.session_id, poll.acked])).toEqual([
      ['sess-1', 0],
      ['sess-1', 2],
    ])
    expect(app.polls[0].nonce).not.toBe(app.polls[1].nonce)
    // The ack names the attach it counts in, and each poll carries the
    // challenge of the answer before it.
    expect(app.polls.map(poll => [poll.attach, poll.challenge])).toEqual([
      [0, ''],
      [7, '1'.repeat(32)],
    ])
  })

  test('a dropped forward clears who waits', { options: OPTIONS }, async ($, on) => {
    const clock = mock.clock(on)
    mock.env(on, { HOME: '/home/tom' })
    const app = fakeApp(clock, [['{"mod_message":1,"kind":"state","id":"w","waiting":["payments"]}'], 'drop'])
    on('session.start', ($, e) => ({ cwd: e.cwd }))
    on('session.id', () => ({ value: 'sess-1' }))
    on('fs.read', () => {
      throw new Error('no stamp')
    })
    on('ui.render', ($, e) => $.ui.resolve(e).Box({}))
    on('http.fetch', async ($, e) => ({ value: await app.fetch(e.url, e.init) }))

    await $.session.start(STARTED)
    await clock.advance(10)
    const ui = await $.ui.mount({ plugin: 'localvoxtral-remote', surface: 'terminal', component: 'AbovePrompt', props: PROPS })
    expect(await ui.find({ type: 'Text', text: 'payments waits for you' })).toBeDefined()
    await clock.advance(1000)
    expect(app.polls.length).toBe(2)
    expect(await ui.find({ type: 'Text', text: /wait/ })).toBeUndefined()
    await ui.unmount()
  })

  test('acts on nothing an answer without the key proof carries, and waits before dialing again', { options: OPTIONS }, async ($, on) => {
    const clock = mock.clock(on)
    mock.env(on, { HOME: '/home/tom' })
    const app = fakeApp(clock, [['{"mod_message":1,"kind":"fill","id":"f","text":"rm -rf /"}']], { forge: true })
    const fills: string[] = []
    on('session.start', ($, e) => ({ cwd: e.cwd }))
    on('session.id', () => ({ value: 'sess-1' }))
    on('fs.read', () => {
      throw new Error('no stamp')
    })
    on('prompt.fill', ($, e) => {
      fills.push(e.text)
      return { isFilled: true, text: e.text }
    })
    on('http.fetch', async ($, e) => ({ value: await app.fetch(e.url, e.init) }))

    await $.session.start(STARTED)
    await clock.advance(BACKOFF_MS - 10000)
    expect(fills).toEqual([])
    expect(app.replies).toEqual([])
    expect(app.polls.length).toBe(1)
    await clock.advance(20000)
    expect(app.polls.length).toBe(2)
    // The forged answer's challenge is not carried.
    expect(app.polls[1].challenge).toBe('')
  })

  test('a hook that reaches the app ends the wait early', { options: OPTIONS }, async ($, on) => {
    const clock = mock.clock(on)
    mock.env(on, { HOME: '/home/tom', XDG_RUNTIME_DIR: '/run/user/1000' })
    let dials = 0
    let stamp = 'down 0'
    on('session.start', ($, e) => ({ cwd: e.cwd }))
    on('session.id', () => ({ value: 'sess-1' }))
    on('fs.read', ($, e) => {
      expect(e.path).toBe('/run/user/1000/localvoxtral/hook-status')
      return { value: stamp }
    })
    on('http.fetch', async () => {
      dials += 1
      if (dials === 1) throw new Error('connection refused')
      await clock.sleep(600000)
      return { value: { status: 200, ok: true, headers: {}, text: '' } }
    })

    await $.session.start(STARTED)
    await clock.advance(60000)
    expect(dials).toBe(1)
    stamp = `ok ${Math.floor(clock.now() / 1000)}`
    await clock.advance(6000)
    expect(dials).toBe(2)
  })

  test('an app without the route ends the channel for the session', { options: OPTIONS }, async ($, on) => {
    const clock = mock.clock(on)
    mock.env(on, { HOME: '/home/tom' })
    const app = fakeApp(clock, [], { status: 404 })
    on('session.start', ($, e) => ({ cwd: e.cwd }))
    on('session.id', () => ({ value: 'sess-1' }))
    on('http.fetch', async ($, e) => ({ value: await app.fetch(e.url, e.init) }))

    await $.session.start(STARTED)
    await clock.advance(BACKOFF_MS * 2)
    expect(app.polls.length).toBe(1)
  })

  for (const [label, options] of [
    ['no channel key', { token: TOKEN, port: '29891' }],
    ['no token', { port: '29891', channel_key: KEY }],
  ] as const) {
    test(`dials nothing with ${label}`, { options }, async ($, on) => {
      const clock = mock.clock(on)
      mock.env(on, { HOME: '/home/tom' })
      let dials = 0
      on('session.start', ($, e) => ({ cwd: e.cwd }))
      on('session.id', () => ({ value: 'sess-1' }))
      on('http.fetch', () => {
        dials += 1
        return { value: { status: 200, ok: true, headers: {}, text: '' } }
      })

      await $.session.start(STARTED)
      await clock.advance(60000)
      expect(dials).toBe(0)
    })
  }

  test('session.end says a signed bye, and a /clear polls under the new id', { options: OPTIONS }, async ($, on) => {
    const clock = mock.clock(on)
    mock.env(on, { HOME: '/home/tom' })
    let sessionID = 'sess-1'
    const app = fakeApp(clock, [])
    on('session.start', ($, e) => ({ cwd: e.cwd }))
    on('session.end', ($, e) => ({ sessionId: e.sessionId }))
    on('session.id', () => ({ value: sessionID }))
    on('http.fetch', async ($, e) => ({ value: await app.fetch(e.url, e.init) }))

    await $.session.start(STARTED)
    await clock.advance(1000)
    await $.session.end({ reason: 'clear', sessionId: 'sess-1', resume: { id: 'sess-1' } })
    sessionID = 'sess-2'
    await clock.advance(2000)

    expect(app.refusals).toEqual([])
    expect(app.replies).toEqual([{ mod_bye: 1, session_id: 'sess-1' }])
    expect(app.polls.map(poll => poll.session_id)).toEqual(['sess-1', 'sess-2'])
  })

  test('/inbox lists the session project from the app, signed, and opens a capture by id', { options: OPTIONS }, async ($, on) => {
    const clock = mock.clock(on, { now: NOW })
    mock.env(on, { HOME: '/home/tom' })
    const asks: { url: string; body: Record<string, unknown>; proven: boolean }[] = []
    const toasts: string[] = []
    on('session.start', ($, e) => ({ cwd: e.cwd }))
    on('session.id', () => ({ value: 'sess-1' }))
    on('command.register', ($, e) => ({ value: { command: e.name } }))
    on('ui.open', () => ({ value: { isPlaced: true } }))
    on('ui.toast', ($, e) => {
      toasts.push(e.text)
      return { value: undefined }
    })
    on('ui.render', ($, e) => $.ui.resolve(e).Box({}))
    on('http.fetch', async ($, e) => {
      if (e.url === POLL) {
        await clock.sleep(600000)
        return { value: { status: 200, ok: true, headers: {}, text: '' } }
      }
      const body = e.init?.body ?? ''
      const asked = JSON.parse(body) as Record<string, unknown>
      asks.push({ url: e.url, body: asked, proven: e.init?.headers?.['X-Lvx-Mod-Proof'] === requestProof(KEY, body) })
      const text = e.url === INBOX ? LISTED : ''
      const proof = answerProof(KEY, String(asked.nonce), text)
      return { value: { status: 200, ok: true, headers: { 'x-lvx-mod-proof': proof }, text } }
    })

    await $.session.start(STARTED)
    const ran = await $.command.run({ command: 'inbox' })
    expect(ran.text).toBe('Opened the Inbox pane.')
    const ui = await $.ui.mount({ plugin: 'localvoxtral-remote', surface: 'desktop', component: 'Pane', props: PANE, requestId: 'localvoxtral-inbox' })
    expect(await ui.find({ type: 'Text', text: 'Italic kerning' })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: 'Untitled capture' })).toBeDefined()
    await ui.press({ key: `open-${CAPTURE}` })
    await ui.unmount()

    expect(toasts).toEqual([])
    expect(asks.map(ask => [ask.url, ask.proven, ask.body.session_id, ask.body.id])).toEqual([
      [INBOX, true, 'sess-1', undefined],
      [INBOX_OPEN, true, 'sess-1', CAPTURE],
    ])
  })

  test('/inbox shows nothing an answer without the key proof carries', { options: OPTIONS }, async ($, on) => {
    mock.clock(on, { now: NOW })
    mock.env(on, { HOME: '/home/tom' })
    on('session.start', ($, e) => ({ cwd: e.cwd }))
    on('session.id', () => ({ value: 'sess-1' }))
    on('command.register', ($, e) => ({ value: { command: e.name } }))
    on('ui.open', () => ({ value: { isPlaced: true } }))
    on('ui.render', ($, e) => $.ui.resolve(e).Box({}))
    on('http.fetch', async ($, e) => {
      const asked = JSON.parse(e.init?.body ?? '{}') as Record<string, unknown>
      const text = e.url === INBOX ? LISTED : ''
      const proof = answerProof('b'.repeat(64), String(asked.nonce), text)
      return { value: { status: 200, ok: true, headers: { 'x-lvx-mod-proof': proof }, text } }
    })

    await $.session.start(STARTED)
    await $.command.run({ command: 'inbox' })
    const ui = await $.ui.mount({ plugin: 'localvoxtral-remote', surface: 'terminal', component: 'Pane', props: PANE, requestId: 'localvoxtral-inbox' })
    expect(await ui.find({ type: 'Text', text: 'localvoxtral could not list the Inbox.' })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: 'Italic kerning' })).toBeUndefined()
    await ui.unmount()
  })
})
